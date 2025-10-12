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

        func appendPlain(_ substring: String) {
            guard !substring.isEmpty else { return }
            let newRuns = makePlainRuns(from: substring)
            guard !newRuns.isEmpty else { return }
            if let last = runs.last, last.style.isEmpty, last.linkURL == nil, last.image == nil,
               let lastPlain = newRuns.first, lastPlain.style.isEmpty, lastPlain.linkURL == nil, lastPlain.image == nil {
                runs[runs.count - 1].text += lastPlain.text
                runs.append(contentsOf: newRuns.dropFirst())
            } else {
                runs.append(contentsOf: newRuns)
            }
        }

        func flushPlain(upTo end: String.Index) {
            guard plainStart < end else { return }
            let substring = String(text[plainStart..<end])
            appendPlain(substring)
            consumedEnd = end
            plainStart = end
        }

        func isAlphanumeric(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        }

        func isWhitespace(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }

        func character(before index: String.Index) -> Character? {
            guard index > text.startIndex else { return nil }
            let prior = text.index(before: index)
            return text[prior]
        }

        func character(after index: String.Index, offset: Int = 0) -> Character? {
            var current = index
            for _ in 0..<offset {
                guard current < text.endIndex else { return nil }
                current = text.index(after: current)
            }
            guard current < text.endIndex else { return nil }
            return text[current]
        }

        func canOpenEmphasis(at index: String.Index, delimiter: Character, length: Int) -> Bool {
            guard delimiter == "_" else { return true }
            if let prev = character(before: index), isAlphanumeric(prev) {
                return false
            }
            guard let next = character(after: index, offset: length) else {
                return false
            }
            return !isWhitespace(next)
        }

        func canCloseEmphasis(at index: String.Index, delimiter: Character, length: Int) -> Bool {
            guard delimiter == "_" else { return true }
            guard let before = character(before: index), !isWhitespace(before) else {
                return false
            }
            if let after = character(after: index, offset: length) {
                if isAlphanumeric(after) {
                    return false
                }
            }
            return true
        }

        func findClosingDelimiter(delimiter: Character, length: Int, from start: String.Index) -> Range<String.Index>? {
            let token = String(repeating: delimiter, count: length)
            var search = start
            while search < text.endIndex {
                guard let range = text[search...].range(of: token) else { return nil }
                if canCloseEmphasis(at: range.lowerBound, delimiter: delimiter, length: length) {
                    return range
                }
                search = text.index(after: range.lowerBound)
            }
            return nil
        }

        func findCodeClosing(delimiterLength: Int, from start: String.Index) -> Range<String.Index>? {
            let token = String(repeating: "`", count: delimiterLength)
            var search = start
            while search < text.endIndex {
                guard let range = text[search...].range(of: token) else { return nil }
                if range.upperBound < text.endIndex, text[range.upperBound] == "`" {
                    search = range.upperBound
                    continue
                }
                return range
            }
            return nil
        }

        enum BracketParseResult {
            case handled(nextIndex: String.Index)
            case literal
            case incomplete
        }

        func splitDestinationAndTitle(_ segment: String) -> (String, String?) {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return ("", nil) }

            let withoutAngles: String
            if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count >= 2 {
                withoutAngles = String(trimmed.dropFirst().dropLast())
            } else {
                withoutAngles = trimmed
            }

            var url = withoutAngles
            var title: String? = nil

            if let spaceIndex = withoutAngles.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                let urlPart = withoutAngles[..<spaceIndex]
                let remainder = withoutAngles[spaceIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
                if let first = remainder.first, first == "\"" || first == "'" {
                    let quote = first
                    let contentStart = remainder.index(after: remainder.startIndex)
                    if let closing = remainder[contentStart...].firstIndex(of: quote) {
                        url = String(urlPart)
                        title = String(remainder[contentStart..<closing])
                    }
                }
            }

            return (url, title)
        }

        func parseBracketSequence(openBracketIndex: String.Index, treatAsImage: Bool) -> BracketParseResult {
            guard let closingBracket = text[text.index(after: openBracketIndex)..<text.endIndex].firstIndex(of: "]") else {
                return .incomplete
            }
            let afterBracket = text.index(after: closingBracket)
            guard afterBracket < text.endIndex, text[afterBracket] == "(" else {
                return .literal
            }
            var closingParen: String.Index?
            var cursor = text.index(after: afterBracket)
            var depth = 0
            while cursor < text.endIndex {
                let currentChar = text[cursor]
                if currentChar == "(" {
                    depth += 1
                } else if currentChar == ")" {
                    if depth == 0 {
                        closingParen = cursor
                        break
                    } else {
                        depth -= 1
                    }
                }
                cursor = text.index(after: cursor)
            }
            guard let closing = closingParen else {
                return .incomplete
            }
            let labelStart = text.index(after: openBracketIndex)
            let label = String(text[labelStart..<closingBracket])
            let urlStart = text.index(after: afterBracket)
            let (destination, title) = splitDestinationAndTitle(String(text[urlStart..<closing]))

            if treatAsImage {
                runs.append(InlineRun(text: label, style: [.image], image: InlineImage(source: destination, title: title)))
            } else {
                runs.append(InlineRun(text: label, style: [.link], linkURL: destination))
            }

            let afterClose = text.index(after: closing)
            consumedEnd = afterClose
            plainStart = afterClose
            return .handled(nextIndex: afterClose)
        }

        parsing: while index < text.endIndex {
            let ch = text[index]
            switch ch {
            case "\\":
                let nextIndex = text.index(after: index)
                if nextIndex >= text.endIndex {
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
                appendPlain(String(text[nextIndex]))
                let after = text.index(after: nextIndex)
                consumedEnd = after
                index = after
                plainStart = after
            case "!":
                let nextIndex = text.index(after: index)
                guard nextIndex < text.endIndex else {
                    if includeUnterminated {
                        plainStart = index
                        index = nextIndex
                        continue parsing
                    } else {
                        consumedAll = false
                        break parsing
                    }
                }
                guard text[nextIndex] == "[" else {
                    index = nextIndex
                    continue parsing
                }
                flushPlain(upTo: index)
                switch parseBracketSequence(openBracketIndex: nextIndex, treatAsImage: true) {
                case .handled(let next):
                    index = next
                case .literal:
                    plainStart = index
                    index = nextIndex
                case .incomplete:
                    if includeUnterminated {
                        plainStart = index
                        index = nextIndex
                        continue parsing
                    } else {
                        consumedAll = false
                        break parsing
                    }
                }
            case "[":
                flushPlain(upTo: index)
                switch parseBracketSequence(openBracketIndex: index, treatAsImage: false) {
                case .handled(let next):
                    index = next
                case .literal:
                    plainStart = index
                    index = text.index(after: index)
                case .incomplete:
                    if includeUnterminated {
                        plainStart = index
                        index = text.index(after: index)
                        continue parsing
                    } else {
                        consumedAll = false
                        break parsing
                    }
                }
            case "*", "_":
                let delimiter = ch
                let nextIndex = text.index(after: index)
                let isDouble = nextIndex < text.endIndex && text[nextIndex] == delimiter
                let markerLength = isDouble ? 2 : 1
                if !canOpenEmphasis(at: index, delimiter: delimiter, length: markerLength) {
                    index = text.index(after: index)
                    continue parsing
                }
                let searchStart = markerLength == 2 ? text.index(after: nextIndex) : text.index(after: index)
                guard searchStart <= text.endIndex else {
                    index = text.index(after: index)
                    continue parsing
                }
                guard let closingRange = findClosingDelimiter(delimiter: delimiter, length: markerLength, from: searchStart) else {
                    if includeUnterminated {
                        plainStart = index
                        index = markerLength == 2 ? text.index(after: nextIndex) : text.index(after: index)
                        continue parsing
                    } else {
                        consumedAll = false
                        break parsing
                    }
                }
                flushPlain(upTo: index)
                let innerStart = markerLength == 2 ? text.index(after: nextIndex) : text.index(after: index)
                let inner = String(text[innerStart..<closingRange.lowerBound])
                let style: InlineStyle = isDouble ? [.bold] : [.italic]
                runs.append(InlineRun(text: inner, style: style))
                let afterClose = closingRange.upperBound
                consumedEnd = afterClose
                index = afterClose
                plainStart = afterClose
            case "~":
                let nextIndex = text.index(after: index)
                guard nextIndex < text.endIndex, text[nextIndex] == "~" else {
                    index = nextIndex
                    continue parsing
                }
                let searchStart = text.index(after: nextIndex)
                guard let closingRange = findClosingDelimiter(delimiter: "~", length: 2, from: searchStart) else {
                    if includeUnterminated {
                        plainStart = index
                        index = searchStart
                        continue parsing
                    } else {
                        consumedAll = false
                        break parsing
                    }
                }
                flushPlain(upTo: index)
                let inner = String(text[searchStart..<closingRange.lowerBound])
                runs.append(InlineRun(text: inner, style: [.strikethrough]))
                let afterClose = closingRange.upperBound
                consumedEnd = afterClose
                index = afterClose
                plainStart = afterClose
            case "`":
                var delimiterLength = 1
                var cursor = text.index(after: index)
                while cursor < text.endIndex && text[cursor] == "`" {
                    delimiterLength += 1
                    cursor = text.index(after: cursor)
                }
                let contentStart = cursor
                guard let closingRange = findCodeClosing(delimiterLength: delimiterLength, from: contentStart) else {
                    if includeUnterminated {
                        plainStart = index
                        index = cursor
                        continue parsing
                    } else {
                        consumedAll = false
                        break parsing
                    }
                }
                flushPlain(upTo: index)
                let inner = String(text[contentStart..<closingRange.lowerBound])
                runs.append(InlineRun(text: inner, style: [.code]))
                let afterClose = closingRange.upperBound
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

        runs.removeAll(where: { $0.text.isEmpty && $0.style.isEmpty && $0.linkURL == nil && $0.image == nil })
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
