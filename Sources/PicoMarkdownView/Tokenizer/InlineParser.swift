import Foundation

struct LinkDefinition: Equatable {
    let url: String
    let title: String?
}

final class LinkReferenceStore {
    private var definitions: [String: LinkDefinition] = [:]

    func define(label: String, url: String, title: String?) {
        let key = normalizeLinkLabel(label)
        guard definitions[key] == nil else { return }
        definitions[key] = LinkDefinition(url: url, title: title)
    }

    func resolve(label: String) -> LinkDefinition? {
        definitions[normalizeLinkLabel(label)]
    }

    private func normalizeLinkLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "\n" || $0 == "\r" })
        return parts.joined(separator: " ").lowercased()
    }
}

final class FootnoteRegistry {
    private var order: [String: Int] = [:]
    private var nextIndex: Int = 1

    func index(for id: String) -> Int {
        if let existing = order[id] { return existing }
        let assigned = nextIndex
        order[id] = assigned
        nextIndex += 1
        return assigned
    }
}

/// Result of attempting to parse a tag at the current position.
private enum TagParseResult {
    /// A tag was successfully recognised and emitted; resume at this index.
    case handled(nextIndex: String.Index)
    /// The opener didn't form a real tag (e.g. ``@`` followed by a hard-stop
    /// character). Let the normal switch handle this position instead.
    case literal
    /// Streaming-incomplete — the buffer doesn't yet contain enough characters
    /// to resolve the tag (e.g. paired ``[[`` without ``]]`` yet, or markdown-
    /// link form ``@[John](`` waiting for ``)``). Caller should pause.
    case needMore
}

/// Minimal streaming inline parser supporting CommonMark emphasis, code spans, links, hard breaks,
/// and inline custom tags (mentions/hashtags/tickers/paired wiki-links).
struct InlineParser {
    private enum LineBreakParseResult {
        case handled(nextIndex: String.Index)
        case needMore
    }
    private var pending: String = ""
    var replacements = StreamingReplacementEngine()
    private var mathState: InlineMathState?
    var linkReferences: LinkReferenceStore?
    var footnoteRegistry: FootnoteRegistry?

    /// Registered tag prefixes. ``MarkdownTokenizer`` populates this via its
    /// init parameter; the default is ``TagPrefix/defaults`` (``@`` + ``#``).
    /// Sorted at init by descending opening length so that longer prefixes
    /// (``[[``) are tried before shorter ones (``[``) when both could match.
    let tagPrefixes: [TagPrefix]

    /// Quick-reject set of single-character prefix openings — used to
    /// short-circuit the per-position scan in ``matchingTagPrefix(at:in:)``
    /// without walking the prefix array on every character.
    let tagPrefixOpeningFirstChars: Set<Character>

    init(tagPrefixes: Set<TagPrefix> = TagPrefix.defaults) {
        // Longest opening first so e.g. "[[" wins over "["
        self.tagPrefixes = tagPrefixes.sorted { $0.opening.count > $1.opening.count }
        self.tagPrefixOpeningFirstChars = Set(
            tagPrefixes.compactMap { $0.opening.first }
        )
    }

    /// Fast-path initializer used when both the sorted-prefix array and the
    /// first-char lookup set are already in hand — avoids the sort + set
    /// conversion on every nested parse triggered by emphasis/strikethrough.
    private init(sortedTagPrefixes: [TagPrefix],
                 tagPrefixOpeningFirstChars: Set<Character>) {
        self.tagPrefixes = sortedTagPrefixes
        self.tagPrefixOpeningFirstChars = tagPrefixOpeningFirstChars
    }

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
        var runs: [InlineRun] = []
        let text = pending
        var index = text.startIndex
        var plainStart = text.startIndex
        var consumedEnd = text.startIndex
        var consumedAll = true

