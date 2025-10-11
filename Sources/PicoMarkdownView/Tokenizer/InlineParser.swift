import Foundation

/// Minimal streaming inline parser supporting CommonMark emphasis, code spans, links, and hard breaks.
struct InlineParser {
    private var pending: String = ""

    mutating func append(_ text: String) -> [InlineRun] {
        pending.append(text)
        return consume(includeUnterminated: false)
    }

    mutating func finish() -> [InlineRun] {
        let runs = consume(includeUnterminated: true)
        pending.removeAll(keepingCapacity: true)
        return runs
    }

    private mutating func consume(includeUnterminated: Bool) -> [InlineRun] {
        guard !pending.isEmpty else { return [] }

        var runs: [InlineRun] = []
        let text = pending
        var index = text.startIndex
        var plainStart = text.startIndex
        var consumedEnd = text.startIndex
        var consumedAll = true

        func flushPlain(upTo end: String.Index) {
            guard plainStart < end else { return }
            let substring = String(text[plainStart..<end])
            runs.append(contentsOf: makePlainRuns(from: substring))
            consumedEnd = end
            plainStart = end
        }

        parsing: while index < text.endIndex {
            let ch = text[index]
            switch ch {
            case "[":
                flushPlain(upTo: index)
                guard let closingBracket = text[text.index(after: index)..<text.endIndex].firstIndex(of: "]") else {
                    if includeUnterminated {
                        // Treat as literal and continue.
                        plainStart = index
                        index = text.index(after: index)
                        continue parsing
                    } else {
                        consumedAll = false
                        break parsing
                    }
                }
                let afterBracket = text.index(after: closingBracket)
                guard afterBracket < text.endIndex, text[afterBracket] == "(" else {
                    if includeUnterminated {
                        plainStart = index
                        index = text.index(after: index)
                        continue parsing
                    } else {
                        consumedAll = false
                        break parsing
                    }
                }
                var closingParen: String.Index?
                var cursor = text.index(after: afterBracket)
                while cursor < text.endIndex {
                    if text[cursor] == ")" {
                        closingParen = cursor
                        break
                    }
                    cursor = text.index(after: cursor)
                }
                guard let closing = closingParen else {
                    if includeUnterminated {
                        plainStart = index
                        index = text.index(after: index)
                        continue parsing
                    } else {
                        consumedAll = false
                        break parsing
                    }
                }
                let labelStart = text.index(after: index)
                let label = String(text[labelStart..<closingBracket])
                let urlStart = text.index(after: afterBracket)
                let url = String(text[urlStart..<closing])
                runs.append(InlineRun(text: label, style: [.link], linkURL: url))
                let afterClose = text.index(after: closing)
                consumedEnd = afterClose
                index = afterClose
                plainStart = afterClose
            case "*":
                let nextIndex = text.index(after: index)
                let isBold = nextIndex < text.endIndex && text[nextIndex] == "*"
                if isBold {
                    let searchStart = text.index(after: nextIndex)
                    guard let closingRange = text[searchStart..<text.endIndex].range(of: "**") else {
                        if includeUnterminated {
                            plainStart = index
                            index = nextIndex
                            continue parsing
                        } else {
                            consumedAll = false
                            break parsing
                        }
                    }
                    flushPlain(upTo: index)
                    let inner = String(text[searchStart..<closingRange.lowerBound])
                    runs.append(InlineRun(text: inner, style: [.bold]))
                    let afterClose = closingRange.upperBound
                    consumedEnd = afterClose
                    index = afterClose
                    plainStart = afterClose
                } else {
                    guard let closing = text[text.index(after: index)..<text.endIndex].firstIndex(of: "*") else {
                        if includeUnterminated {
                            plainStart = index
                            index = text.index(after: index)
                            continue parsing
                        } else {
                            consumedAll = false
                            break parsing
                        }
                    }
                    flushPlain(upTo: index)
                    let inner = String(text[text.index(after: index)..<closing])
                    runs.append(InlineRun(text: inner, style: [.italic]))
                    let afterClose = text.index(after: closing)
                    consumedEnd = afterClose
                    index = afterClose
                    plainStart = afterClose
                }
            case "`":
                guard let closing = text[text.index(after: index)..<text.endIndex].firstIndex(of: "`") else {
                    if includeUnterminated {
                        plainStart = index
                        index = text.index(after: index)
                        continue parsing
                    } else {
                        consumedAll = false
                        break parsing
                    }
                }
                flushPlain(upTo: index)
                let inner = String(text[text.index(after: index)..<closing])
                runs.append(InlineRun(text: inner, style: [.code]))
                let afterClose = text.index(after: closing)
                consumedEnd = afterClose
                index = afterClose
                plainStart = afterClose
            default:
                index = text.index(after: index)
            }
        }

        if includeUnterminated || consumedAll {
            flushPlain(upTo: text.endIndex)
            consumedEnd = text.endIndex
        }

        if consumedEnd > text.startIndex {
            let consumedCount = text.distance(from: text.startIndex, to: consumedEnd)
            pending.removeFirst(consumedCount)
        }

        runs.removeAll(where: { $0.text.isEmpty })
        return runs
    }

    static func parseAll(_ text: String) -> [InlineRun] {
        var parser = InlineParser()
        parser.pending = text
        return parser.consume(includeUnterminated: true)
    }
}

private func makePlainRuns(from text: String) -> [InlineRun] {
    guard !text.isEmpty else { return [] }
    var runs: [InlineRun] = []
    var current = ""
    var index = text.startIndex
    while index < text.endIndex {
        let nextIndex = text.index(after: index)
        if text[index] == " " && nextIndex < text.endIndex && text[nextIndex] == " " {
            let thirdIndex = text.index(after: nextIndex)
            if thirdIndex < text.endIndex && text[thirdIndex] == "\n" {
                if !current.isEmpty {
                    runs.append(InlineRun(text: current))
                    current.removeAll(keepingCapacity: true)
                }
                runs.append(InlineRun(text: "\n"))
                index = text.index(after: thirdIndex)
                continue
            }
        }
        current.append(text[index])
        index = nextIndex
    }
    if !current.isEmpty {
        runs.append(InlineRun(text: current))
    }
    return runs
}
