import Foundation

/// Minimal streaming inline parser supporting CommonMark emphasis, code spans, links, and hard breaks.
struct InlineParser {
    private enum LineBreakParseResult {
        case handled(nextIndex: String.Index)
        case needMore
    }
    private var pending: String = ""
    private var replacements = StreamingReplacementEngine()
    private var mathState: InlineMathState?

    private struct InlineMathState {
        enum Delimiter {
            case dollar(count: Int, display: Bool)
            case command(closing: Character, display: Bool)
        }

        var delimiter: Delimiter
        var startOffset: Int
        var contentOffset: Int
        var openingMarker: String
    }

    mutating func append(_ text: String) -> [InlineRun] {
        pending.append(text)
        return consume(includeUnterminated: false)
    }

    mutating func finish() -> [InlineRun] {
        let runs = consume(includeUnterminated: true)
        pending.removeAll(keepingCapacity: true)
        replacements.reset()
        mathState = nil
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

        func appendProcessed(_ text: String) {
            guard !text.isEmpty else { return }
            let newRuns = makePlainRuns(from: text)
            guard !newRuns.isEmpty else { return }
            if let last = runs.last, last.style.isEmpty, last.linkURL == nil, last.image == nil,
               let lastPlain = newRuns.first, lastPlain.style.isEmpty, lastPlain.linkURL == nil, lastPlain.image == nil,
               !last.text.hasSuffix("\n"), !(lastPlain.text.hasPrefix("\n")) {
                runs[runs.count - 1].text += lastPlain.text
                runs.append(contentsOf: newRuns.dropFirst())
            } else {
                runs.append(contentsOf: newRuns)
            }
        }

        func appendPlain(_ substring: String) {
            guard !substring.isEmpty else { return }
            let transformed = replacements.process(substring)
            appendProcessed(transformed)
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

        func offset(of index: String.Index) -> Int {
            text.distance(from: text.startIndex, to: index)
        }

        func indexForOffset(_ offset: Int) -> String.Index {
            text.index(text.startIndex, offsetBy: offset)
        }

        func appendMathRun(_ tex: String, display: Bool) {
            let run = InlineRun(text: tex,
                                 style: [.math],
                                 math: MathInlinePayload(tex: tex, display: display))
            runs.append(run)
        }

        func parseNestedRuns(from text: String, inheriting style: InlineStyle) -> [InlineRun] {
            guard !text.isEmpty else { return [] }
            var nested = InlineParser()
            var result = nested.append(text)
            result += nested.finish()
            guard !result.isEmpty else { return [] }
            let nonInheriting: InlineStyle = [.code, .math, .image]
            return result.map { run in
                guard run.style.intersection(nonInheriting).isEmpty else { return run }
                var combined = run
                combined.style.formUnion(style)
                return combined
            }
        }

        func appendRun(_ run: InlineRun) {
            if let last = runs.last,
               last.style == run.style,
               last.linkURL == run.linkURL,
               last.image == run.image,
               last.math == run.math,
               !last.text.hasSuffix("\n"),
               !run.text.hasPrefix("\n") {
                runs[runs.count - 1].text += run.text
            } else {
                runs.append(run)
            }
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

        enum AutolinkParseResult {
            case handled(nextIndex: String.Index, display: String, url: String)
            case needMore
        }

        func isAutolinkPrefix(at index: String.Index) -> (scheme: String, prefixLength: Int)? {
            let remaining = text[index...]
            if remaining.hasPrefix("http://") || remaining.hasPrefix("HTTP://") {
                return ("http://", 7)
            }
            if remaining.hasPrefix("https://") || remaining.hasPrefix("HTTPS://") {
                return ("https://", 8)
            }
            if remaining.hasPrefix("www.") || remaining.hasPrefix("WWW.") {
                return ("www.", 4)
            }
            return nil
        }

        func isAutolinkBoundaryBefore(_ index: String.Index) -> Bool {
            guard let prev = character(before: index) else { return true }
            if isAlphanumeric(prev) { return false }
            return true
        }

        func normalizeAutolink(display: String, prefix: (scheme: String, prefixLength: Int)) -> (display: String, url: String)? {
            guard !display.isEmpty else { return nil }
            var sawDot = false
            var parenDepth = 0
            for character in display {
                if character == "(" {
                    parenDepth += 1
                } else if character == ")" {
                    if parenDepth == 0 {
                        return nil
                    }
                    parenDepth -= 1
                }
                if character == "." || character == "/" || character == "#" || character == "?" {
                    sawDot = true
                }
                if character.isWhitespace || character == "<" || character == ">" || character == "\"" || character == "'" {
                    return nil
                }
            }
            if parenDepth != 0 {
                return nil
            }
            if prefix.scheme.lowercased().hasPrefix("www") && !sawDot {
                return nil
            }
            let url: String
            if prefix.scheme.lowercased().hasPrefix("www") {
                url = "https://" + display
            } else {
                url = display
            }
            return (display, url)
        }

        func parseAutolink(at index: String.Index) -> AutolinkParseResult? {
            guard isAutolinkBoundaryBefore(index), let prefix = isAutolinkPrefix(at: index) else {
                return nil
            }

            var cursor = text.index(index, offsetBy: prefix.prefixLength)
            var lastAcceptable = cursor
            var parenDepth = 0
            var consumedCharacters = 0

            while cursor < text.endIndex {
                let ch = text[cursor]
                if ch == "(" {
                    parenDepth += 1
                    cursor = text.index(after: cursor)
                    lastAcceptable = cursor
                    consumedCharacters += 1
                    continue
                }
                if ch == ")" {
                    if parenDepth == 0 {
                        break
                    }
                    parenDepth -= 1
                    cursor = text.index(after: cursor)
                    lastAcceptable = cursor
                    consumedCharacters += 1
                    continue
                }
                if ch == "<" || ch == ">" || ch == "\"" || ch == "'" {
                    break
                }
                if ch.isWhitespace || ch.isNewline {
                    break
                }
                cursor = text.index(after: cursor)
                lastAcceptable = cursor
                consumedCharacters += 1
            }

            if cursor == text.endIndex && !includeUnterminated {
                return .needMore
            }

            var endIndex = lastAcceptable
            while endIndex > index {
                let prevIndex = text.index(before: endIndex)
                let prevChar = text[prevIndex]
                if ".,:;!?".contains(prevChar) {
                    endIndex = prevIndex
                    continue
                }
                break
            }

            guard endIndex > index else { return nil }
            if consumedCharacters == 0 {
                return nil
            }

            let display = String(text[index..<endIndex])
            guard let normalized = normalizeAutolink(display: display, prefix: prefix) else {
                return nil
            }

            return .handled(nextIndex: endIndex, display: normalized.display, url: normalized.url)
        }

        func parseAngleAutolink(at index: String.Index) -> AutolinkParseResult? {
            let start = text.index(after: index)
            guard start < text.endIndex else { return .needMore }
            guard let closing = text[start...].firstIndex(of: ">") else {
                return includeUnterminated ? nil : .needMore
            }
            let candidate = String(text[start..<closing])
            guard let prefix = isAutolinkPrefix(at: start) else { return nil }
            guard let normalized = normalizeAutolink(display: candidate, prefix: prefix) else { return nil }
            let afterClose = text.index(after: closing)
            return .handled(nextIndex: afterClose, display: normalized.display, url: normalized.url)
        }

        func parseLineBreakTag(at index: String.Index) -> LineBreakParseResult? {
            let remaining = text[index...]
            if remaining.count < 4 {
                return includeUnterminated ? .needMore : nil
            }

            var cursor = text.index(after: index)
            guard cursor < text.endIndex else { return includeUnterminated ? .needMore : nil }
            let first = text[cursor].lowercased()
            guard first == "b" else { return nil }
            cursor = text.index(after: cursor)
            guard cursor < text.endIndex else { return includeUnterminated ? .needMore : nil }
            let second = text[cursor].lowercased()
            guard second == "r" else { return nil }
            cursor = text.index(after: cursor)

            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }

            if cursor < text.endIndex, text[cursor] == "/" {
                cursor = text.index(after: cursor)
                while cursor < text.endIndex, text[cursor].isWhitespace {
                    cursor = text.index(after: cursor)
                }
            }

            guard cursor < text.endIndex else { return includeUnterminated ? .needMore : nil }
            guard text[cursor] == ">" else { return nil }
            let nextIndex = text.index(after: cursor)
            return .handled(nextIndex: nextIndex)
        }

        parsing: while index < text.endIndex {
            let ch = text[index]
            switch ch {
            case "\\":
                let nextIndex = text.index(after: index)
                if let state = mathState {
                    switch state.delimiter {
                    case .command(let closing, let display):
                        if nextIndex < text.endIndex, text[nextIndex] == closing {
                            let contentStart = indexForOffset(state.contentOffset)
                            let inner = contentStart <= index ? String(text[contentStart..<index]) : ""
                            appendMathRun(inner, display: display)
                            let afterClose = text.index(after: nextIndex)
                            consumedEnd = afterClose
                            index = afterClose
                            plainStart = afterClose
                            mathState = nil
                            continue parsing
                        }
                    default:
                        break
                    }
                }
                if mathState == nil, nextIndex < text.endIndex {
                    let nextChar = text[nextIndex]
                    if nextChar == "(" || nextChar == "[" {
                        flushPlain(upTo: index)
                        let display = nextChar == "["
                        let startOffset = offset(of: index)
                        let markerEnd = text.index(after: nextIndex)
                        let marker = String(text[index..<markerEnd])
                        consumedEnd = markerEnd
                        let contentOffset = startOffset + 2
                        mathState = InlineMathState(
                            delimiter: .command(closing: nextChar == "(" ? ")" : "]", display: display),
                            startOffset: startOffset,
                            contentOffset: contentOffset,
                            openingMarker: marker
                        )
                        let contentIndex = markerEnd
                        plainStart = contentIndex
                        index = contentIndex
                        continue parsing
                    }
                }
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
            case "$":
                if let prev = character(before: index), prev == "\\" {
                    index = text.index(after: index)
                    continue parsing
                }
                if let state = mathState {
                    switch state.delimiter {
                    case .dollar(let count, let display):
                        var length = 0
                        var cursor = index
                        while cursor < text.endIndex, text[cursor] == "$", length < count {
                            length += 1
                            cursor = text.index(after: cursor)
                        }
                        if length == count {
                            let contentStart = indexForOffset(state.contentOffset)
                            let inner = contentStart <= index ? String(text[contentStart..<index]) : ""
                            appendMathRun(inner, display: display)
                            consumedEnd = cursor
                            index = cursor
                            plainStart = cursor
                            mathState = nil
                            continue parsing
                        }
                    default:
                        break
                    }
                } else {
                    var length = 1
                    var cursor = text.index(after: index)
                    while cursor < text.endIndex, text[cursor] == "$" && length < 2 {
                        length += 1
                        cursor = text.index(after: cursor)
                    }
                    let display = length >= 2
                    let markerLength = display ? 2 : 1
                    flushPlain(upTo: index)
                    let startOffset = offset(of: index)
                    let markerEnd = text.index(index, offsetBy: markerLength)
                    let marker = String(text[index..<markerEnd])
                    consumedEnd = markerEnd
                    let contentOffset = startOffset + markerLength
                    mathState = InlineMathState(
                        delimiter: .dollar(count: markerLength, display: display),
                        startOffset: startOffset,
                        contentOffset: contentOffset,
                        openingMarker: marker
                    )
                    let contentIndex = markerEnd
                    plainStart = contentIndex
                    index = contentIndex
                    continue parsing
                }
                index = text.index(after: index)
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
                let nestedRuns = parseNestedRuns(from: inner, inheriting: style)
                if nestedRuns.isEmpty {
                    appendRun(InlineRun(text: inner, style: style))
                } else {
                    nestedRuns.forEach { appendRun($0) }
                }
                let afterClose = closingRange.upperBound
                consumedEnd = afterClose
                index = afterClose
                plainStart = afterClose
            case "~":
                // GFM Strikethrough: require a leading "~~" and a matching closing "~~".
                let nextIndex = text.index(after: index)
                if nextIndex < text.endIndex && text[nextIndex] == "~" {
                    let searchStart = text.index(after: nextIndex)
                    if let closeAfter = findStrikethroughClosing(in: text, from: searchStart) {
                        // Flush any accumulated plain text before the styled run
                        flushPlain(upTo: index)

                        // Extract inner text between the opening and closing tildes
                        let innerStart = text.index(after: nextIndex)
                        let innerEndExclusive = text.index(closeAfter, offsetBy: -2) // index of the first tilde in the closing "~~"
                        let inner = innerStart <= innerEndExclusive ? String(text[innerStart..<innerEndExclusive]) : ""
                        let nestedRuns = parseNestedRuns(from: inner, inheriting: [.strikethrough])

                        if nestedRuns.isEmpty {
                            appendRun(InlineRun(text: inner, style: [.strikethrough]))
                        } else {
                            nestedRuns.forEach { appendRun($0) }
                        }

                        // Advance past the closing delimiter and reset plainStart
                        consumedEnd = closeAfter
                        index = closeAfter
                        plainStart = closeAfter
                        continue parsing
                    } else if !includeUnterminated {
                        // Streaming: we haven’t seen the closing "~~" yet. Emit all unambiguous
                        // plain text *before* the opener, then pause so we don’t emit provisional runs.
                        flushPlain(upTo: index)
                        consumedEnd = index
                        plainStart = index
                        consumedAll = false
                        break parsing
                    }
                }
                // No "~~" or still incomplete: treat the first "~" as plain and keep scanning.
                index = nextIndex
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
            case "h", "H", "w", "W":
                if let result = parseAutolink(at: index) {
                    switch result {
                    case .handled(let nextIndex, let display, let url):
                        flushPlain(upTo: index)
                        runs.append(InlineRun(text: display, style: [.link], linkURL: url))
                        consumedEnd = nextIndex
                        index = nextIndex
                        plainStart = nextIndex
                        continue parsing
                    case .needMore:
                        flushPlain(upTo: index)
                        consumedAll = false
                        break parsing
                    }
                }
                index = text.index(after: index)
            case "<":
                if let breakResult = parseLineBreakTag(at: index) {
                    switch breakResult {
                    case .handled(let nextIndex):
                        flushPlain(upTo: index)
                        runs.append(InlineRun(text: "\n"))
                        consumedEnd = nextIndex
                        index = nextIndex
                        plainStart = nextIndex
                        continue parsing
                    case .needMore:
                        consumedAll = false
                        break parsing
                    }
                }
                if let result = parseAngleAutolink(at: index) {
                    switch result {
                    case .handled(let nextIndex, let display, let url):
                        flushPlain(upTo: index)
                        runs.append(InlineRun(text: display, style: [.link], linkURL: url))
                        consumedEnd = nextIndex
                        index = nextIndex
                        plainStart = nextIndex
                        continue parsing
                    case .needMore:
                        consumedAll = false
                        break parsing
                    }
                }
                index = text.index(after: index)
            default:
                index = text.index(after: index)
            }
        }

        if mathState != nil {
            consumedAll = false
        }

        if includeUnterminated, let state = mathState {
            let contentIndex = indexForOffset(max(0, state.contentOffset))
            let remaining = String(text[contentIndex...])
            appendPlain(state.openingMarker + remaining)
            consumedEnd = text.endIndex
            plainStart = text.endIndex
            mathState = nil
        }

        if includeUnterminated || consumedAll {
            flushPlain(upTo: text.endIndex)
            consumedEnd = text.endIndex
        }

        if includeUnterminated {
            let trailing = replacements.finish()
            appendProcessed(trailing)
        }

        if consumedEnd > text.startIndex {
            let consumedCount = text.distance(from: text.startIndex, to: consumedEnd)
            pending.removeFirst(consumedCount)
            if var state = mathState {
                state.startOffset = max(0, state.startOffset - consumedCount)
                state.contentOffset = max(0, state.contentOffset - consumedCount)
                mathState = state
            }
        }

        runs.removeAll(where: { $0.text.isEmpty && $0.style.isEmpty && $0.linkURL == nil && $0.image == nil })
        return runs
    }

    static func parseAll(_ text: String) -> [InlineRun] {
        var parser = InlineParser()
        parser.pending = text
        return parser.consume(includeUnterminated: true)
    }
    
    // MARK: - Strikethrough helper (GFM)
    private func findStrikethroughClosing(in s: String, from: String.Index) -> String.Index? {
        var i = from
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\\" { // skip escaped next char
                i = s.index(after: i)
                if i < s.endIndex { i = s.index(after: i) }
                continue
            }
            if ch == "~" {
                let n = s.index(after: i)
                if n < s.endIndex, s[n] == "~" {
                    return s.index(after: n) // index after the closing "~~"
                }
            }
            i = s.index(after: i)
        }
        return nil
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