        // Capture immutable parser configuration into locals so the nested
        // helpers below don't need to reach back through `self` (which is
        // `inout` inside this mutating method).
        let parserTagPrefixes = self.tagPrefixes
        let parserTagPrefixOpeningFirstChars = self.tagPrefixOpeningFirstChars

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
            // Use the fast-path init: the outer parser already sorted the
            // prefix array and computed the first-char set, so the nested
            // parser doesn't need to redo either on every emphasis span.
            var nested = InlineParser(sortedTagPrefixes: parserTagPrefixes,
                                      tagPrefixOpeningFirstChars: parserTagPrefixOpeningFirstChars)
            var result = nested.append(text)
            result += nested.finish()
            guard !result.isEmpty else { return [] }
            // Tags are styled text (not opaque attachments like code/math/image),
            // so surrounding emphasis SHOULD apply — "**@behlool**" → bold tag.
            let nonInheriting: InlineStyle = [.code, .math, .image]
            return result.map { run in
                guard run.style.intersection(nonInheriting).isEmpty else { return run }
                var combined = run
                combined.style.formUnion(style)
                return combined
            }
        }

        func appendRun(_ run: InlineRun) {
            // Payload-identity check is shared with the assembler and the
            // state machine via `InlineRun.canCoalesce(with:)`; the two
            // line-break guards are local to inline parsing (don't merge
            // across a hard line break) and stay here.
            if let last = runs.last,
               last.canCoalesce(with: run),
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
            let labelStart = text.index(after: openBracketIndex)
            let label = String(text[labelStart..<closingBracket])
            if !treatAsImage, label.hasPrefix("^") {
                let id = String(label.dropFirst())
                if !id.isEmpty, let registry = footnoteRegistry {
                    let number = registry.index(for: id)
                    let run = InlineRun(text: String(number), style: [.footnote, .superscript])
                    runs.append(run)
                    consumedEnd = afterBracket
                    plainStart = afterBracket
                    return .handled(nextIndex: afterBracket)
                }
                return .literal
            }
            guard afterBracket < text.endIndex else {
                return .literal
            }
            if text[afterBracket] != "(" {
                if let reference = parseReferenceLink(label: label, afterBracket: afterBracket, treatAsImage: treatAsImage) {
                    return reference
                }
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

        func parseReferenceLink(label: String,
                                afterBracket: String.Index,
                                treatAsImage: Bool) -> BracketParseResult? {
            guard let store = linkReferences else { return nil }
            var referenceLabel = label
            var nextIndex = afterBracket

            if text[afterBracket] == "[" {
                guard let closing = text[text.index(after: afterBracket)..<text.endIndex].firstIndex(of: "]") else {
                    return .incomplete
                }
                let innerStart = text.index(after: afterBracket)
                let innerLabel = String(text[innerStart..<closing])
                if !innerLabel.isEmpty {
                    referenceLabel = innerLabel
                }
                nextIndex = text.index(after: closing)
            }

            guard let definition = store.resolve(label: referenceLabel), !definition.url.isEmpty else {
                return .literal
            }

            if treatAsImage {
                runs.append(InlineRun(text: label, style: [.image], image: InlineImage(source: definition.url, title: definition.title)))
            } else {
                runs.append(InlineRun(text: label, style: [.link], linkURL: definition.url))
            }
            consumedEnd = nextIndex
            plainStart = nextIndex
            return .handled(nextIndex: nextIndex)
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

        enum InlineHTMLParseResult {
            case handled(nextIndex: String.Index)
            case needMore
        }

        func parseInlineHTMLTag(at index: String.Index) -> InlineHTMLParseResult? {
            let remaining = text[index...]
            if remaining.hasPrefix("<kbd>") {
                return parseInlineHTMLTag(open: "<kbd>", close: "</kbd>", style: [.keyboard], at: index)
            }
            if remaining.hasPrefix("<sup>") {
                return parseInlineHTMLTag(open: "<sup>", close: "</sup>", style: [.superscript], at: index)
            }
            if remaining.hasPrefix("<sub>") {
                return parseInlineHTMLTag(open: "<sub>", close: "</sub>", style: [.subscriptText], at: index)
            }
            return nil
        }

        func parseInlineHTMLTag(open: String,
                                close: String,
                                style: InlineStyle,
                                at index: String.Index) -> InlineHTMLParseResult? {
            guard let openRange = text[index...].range(of: open) else { return nil }
            let contentStart = openRange.upperBound
            guard let closeRange = text[contentStart...].range(of: close) else {
                return .needMore
            }
            flushPlain(upTo: index)
            let inner = String(text[contentStart..<closeRange.lowerBound])
            let nestedRuns = parseNestedRuns(from: inner, inheriting: style)
            if nestedRuns.isEmpty {
                appendRun(InlineRun(text: inner, style: style))
            } else {
                nestedRuns.forEach { appendRun($0) }
            }
            let afterClose = closeRange.upperBound
            consumedEnd = afterClose
            plainStart = afterClose
            return .handled(nextIndex: afterClose)
        }

        // MARK: - Inline tag parsing

        /// Returns the longest registered ``TagPrefix`` whose opening matches
        /// the buffer starting at ``index``, or ``nil`` if none match.
        /// ``tagPrefixes`` is pre-sorted longest-first at init, so this picks
        /// e.g. ``[[`` over ``[``.
        func matchingTagPrefix(at index: String.Index) -> TagPrefix? {
            // Cheap reject: first character must match at least one opening.
            guard parserTagPrefixOpeningFirstChars.contains(text[index]) else { return nil }
            for prefix in parserTagPrefixes {
                if text[index...].hasPrefix(prefix.opening) {
                    return prefix
                }
            }
            return nil
        }

        /// Build the synthetic URL string used by the renderer to route tag
        /// taps/hovers back to the host.
        ///
        /// Format: ``pico-tag:///<prefix>/<identifier>`` with an explicitly
        /// empty host (three slashes) so neither component lands in URL host
        /// position — important because `urlHostAllowed` is stricter than
        /// `urlPathAllowed`, and because an unencoded ``@`` (the default
        /// mention prefix!) in the host position would be parsed as a
        /// userinfo separator (`scheme://user@host`).
        ///
        /// Encoding: ``CharacterSet.alphanumerics``-only allowed — anything
        /// else is percent-encoded. The URL is opaque to the host (they get
        /// the ``Tag`` payload via callback); readability isn't a goal, but
        /// round-trip safety is, regardless of what characters appear in
        /// the prefix or identifier (slashes, fragments, query separators,
        /// userinfo separators, percent signs, anything).
        func makePicoTagURL(prefix: String, identifier: String) -> String {
            let allowed = CharacterSet.alphanumerics
            let encodedPrefix = prefix.addingPercentEncoding(withAllowedCharacters: allowed) ?? prefix
            let encodedIdentifier = identifier.addingPercentEncoding(withAllowedCharacters: allowed) ?? identifier
            return "pico-tag:///\(encodedPrefix)/\(encodedIdentifier)"
        }

        /// Try the ``@[Display Text](identifier)`` markdown-link form.
        /// Returns ``.handled`` on success, ``.needMore`` if the buffer is
        /// streaming-incomplete (no closing ``]`` or ``)`` yet), or ``nil``
        /// to indicate "not the markdown-link form" so the caller can fall
        /// back to the bare-tag scan.
        func parseMarkdownLinkTagForm(openerStart: String.Index,
                                      prefix: TagPrefix,
                                      bracketStart: String.Index) -> TagParseResult? {
            let labelStart = text.index(after: bracketStart)
            guard labelStart <= text.endIndex else {
                return includeUnterminated ? nil : .needMore
            }
            guard let labelClose = text[labelStart..<text.endIndex].firstIndex(of: "]") else {
                return includeUnterminated ? nil : .needMore
            }
            let afterLabelClose = text.index(after: labelClose)
            guard afterLabelClose < text.endIndex else {
                return includeUnterminated ? nil : .needMore
            }
            guard text[afterLabelClose] == "(" else {
                // Not the markdown-link form. Caller falls back to bare scan.
                return nil
            }

            var closingParen: String.Index?
            var cursor = text.index(after: afterLabelClose)
            var depth = 0
            while cursor < text.endIndex {
                let c = text[cursor]
                if c == "(" {
                    depth += 1
                } else if c == ")" {
                    if depth == 0 {
                        closingParen = cursor
                        break
                    } else {
                        depth -= 1
                    }
                }
                cursor = text.index(after: cursor)
            }
            guard let close = closingParen else {
                return includeUnterminated ? nil : .needMore
            }

            let label = String(text[labelStart..<labelClose])
            let urlStart = text.index(after: afterLabelClose)
            let rawIdentifier = String(text[urlStart..<close])
            let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)

            // Empty label or empty identifier — not a useful tag. Fall back so
            // the caller can try the bare form / treat as literal.
            guard !label.isEmpty, !identifier.isEmpty else { return nil }

            let displayText = prefix.opening + label
            let nextIndex = text.index(after: close)
            let raw = String(text[openerStart..<nextIndex])
            let tagPayload = Tag(prefix: prefix.opening,
                                 identifier: identifier,
                                 displayText: displayText,
                                 rawText: raw)
            let url = makePicoTagURL(prefix: prefix.opening, identifier: identifier)

            flushPlain(upTo: openerStart)
            appendRun(InlineRun(text: displayText,
                                style: [.tag, .link],
                                linkURL: url,
                                tag: tagPayload))
            consumedEnd = nextIndex
            plainStart = nextIndex
            return .handled(nextIndex: nextIndex)
        }

        /// True if a character immediately preceding a tag opener should
        /// SUPPRESS that opener — i.e. the opener is glued to text that
        /// looks like the local part of an email address or similar
        /// word-continuation. Suppresses on ASCII letters / digits /
        /// `_` / `-` / `+` so that `john@example.com`, `v1.0+rc1`, etc.
        /// don't turn into tags. Non-ASCII characters (emoji, CJK,
        /// accented letters) deliberately do NOT suppress so that
        /// `🎯@user` and `张伟@user` still recognise the mention.
        func suppressesAdjacentTag(_ ch: Character) -> Bool {
            guard ch.isASCII else { return false }
            if ch.isLetter || ch.isNumber { return true }
            return ch == "_" || ch == "-" || ch == "+"
        }

        /// Parse a tag starting at ``index`` using ``prefix``. Routes between
        /// the paired form (``[[wiki]]``), the markdown-link form
        /// (``@[John](id)``), and the bare form (``@behlool``).
        func parseTag(at index: String.Index, prefix: TagPrefix) -> TagParseResult {
            // Left-boundary check — see suppressesAdjacentTag above.
            // Skip for beginning-of-buffer (no preceding char) and for paired
            // delimiters (their multi-char opening already provides a natural
            // boundary; "abc[[wiki]]" still recognises the wiki link).
            if index > text.startIndex, prefix.closing == nil {
                let prev = text[text.index(before: index)]
                if suppressesAdjacentTag(prev) {
                    return .literal
                }
            }

            let openingLength = prefix.opening.count
            guard let openEnd = text.index(index, offsetBy: openingLength, limitedBy: text.endIndex) else {
                return includeUnterminated ? .literal : .needMore
            }

            // ---- Paired form (e.g. [[wiki]]) ----
            if let closing = prefix.closing {
                // Look for the closing delimiter starting after the opening.
                guard let closeRange = text[openEnd..<text.endIndex].range(of: closing) else {
                    return includeUnterminated ? .literal : .needMore
                }
                let inner = String(text[openEnd..<closeRange.lowerBound])
                let identifier = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !identifier.isEmpty else { return .literal }
                // Reject if the inner content contains the OPENING delimiter
                // again — that's almost certainly malformed input, treat as literal.
                if inner.contains(prefix.opening) { return .literal }

                let nextIndex = closeRange.upperBound
                let raw = String(text[index..<nextIndex])
                let displayText = raw
                let tagPayload = Tag(prefix: prefix.opening,
                                     identifier: identifier,
                                     displayText: displayText,
                                     rawText: raw)
                let url = makePicoTagURL(prefix: prefix.opening, identifier: identifier)

                flushPlain(upTo: index)
                appendRun(InlineRun(text: displayText,
                                    style: [.tag, .link],
                                    linkURL: url,
                                    tag: tagPayload))
                consumedEnd = nextIndex
                plainStart = nextIndex
                return .handled(nextIndex: nextIndex)
            }

            // ---- Single-char opener: try the markdown-link form first ----
            if openEnd < text.endIndex, text[openEnd] == "[" {
                if let result = parseMarkdownLinkTagForm(openerStart: index,
                                                         prefix: prefix,
                                                         bracketStart: openEnd) {
                    return result
                }
                // nil → not the markdown-link form; fall through to bare scan.
            }

            // ---- Bare form: scan until terminator ----
            // Stop at: whitespace, any TagCharacterRules.hardStop, or the
            // opening character of any registered tag prefix (including the
            // current one — so "@beh@lool" splits into two tags).
            var cursor = openEnd
            while cursor < text.endIndex {
                let c = text[cursor]
                if c.isWhitespace { break }
                if TagCharacterRules.hardStop.contains(c) { break }
                if parserTagPrefixOpeningFirstChars.contains(c) { break }
                cursor = text.index(after: cursor)
            }

            // If we didn't consume any identifier characters, this isn't a tag.
            if cursor == openEnd { return .literal }

            // Streaming: if we hit the end of the buffer without a terminator,
            // wait for more — otherwise we might cut off a trailing-strip char
            // and miss the chance to keep it as a separator.
            if cursor == text.endIndex && !includeUnterminated {
                return .needMore
            }

            // Trailing-strip: walk back across .,:;!? so "@behlool!" leaves "!"
            // outside the tag identifier.
            var endIndex = cursor
            while endIndex > openEnd {
                let prevIndex = text.index(before: endIndex)
                if TagCharacterRules.trailingStrip.contains(text[prevIndex]) {
                    endIndex = prevIndex
                } else {
                    break
                }
            }
            // Reject tags consisting entirely of trailing-strip chars (e.g. "@.").
            if endIndex == openEnd { return .literal }

            let identifier = String(text[openEnd..<endIndex])
            let displayText = String(text[index..<endIndex])
            let rawText = displayText  // bare form: raw == display
            let tagPayload = Tag(prefix: prefix.opening,
                                 identifier: identifier,
                                 displayText: displayText,
                                 rawText: rawText)
            let url = makePicoTagURL(prefix: prefix.opening, identifier: identifier)

            flushPlain(upTo: index)
            appendRun(InlineRun(text: displayText,
                                style: [.tag, .link],
                                linkURL: url,
                                tag: tagPayload))
            consumedEnd = endIndex
            plainStart = endIndex
            return .handled(nextIndex: endIndex)
        }

        parsing: while index < text.endIndex {
            // Inline tag dispatch — fires before the normal switch so that
            // characters which also have other meanings (e.g. "$" is also a
            // math delimiter, "[" is also a link opener) prefer the tag form
            // only when the registered prefix actually matches. Skipped while
            // inside a math span — tags are not parsed inside TeX content.
            if mathState == nil, let prefix = matchingTagPrefix(at: index) {
                switch parseTag(at: index, prefix: prefix) {
                case .handled(let nextIndex):
                    index = nextIndex
                    continue parsing
                case .literal:
                    break  // fall through to the normal switch
                case .needMore:
                    // Mirror the strikethrough-streaming pattern: emit any
                    // plain text accumulated before the opener, then pause
                    // at the opener so the next chunk resumes from there.
                    flushPlain(upTo: index)
                    consumedEnd = index
                    plainStart = index
                    consumedAll = false
                    break parsing
                }
            }

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
                        // Inside \(...\) / \[...\], keep backslashes as TeX content unless
                        // they close the current math span. Do not apply Markdown escaping.
                        if nextIndex < text.endIndex {
                            index = nextIndex
                            continue parsing
                        }
                        if includeUnterminated {
                            index = nextIndex
                            continue parsing
                        } else {
                            consumedAll = false
                            break parsing
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
                if let htmlResult = parseInlineHTMLTag(at: index) {
                    switch htmlResult {
                    case .handled(let nextIndex):
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
            let remainder = replacements.drainLiteralTail()
            appendProcessed(remainder)
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

    static func parseAll(_ text: String,
                         tagPrefixes: Set<TagPrefix> = TagPrefix.defaults) -> [InlineRun] {
        var parser = InlineParser(tagPrefixes: tagPrefixes)
        parser.pending = text
        return parser.consume(includeUnterminated: true)
    }

    mutating func flushTrailingPeriods() -> [InlineRun] {
        var output = ""
        replacements.flushTrailingPeriods(into: &output)
        guard !output.isEmpty else { return [] }
        return makePlainRuns(from: output)
    }

    mutating func flushPendingTail() -> [InlineRun] {
        var output = ""
        replacements.flushPendingTail(into: &output)
        guard !output.isEmpty else { return [] }
        return makePlainRuns(from: output)
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
