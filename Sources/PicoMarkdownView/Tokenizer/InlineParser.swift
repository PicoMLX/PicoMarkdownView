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
    private var followsMathGrapheme = false
    /// The last character already emitted from an earlier chunk, so a marker
    /// at the start of the pending text keeps its intraword context (`a` then
    /// `_b_` is the identifier `a_b_`, not `a` and italic `b`).
    /// What the parser knows about the grapheme that ended the text consumed
    /// so far. `alphanumeric` and `whitespace` are exact for the whole
    /// grapheme (the only two things the parser asks of a preceding
    /// character); `tail` holds its last scalars, bounded, and serves only to
    /// tell whether the next chunk's first grapheme joins it.
    private struct ConsumedContext {
        /// The consumed text ended with a run of `*` or `_` that the next
        /// chunk may continue. A delimiter run is judged by the character
        /// before the whole run, so that character's class is kept (as a
        /// stand-in; `nil` is the start of the text).
        struct TrailingRun {
            var delimiter: Character
            var before: Character?
            /// Delimiters of the run consumed so far.
            var length: Int
        }
        var tail: String
        var alphanumeric: Bool
        var whitespace: Bool
        var punctuation: Bool
        var trailingRun: TrailingRun?
    }
    private var lastConsumed: ConsumedContext?

    /// The emphasis algorithm's scan for an opener that is waiting for more
    /// text (see `matchEmphasis`). The next chunk resumes it where it
    /// stopped instead of rescanning everything after the opener, which is
    /// then the start of `pending`. Positions are UTF-8 offsets from the
    /// opener.
    private struct EmphasisScan {
        struct Delimiter {
            var character: Character
            var start: Int
            var count: Int
            let originalCount: Int
            let canOpen: Bool
            let canClose: Bool
        }
        struct Pair {
            var closerStart: Int
            var closerEnd: Int
            var length: Int
        }
        /// The opener's offset in the text the scan was saved from; the scan
        /// is kept only if that text is consumed exactly up to the opener.
        var targetOffset: Int
        var cursor: Int
        /// One stack per delimiter character (`*`, `_`), each ordered by
        /// position. The opener is the bottom of its stack.
        var openers: [[Delimiter]]
        /// cmark's `openers_bottom`: per closer kind, the position below
        /// which no opener can pair with it.
        var searchFloor: [Int]
        /// The last (outermost so far) pair that took each opener's delimiters.
        var lastPairs: [Int: Pair]
        var usedUp: Set<Int>
        var earliestPairedOpener: Int?
    }
    private var emphasisScan: EmphasisScan?
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
            case command(closing: UInt8, display: Bool)
        }

        var delimiter: Delimiter
        var contentUTF8Offset: Int
        var openingMarker: String
        var resumeUTF8Offset: Int = 0
    }

    mutating func append(_ text: String) -> [InlineRun] {
        pending.append(text)
        return consume(includeUnterminated: false)
    }

    /// The ASCII punctuation characters a backslash can escape (CommonMark).
    private static let asciiPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars)

    /// Punctuation for emphasis flanking: ASCII punctuation or a Unicode
    /// punctuation (P) category, decided on the leading scalar. This is
    /// cmark-gfm's definition; symbols such as `£` are not punctuation.
    private static func isPunctuation(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.isASCII { return asciiPunctuation.contains(scalar) }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    mutating func finish() -> [InlineRun] {
        let runs = consume(includeUnterminated: true)
        pending.removeAll(keepingCapacity: true)
        replacements.reset()
        mathState = nil
        followsMathGrapheme = false
        lastConsumed = nil
        emphasisScan = nil
        return runs
    }

    private mutating func consume(includeUnterminated: Bool) -> [InlineRun] {
        var runs: [InlineRun] = []
        let text = pending
        var index = text.startIndex
        var plainStart = text.startIndex
        var consumedEnd = text.startIndex
        var consumedAll = true
        var mathGraphemeBoundary: String.Index? = followsMathGrapheme ? text.startIndex : nil
        if let state = mathState,
           let resume = text.utf8.index(text.utf8.startIndex, offsetBy: state.resumeUTF8Offset, limitedBy: text.utf8.endIndex) {
            index = resume
        }

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

        /// Text the replacement engine still holds (a possible `(c)` or
        /// `:smile:`) comes before a run that is not plain text, so it is
        /// released first; otherwise the run would overtake it. No
        /// replacement spans such a run.
        func settleReplacements() {
            appendProcessed(replacements.finish())
        }

        func appendStructured(_ run: InlineRun) {
            settleReplacements()
            runs.append(run)
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
            if let boundary = mathGraphemeBoundary, index <= boundary {
                return "$" // Both math closers are punctuation, even with trailing combining scalars.
            }
            guard index > text.startIndex else {
                // A stand-in with the exact class of the grapheme consumed
                // before this text; the class is all the callers ask of it.
                guard let context = lastConsumed else { return nil }
                if context.alphanumeric { return "a" }
                if context.whitespace { return " " }
                return context.punctuation ? "." : "©"
            }
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

        func mathContentIndex(_ state: InlineMathState) -> String.Index {
            text.utf8.index(text.utf8.startIndex, offsetBy: state.contentUTF8Offset)
        }

        func appendMathRun(_ tex: String, display: Bool) {
            let run = InlineRun(text: tex,
                                 style: [.math],
                                 math: MathInlinePayload(tex: tex, display: display))
            appendStructured(run)
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
            settleReplacements()
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

        /// Whether the character at `index` follows an odd run of backslashes.
        func isEscaped(_ index: String.Index) -> Bool {
            var backslashes = 0
            var cursor = index
            while cursor > text.startIndex {
                let previous = text.index(before: cursor)
                guard text[previous] == "\\" else { break }
                backslashes += 1
                cursor = previous
            }
            return backslashes % 2 == 1
        }

        /// The run of `text[index]` characters around `index`: a delimiter
        /// run (CommonMark) is judged as a whole. An escaped delimiter is
        /// text, not part of the run.
        func delimiterRun(containing index: String.Index) -> Range<String.Index> {
            let delimiter = text[index]
            var start = index
            while start > text.startIndex {
                let previous = text.index(before: start)
                guard text[previous] == delimiter, !isEscaped(previous) else { break }
                start = previous
            }
            var end = index
            while end < text.endIndex, text[end] == delimiter {
                end = text.index(after: end)
            }
            return start..<end
        }

        struct Flanking {
            var left: Bool
            var right: Bool
            var punctuationBefore: Bool
            var punctuationAfter: Bool
        }

        /// The character before a delimiter run, including a run that an
        /// earlier chunk began (`word_` delivered, then `_bar`).
        func characterBefore(run: Range<String.Index>) -> Character? {
            if run.lowerBound == text.startIndex, let trailing = lastConsumed?.trailingRun,
               trailing.delimiter == text[run.lowerBound] {
                return trailing.before
            }
            return character(before: run.lowerBound)
        }

        /// The length of a delimiter run, including delimiters of it that an
        /// earlier chunk consumed: the rule of three counts the whole run.
        func runLength(_ run: Range<String.Index>) -> Int {
            var length = text.distance(from: run.lowerBound, to: run.upperBound)
            if run.lowerBound == text.startIndex, let trailing = lastConsumed?.trailingRun,
               trailing.delimiter == text[run.lowerBound] {
                length += trailing.length
            }
            return length
        }

        /// CommonMark flanking of a delimiter run. The start and end of the
        /// text count as whitespace; `nil` while the character after the run
        /// has not arrived yet.
        func flanking(of run: Range<String.Index>) -> Flanking? {
            let before = characterBefore(run: run) ?? " "
            let after: Character
            if run.upperBound < text.endIndex {
                after = text[run.upperBound]
            } else if includeUnterminated {
                after = " "
            } else {
                return nil
            }
            let beforeIsSpace = isWhitespace(before), afterIsSpace = isWhitespace(after)
            let beforeIsPunctuation = Self.isPunctuation(before), afterIsPunctuation = Self.isPunctuation(after)
            return Flanking(
                left: !afterIsSpace && (!afterIsPunctuation || beforeIsSpace || beforeIsPunctuation),
                right: !beforeIsSpace && (!beforeIsPunctuation || afterIsSpace || afterIsPunctuation),
                punctuationBefore: beforeIsPunctuation,
                punctuationAfter: afterIsPunctuation
            )
        }

        func canOpen(_ delimiter: Character, _ flank: Flanking) -> Bool {
            delimiter == "*" ? flank.left : flank.left && (!flank.right || flank.punctuationBefore)
        }

        func canClose(_ delimiter: Character, _ flank: Flanking) -> Bool {
            delimiter == "*" ? flank.right : flank.right && (!flank.left || flank.punctuationAfter)
        }

        /// How far a construct that binds tighter than emphasis reaches.
        enum SpanScan {
            case end(String.Index)
            case none
            case needMore
        }

        /// The closing backtick run of exactly `delimiterLength` backticks
        /// after `start`: a longer or shorter run is code content.
        func findCodeClosing(delimiterLength: Int, from start: String.Index) -> Range<String.Index>? {
            var search = start
            while let tick = text[search...].firstIndex(of: "`") {
                var end = tick
                var length = 0
                while end < text.endIndex, text[end] == "`" {
                    length += 1
                    end = text.index(after: end)
                }
                if length == delimiterLength { return tick..<end }
                search = end
            }
            return nil
        }

        /// A code span opening at the backtick run at `index`. A closer at
        /// the end of the text may still grow into a longer run, so it waits.
        func codeSpanScan(at index: String.Index) -> SpanScan {
            var contentStart = index
            var length = 0
            while contentStart < text.endIndex, text[contentStart] == "`" {
                length += 1
                contentStart = text.index(after: contentStart)
            }
            guard let closing = findCodeClosing(delimiterLength: length, from: contentStart) else {
                return includeUnterminated ? .none : .needMore
            }
            if closing.upperBound == text.endIndex, !includeUnterminated { return .needMore }
            return .end(closing.upperBound)
        }

        enum AngleSpan {
            case autolink(end: String.Index, display: String, url: String)
            case html(end: String.Index)
            case none
            case needMore
        }

        /// A CommonMark autolink (`<scheme:…>`, `<user@host>`) or raw HTML
        /// construct starting at the `<` at `index`.
        func angleSpan(at index: String.Index) -> AngleSpan {
            let start = text.index(after: index)
            var cursor = start
            while cursor < text.endIndex {
                let character = text[cursor]
                if character == ">" || character == "<" || character.isWhitespace
                    || character.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                    break
                }
                cursor = text.index(after: cursor)
            }
            var autolinkPending = false
            if cursor < text.endIndex, text[cursor] == ">" {
                let candidate = String(text[start..<cursor])
                let end = text.index(after: cursor)
                if isURIAutolink(candidate) {
                    return .autolink(end: end, display: candidate, url: candidate)
                }
                if isEmailAutolink(candidate) {
                    return .autolink(end: end, display: candidate, url: "mailto:" + candidate)
                }
            } else if cursor == text.endIndex {
                autolinkPending = !includeUnterminated
            }
            switch htmlScan(at: index) {
            case .end(let end): return .html(end: end)
            case .needMore: return .needMore
            case .none: return autolinkPending ? .needMore : .none
            }
        }

        func isURIAutolink(_ candidate: String) -> Bool {
            guard let colon = candidate.firstIndex(of: ":") else { return false }
            let scheme = candidate[..<colon]
            guard (2...32).contains(scheme.count), let first = scheme.first, first.isASCII, first.isLetter else { return false }
            return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-") }
        }

        func isEmailAutolink(_ candidate: String) -> Bool {
            let parts = candidate.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
            let localAllowed = Set(".!#$%&'*+/=?^_`{|}~-")
            guard parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || localAllowed.contains($0)) }) else { return false }
            return parts[1].split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                guard (1...63).contains(label.count), let first = label.first, let last = label.last else { return false }
                let alphanumeric: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
                return alphanumeric(first) && alphanumeric(last) && label.allSatisfy { alphanumeric($0) || $0 == "-" }
            }
        }

        /// Raw HTML (CommonMark): an open or closing tag, a comment, a
        /// processing instruction, a declaration or a CDATA section.
        func htmlScan(at index: String.Index) -> SpanScan {
            let pending: SpanScan = includeUnterminated ? .none : .needMore
            var cursor = text.index(after: index)
            func atEnd() -> Bool { cursor >= text.endIndex }
            func advance() { cursor = text.index(after: cursor) }
            func isTagNameCharacter(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "-") }
            func skipWhitespace() -> Bool {
                let before = cursor
                while !atEnd(), text[cursor].isWhitespace { advance() }
                return cursor > before
            }
            /// The end of the first `terminator` at or after the cursor.
            func scan(through terminator: String) -> SpanScan {
                guard let range = text[cursor...].range(of: terminator) else { return pending }
                return .end(range.upperBound)
            }
            guard !atEnd() else { return pending }
            let first = text[cursor]
            if first == "!" {
                advance()
                if text[cursor...].hasPrefix("--") {
                    cursor = text.index(cursor, offsetBy: 2)
                    return scan(through: "-->")
                }
                if text[cursor...].hasPrefix("[CDATA[") {
                    return scan(through: "]]>")
                }
                if "--".hasPrefix(text[cursor...]) || "[CDATA[".hasPrefix(text[cursor...]) { return pending }
                guard text[cursor].isASCII, text[cursor].isLetter else { return .none }
                return scan(through: ">")
            }
            if first == "?" {
                advance()
                return scan(through: "?>")
            }
            if first == "/" {
                advance()
                guard !atEnd() else { return pending }
                guard text[cursor].isASCII, text[cursor].isLetter else { return .none }
                while !atEnd(), isTagNameCharacter(text[cursor]) { advance() }
                _ = skipWhitespace()
                guard !atEnd() else { return pending }
                return text[cursor] == ">" ? .end(text.index(after: cursor)) : .none
            }
            guard first.isASCII, first.isLetter else { return .none }
            while !atEnd(), isTagNameCharacter(text[cursor]) { advance() }
            while true {
                let spaced = skipWhitespace()
                guard !atEnd() else { return pending }
                let character = text[cursor]
                if character == ">" { return .end(text.index(after: cursor)) }
                if character == "/" {
                    advance()
                    guard !atEnd() else { return pending }
                    return text[cursor] == ">" ? .end(text.index(after: cursor)) : .none
                }
                // An attribute needs whitespace before it.
                guard spaced, character.isASCII, character.isLetter || character == "_" || character == ":" else { return .none }
                while !atEnd(), text[cursor].isASCII,
                      text[cursor].isLetter || text[cursor].isNumber || "_.:-".contains(text[cursor]) {
                    advance()
                }
                let beforeValue = cursor
                _ = skipWhitespace()
                guard !atEnd() else { return pending }
                guard text[cursor] == "=" else {
                    cursor = beforeValue
                    continue
                }
                advance()
                _ = skipWhitespace()
                guard !atEnd() else { return pending }
                let quote = text[cursor]
                if quote == "\"" || quote == "'" {
                    advance()
                    guard let close = text[cursor...].firstIndex(of: quote) else { return pending }
                    cursor = text.index(after: close)
                } else {
                    let valueStart = cursor
                    while !atEnd(), !text[cursor].isWhitespace, !"\"'=<>`".contains(text[cursor]) { advance() }
                    guard cursor > valueStart else { return .none }
                }
            }
        }

        enum EmphasisMatch {
            /// After `literalPrefix` delimiters that stay text, the opener's
            /// leftmost delimiters pair with `closer`, as emphasis (`length`
            /// 1) or strong emphasis (2).
            case matched(closer: Range<String.Index>, length: Int, literalPrefix: Int)
            /// No delimiter of the opener pairs: the run is text.
            case none
            case needMore
        }

        /// What a scan that reached the end of the final text found for every
        /// opener it saw. A later scan from one of those openers would find
        /// the same, provided no pair in the scan used an opener before it:
        /// the runs before it were then inert and the processing from it on
        /// is identical. Openers that never pair are thus resolved once, not
        /// rescanned each (`*a *a … c*`). Positions are UTF-8 offsets.
        struct EmphasisOutcomes {
            var earliestPairedOpener: Int?
            var results: [Int: EmphasisMatch]
        }
        var emphasisOutcomes: EmphasisOutcomes?

        func utf8Offset(of position: String.Index) -> Int {
            text.utf8.distance(from: text.utf8.startIndex, to: position)
        }

        /// CommonMark's emphasis algorithm over the delimiter runs from the
        /// opener at `index` on: closers are processed left to right, each
        /// pairing with the nearest eligible opener (rule of three, two
        /// delimiters when both sides have them), and the answer is the pair
        /// that consumes the opener's leftmost delimiter. Code spans,
        /// autolinks and raw HTML bind tighter, and an escaped delimiter is
        /// text, so none of them holds a delimiter. Every decision depends
        /// only on the text before the deciding closer, so a match that
        /// takes the leftmost delimiter is final once found. Delimiters left
        /// unpaired at the left of the run are known only once the text is
        /// final; the last pair that took any of the opener's delimiters is
        /// then the outermost, and the run is resolved in one scan.
        ///
        /// While the text may still grow, a scan that cannot decide yet is
        /// saved (`emphasisScan`) and the next chunk resumes it from where it
        /// stopped, so a waiting opener costs only the new text.
        func matchEmphasis(openerAt index: String.Index, flank: Flanking) -> EmphasisMatch {
            typealias Delimiter = EmphasisScan.Delimiter
            let base = utf8Offset(of: index)
            if let outcomes = emphasisOutcomes, let known = outcomes.results[base],
               outcomes.earliestPairedOpener.map({ $0 >= base }) ?? true {
                return known
            }
            func position(_ offset: Int) -> String.Index {
                text.utf8.index(text.utf8.startIndex, offsetBy: base + offset)
            }
            func offset(_ position: String.Index) -> Int { utf8Offset(of: position) - base }
            // One stack per delimiter character (`*`, `_`): a closer only ever
            // looks at its own character's openers.
            func slot(_ character: Character) -> Int { character == "*" ? 0 : 1 }
            let delimiter = text[index]
            let targetSlot = slot(delimiter)
            // A scan saved by an earlier chunk resumes when its opener is this
            // one, now at the start of the text (see the end of `consume`).
            var resumed = base == 0 ? emphasisScan : nil
            emphasisScan = nil
            var scan: EmphasisScan
            if resumed != nil {
                scan = resumed!
                resumed = nil
            } else {
                let openerRun = delimiterRun(containing: index)
                scan = EmphasisScan(targetOffset: base, cursor: offset(openerRun.upperBound), openers: [[], []],
                                    searchFloor: Array(repeating: Int.min, count: 12),
                                    lastPairs: [:], usedUp: [], earliestPairedOpener: nil)
                scan.openers[targetSlot].append(Delimiter(character: delimiter,
                                                          start: 0,
                                                          count: text.distance(from: index, to: openerRun.upperBound),
                                                          originalCount: runLength(openerRun),
                                                          canOpen: true,
                                                          canClose: canClose(delimiter, flank)))
            }
            func suspend(at stop: String.Index) -> EmphasisMatch {
                scan.cursor = offset(stop)
                scan.targetOffset = base
                emphasisScan = scan
                return .needMore
            }
            func ruleOfThreeForbids(_ opener: Delimiter, _ closer: Delimiter) -> Bool {
                (opener.canClose || closer.canOpen)
                    && (opener.originalCount + closer.originalCount) % 3 == 0
                    && !(opener.originalCount % 3 == 0 && closer.originalCount % 3 == 0)
            }
            var cursor = position(scan.cursor)
            while cursor < text.endIndex {
                let character = text[cursor]
                if character == "\\" {
                    let escaped = text.index(after: cursor)
                    if escaped == text.endIndex {
                        // What the backslash escapes has not arrived: a resumed
                        // scan must see the pair together.
                        if !includeUnterminated { return suspend(at: cursor) }
                        cursor = escaped
                        continue
                    }
                    cursor = text.index(after: escaped)
                    continue
                }
                if character == "`" {
                    switch codeSpanScan(at: cursor) {
                    case .end(let end): cursor = end
                    case .needMore: return suspend(at: cursor)
                    case .none: cursor = delimiterRun(containing: cursor).upperBound
                    }
                    continue
                }
                if character == "<" {
                    switch angleSpan(at: cursor) {
                    case .autolink(let end, _, _), .html(let end): cursor = end
                    case .needMore: return suspend(at: cursor)
                    case .none: cursor = text.index(after: cursor)
                    }
                    continue
                }
                if character == "*" || character == "_" {
                    let run = delimiterRun(containing: cursor)
                    guard let runFlank = flanking(of: run) else { return suspend(at: run.lowerBound) }
                    let length = text.distance(from: run.lowerBound, to: run.upperBound)
                    var closer = Delimiter(character: character, start: offset(run.lowerBound), count: length,
                                           originalCount: length,
                                           canOpen: canOpen(character, runFlank),
                                           canClose: canClose(character, runFlank))
                    let own = slot(character)
                    if closer.canClose {
                        // Whether an opener can pair with a closer depends only on
                        // the closer's character, whether it can open, and its
                        // length mod 3. After a search for such a closer fails,
                        // every opener then on the stack is known not to pair with
                        // any closer of that kind (cmark's `openers_bottom`).
                        let kind = own * 6 + (closer.canOpen ? 3 : 0) + closer.originalCount % 3
                        while closer.count > 0 {
                            var openerIndex = scan.openers[own].count - 1
                            while openerIndex >= 0, scan.openers[own][openerIndex].start >= scan.searchFloor[kind],
                                  ruleOfThreeForbids(scan.openers[own][openerIndex], closer) {
                                openerIndex -= 1
                            }
                            guard openerIndex >= 0, scan.openers[own][openerIndex].start >= scan.searchFloor[kind] else {
                                scan.searchFloor[kind] = closer.start
                                break
                            }
                            let used = closer.count >= 2 && scan.openers[own][openerIndex].count >= 2 ? 2 : 1
                            // Delimiters are ASCII: one UTF-8 byte each.
                            let closerEnd = closer.start + used
                            // The opener at `index` pairs here once this match
                            // takes its leftmost (outermost) delimiters.
                            if own == targetSlot, openerIndex == 0, scan.openers[own][0].count == used {
                                return .matched(closer: position(closer.start)..<position(closerEnd), length: used, literalPrefix: 0)
                            }
                            let openerStart = scan.openers[own][openerIndex].start
                            scan.lastPairs[openerStart] = EmphasisScan.Pair(closerStart: closer.start, closerEnd: closerEnd, length: used)
                            scan.earliestPairedOpener = min(scan.earliestPairedOpener ?? openerStart, openerStart)
                            scan.openers[own][openerIndex].count -= used
                            // Openers between the pair, of either character,
                            // can no longer match.
                            scan.openers[own].removeSubrange((openerIndex + 1)...)
                            while let top = scan.openers[1 - own].last, top.start > openerStart {
                                scan.openers[1 - own].removeLast()
                            }
                            if scan.openers[own][openerIndex].count == 0 {
                                scan.openers[own].remove(at: openerIndex)
                                scan.usedUp.insert(openerStart)
                            }
                            closer.start = closerEnd
                            closer.count -= used
                        }
                    }
                    if closer.count > 0, closer.canOpen { scan.openers[own].append(closer) }
                    cursor = run.upperBound
                    continue
                }
                cursor = text.index(after: cursor)
            }
            guard includeUnterminated else { return suspend(at: text.endIndex) }
            // The text is final: an opener still on a stack keeps its
            // unpaired delimiters at the left as text; one used up pairs
            // whole. (An opener dropped between a pair is not recorded.)
            func matched(_ pair: EmphasisScan.Pair, literalPrefix: Int) -> EmphasisMatch {
                .matched(closer: position(pair.closerStart)..<position(pair.closerEnd), length: pair.length, literalPrefix: literalPrefix)
            }
            var results: [Int: EmphasisMatch] = [:]
            for stack in scan.openers {
                for opener in stack {
                    results[base + opener.start] = scan.lastPairs[opener.start].map { matched($0, literalPrefix: opener.count) } ?? EmphasisMatch.none
                }
            }
            for start in scan.usedUp {
                if let pair = scan.lastPairs[start] { results[base + start] = matched(pair, literalPrefix: 0) }
            }
            emphasisOutcomes = EmphasisOutcomes(earliestPairedOpener: scan.earliestPairedOpener.map { base + $0 }, results: results)
            return results[base] ?? .none
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
                    appendStructured(run)
                    consumedEnd = afterBracket
                    plainStart = afterBracket
                    return .handled(nextIndex: afterBracket)
                }
                return .literal
            }
            guard afterBracket < text.endIndex else {
                // `[label]` at the end of the buffer may still be followed by
                // `(url)` in the next chunk; wait unless flushing.
                return includeUnterminated ? .literal : .incomplete
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
                appendStructured(InlineRun(text: label, style: [.image], image: InlineImage(source: destination, title: title)))
            } else {
                appendStructured(InlineRun(text: label, style: [.link], linkURL: destination))
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
                appendStructured(InlineRun(text: label, style: [.image], image: InlineImage(source: definition.url, title: definition.title)))
            } else {
                appendStructured(InlineRun(text: label, style: [.link], linkURL: definition.url))
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
            // Math delimiters are ASCII. Scan their bytes directly so a saved
            // cursor remains valid when a new chunk extends the last grapheme.
            // Only a trailing escape or partial closer stays unresolved.
            if let state = mathState {
                let bytes = text.utf8
                let byte = bytes[index]
                let next = bytes.index(after: index)
                var closerEnd: String.Index?
                var display = false
                switch state.delimiter {
                case .dollar(let count, let isDisplay):
                    display = isDisplay
                    if byte == 0x5C {
                        if next == bytes.endIndex && !includeUnterminated {
                            consumedAll = false
                            break parsing
                        }
                        index = next < bytes.endIndex ? bytes.index(after: next) : next
                        continue parsing
                    }
                    if byte == 0x24 {
                        var cursor = index
                        var length = 0
                        while cursor < bytes.endIndex, bytes[cursor] == 0x24, length < count {
                            length += 1
                            cursor = bytes.index(after: cursor)
                        }
                        if length == count {
                            closerEnd = cursor
                        } else if cursor == bytes.endIndex && !includeUnterminated {
                            consumedAll = false
                            break parsing
                        }
                    }
                case .command(let closing, let isDisplay):
                    display = isDisplay
                    if byte == 0x5C {
                        if next == bytes.endIndex && !includeUnterminated {
                            consumedAll = false
                            break parsing
                        }
                        if next < bytes.endIndex, bytes[next] == closing {
                            closerEnd = bytes.index(after: next)
                        }
                    }
                }
                if let afterClose = closerEnd {
                    appendMathRun(String(text[mathContentIndex(state)..<index]), display: display)
                    consumedEnd = afterClose
                    index = afterClose
                    plainStart = afterClose
                    mathState = nil
                    mathGraphemeBoundary = afterClose
                } else {
                    index = next
                }
                continue parsing
            }
            // Drain only scalars extending the ASCII closer. Keep its flanking
            // context across chunks without retaining or rescanning emitted text.
            if index == mathGraphemeBoundary {
                let scalar = text.unicodeScalars[index]
                if scalar.properties.isGraphemeExtend || scalar.value == 0x200D ||
                    scalar.properties.generalCategory == .spacingMark {
                    index = text.unicodeScalars.index(after: index)
                    mathGraphemeBoundary = index
                    continue parsing
                }
            }
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

            // Opening markers have the same byte boundaries as closers, even
            // when the following scalar joins a marker's grapheme cluster.
            let bytes = text.utf8
            let byte = bytes[index]
            if byte == 0x24 {
                var length = 1
                var cursor = bytes.index(after: index)
                while cursor < bytes.endIndex, bytes[cursor] == 0x24 && length < 2 {
                    length += 1
                    cursor = bytes.index(after: cursor)
                }
                if length == 1 && cursor == bytes.endIndex && !includeUnterminated {
                    flushPlain(upTo: index)
                    consumedAll = false
                    break parsing
                }
                flushPlain(upTo: index)
                let markerEnd = cursor
                let marker = String(text[index..<markerEnd])
                consumedEnd = markerEnd
                mathState = InlineMathState(
                    delimiter: .dollar(count: length, display: length == 2),
                    contentUTF8Offset: text.utf8.distance(from: text.utf8.startIndex, to: markerEnd),
                    openingMarker: marker
                )
                plainStart = markerEnd
                index = markerEnd
                continue parsing
            }
            if byte == 0x5C {
                let next = bytes.index(after: index)
                if next < bytes.endIndex, bytes[next] == 0x28 || bytes[next] == 0x5B {
                    flushPlain(upTo: index)
                    let display = bytes[next] == 0x5B
                    let markerEnd = bytes.index(after: next)
                    consumedEnd = markerEnd
                    mathState = InlineMathState(
                        delimiter: .command(closing: display ? 0x5D : 0x29, display: display),
                        contentUTF8Offset: bytes.distance(from: bytes.startIndex, to: markerEnd),
                        openingMarker: String(text[index..<markerEnd])
                    )
                    plainStart = markerEnd
                    index = markerEnd
                    continue parsing
                }
            }

            let ch = text[index]
            switch ch {
            case "\\":
                let nextIndex = text.index(after: index)
                if nextIndex >= text.endIndex {
                    if includeUnterminated {
                        // A trailing backslash is plain text, together with
                        // whatever plain text is still pending before it
                        // (such as a `[label]` that waited for a `(`).
                        index = nextIndex
                        continue parsing
                    } else {
                        consumedAll = false
                        break parsing
                    }
                }
                flushPlain(upTo: index)
                let escaped = text[nextIndex]
                // Only ASCII punctuation can be escaped (CommonMark); before
                // anything else the backslash is literal. A backslash before
                // a newline stays a hard break. The decision is made on the
                // leading scalar: a combining mark or variation selector may
                // make the Character non-ASCII while the punctuation stays
                // escapable (`\*` + U+0301, an escaped keycap `\#️⃣`).
                let leading = escaped.unicodeScalars.first!
                if escaped == "\n" || (leading.isASCII && Self.asciiPunctuation.contains(leading)) {
                    appendPlain(String(escaped))
                } else {
                    appendPlain("\\" + String(escaped))
                }
                let after = text.index(after: nextIndex)
                consumedEnd = after
                index = after
                plainStart = after
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
                // Whether the run opens depends on the characters around the
                // whole run (CommonMark flanking).
                let run = delimiterRun(containing: index)
                guard let flank = flanking(of: run) else {
                    // The character after the run has not arrived. A `_`
                    // after a letter or digit never opens (intraword), so
                    // `word_` streams as text; anything else waits. Text
                    // before the run is settled and is delivered now, so
                    // repeated ambiguous chunks neither delay it nor rescan it.
                    if delimiter == "_", characterBefore(run: run).map(isAlphanumeric) ?? false {
                        index = run.upperBound
                        continue parsing
                    }
                    flushPlain(upTo: index)
                    consumedAll = false
                    break parsing
                }
                if !canOpen(delimiter, flank) {
                    // No delimiter of the run can open: it is text.
                    index = run.upperBound
                    continue parsing
                }
                let closingRange: Range<String.Index>
                let markerLength: Int
                switch matchEmphasis(openerAt: index, flank: flank) {
                case .matched(let closer, let length, let literalPrefix):
                    // Unpaired delimiters at the left of the run are text
                    // (`**foo*` reads `*` then emphasis).
                    index = text.index(index, offsetBy: literalPrefix)
                    closingRange = closer
                    markerLength = length
                case .none:
                    index = run.upperBound
                    continue parsing
                case .needMore:
                    // Text before the opener is settled and is delivered now.
                    // The opener then starts the pending text, where the next
                    // chunk resumes its saved scan.
                    flushPlain(upTo: index)
                    consumedAll = false
                    break parsing
                }
                flushPlain(upTo: index)
                let innerStart = text.index(index, offsetBy: markerLength)
                let inner = String(text[innerStart..<closingRange.lowerBound])
                let style: InlineStyle = markerLength == 2 ? [.bold] : [.italic]
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
                        index = cursor
                        continue parsing
                    } else {
                        consumedAll = false
                        break parsing
                    }
                }
                // A closing run at the end of the text may still grow into a
                // longer run, which would be content (`` `a` `` then `` ` ``).
                if closingRange.upperBound == text.endIndex, !includeUnterminated {
                    consumedAll = false
                    break parsing
                }
                flushPlain(upTo: index)
                // Line endings inside a code span are spaces (CommonMark); this
                // also covers a hard-break newline the block layer inserted
                // before it could know the line ended inside a span.
                var inner = String(text[contentStart..<closingRange.lowerBound]).replacingOccurrences(of: "\n", with: " ")
                // One space is stripped from each side when both are spaces and
                // the content is not only spaces (`` ` `` `` ` `` reads ``` `` ```).
                if inner.count >= 2, inner.first == " ", inner.last == " ", inner.contains(where: { $0 != " " }) {
                    inner = String(inner.dropFirst().dropLast())
                }
                appendStructured(InlineRun(text: inner, style: [.code]))
                let afterClose = closingRange.upperBound
                consumedEnd = afterClose
                index = afterClose
                plainStart = afterClose
            case "h", "H", "w", "W":
                if let result = parseAutolink(at: index) {
                    switch result {
                    case .handled(let nextIndex, let display, let url):
                        flushPlain(upTo: index)
                        appendStructured(InlineRun(text: display, style: [.link], linkURL: url))
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
                        appendStructured(InlineRun(text: "\n"))
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
                        appendStructured(InlineRun(text: display, style: [.link], linkURL: url))
                        consumedEnd = nextIndex
                        index = nextIndex
                        plainStart = nextIndex
                        continue parsing
                    case .needMore:
                        consumedAll = false
                        break parsing
                    }
                }
                switch angleSpan(at: index) {
                case .autolink(let end, let display, let url):
                    flushPlain(upTo: index)
                    appendStructured(InlineRun(text: display, style: [.link], linkURL: url))
                    consumedEnd = end
                    index = end
                    plainStart = end
                    continue parsing
                case .html(let end):
                    // Raw HTML stays text, but nothing inside it is markup:
                    // a backtick or `*` in an attribute opens nothing.
                    index = end
                    continue parsing
                case .needMore:
                    consumedAll = false
                    break parsing
                case .none:
                    break
                }
                index = text.index(after: index)
            default:
                index = text.index(after: index)
            }
        }

        if var state = mathState {
            state.resumeUTF8Offset = text.utf8.distance(from: text.utf8.startIndex, to: index)
            mathState = state
            consumedAll = false
        }

        if includeUnterminated, let state = mathState {
            let contentIndex = mathContentIndex(state)
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

        followsMathGrapheme = mathState == nil && index == mathGraphemeBoundary

        // A saved emphasis scan resumes only if the pending text will start
        // exactly at its opener.
        if let scan = emphasisScan, scan.targetOffset != utf8Offset(of: consumedEnd) {
            emphasisScan = nil
        }

        if consumedEnd > text.startIndex {
            let consumedBytes = text.utf8.distance(from: text.utf8.startIndex, to: consumedEnd)
            // The whole preceding grapheme (`❤️`, not its trailing variation
            // selector, which would read as alphanumeric). `consumedEnd` may
            // sit inside a grapheme when math resumes at a scalar boundary;
            // slicing then yields the scalars before it as the last Character.
            // A chunk may extend the grapheme consumed before it (`❤` then
            // U+FE0F), so the remembered Character is the last grapheme of
            // the previous context joined with the consumed tail. Both sides
            // are capped at 32 scalars: a run of combining marks arriving one
            // per chunk keeps its flanking class (marks are alphanumeric) but
            // must not grow the retained context, or every append would
            // rebuild it.
            // The class of the last consumed grapheme is tracked exactly and
            // separately from the scalars kept for joining, so no bound on
            // the retained text can change it. A single consumed grapheme
            // that joins the previous one (`❤` then U+FE0F, a Prepend
            // character then its letter, a mark after a letter) extends the
            // class by AND; anything else starts a fresh one.
            // The joining tail keeps what grapheme breaking can look back
            // at: every base scalar, and each distinct extending scalar
            // (marks, joiners, Indic linkers) once, at its last position. A
            // run of forty identical marks after a linker collapses to one,
            // so the linker stays visible to the next consonant, while the
            // tail stays bounded (at most 64 scalars are kept).
            func joiningTail(of character: Character) -> String {
                var kept: [Unicode.Scalar] = []
                var seenExtending = Set<Unicode.Scalar>()
                for scalar in character.unicodeScalars.reversed() {
                    if scalar.properties.isGraphemeExtend {
                        guard seenExtending.insert(scalar).inserted else { continue }
                    }
                    kept.append(scalar)
                    if kept.count == 64 { break }
                }
                var view = String.UnicodeScalarView()
                view.append(contentsOf: kept.reversed())
                return String(view)
            }
            let consumed = text[..<consumedEnd]
            if let last = consumed.last {
                let alphanumeric = isAlphanumeric(last)
                let whitespace = isWhitespace(last)
                let punctuation = Self.isPunctuation(last)
                // A trailing delimiter run keeps the class of the character
                // before it, carried over when the run began even earlier.
                var trailingRun: ConsumedContext.TrailingRun?
                // `consumedEnd` may sit inside a grapheme (math resumes at a
                // scalar boundary), so the last character is found within
                // the consumed slice, and only for a delimiter, which is a
                // whole grapheme.
                if last == "*" || last == "_", case let lastIndex = consumed.index(before: consumed.endIndex), !isEscaped(lastIndex) {
                    var runStart = lastIndex
                    while runStart > text.startIndex {
                        let previous = text.index(before: runStart)
                        guard text[previous] == last, !isEscaped(previous) else { break }
                        runStart = previous
                    }
                    let consumedLength = text.distance(from: runStart, to: consumedEnd)
                    if runStart == text.startIndex, var previous = lastConsumed?.trailingRun, previous.delimiter == last {
                        previous.length += consumedLength
                        trailingRun = previous
                    } else {
                        let before = character(before: runStart)
                        let standIn: Character? = before.map { character in
                            if isAlphanumeric(character) { return "a" }
                            if isWhitespace(character) { return " " }
                            return Self.isPunctuation(character) ? "." : "©"
                        }
                        trailingRun = ConsumedContext.TrailingRun(delimiter: last, before: standIn, length: consumedLength)
                    }
                }
                if let previous = lastConsumed, consumed.dropFirst().isEmpty,
                   let merged = (previous.tail + String(last)).last,
                   (previous.tail + String(last)).count < previous.tail.count + 1 {
                    // A joined grapheme keeps the class of its leading scalar
                    // for punctuation, as `isPunctuation` decides.
                    lastConsumed = ConsumedContext(tail: joiningTail(of: merged),
                                                   alphanumeric: previous.alphanumeric && alphanumeric,
                                                   whitespace: previous.whitespace && whitespace,
                                                   punctuation: previous.punctuation,
                                                   trailingRun: trailingRun)
                } else {
                    lastConsumed = ConsumedContext(tail: joiningTail(of: last), alphanumeric: alphanumeric,
                                                   whitespace: whitespace, punctuation: punctuation,
                                                   trailingRun: trailingRun)
                }
            }
            pending = String(text[consumedEnd...])
            if var state = mathState {
                state.contentUTF8Offset = max(0, state.contentUTF8Offset - consumedBytes)
                state.resumeUTF8Offset = max(0, state.resumeUTF8Offset - consumedBytes)
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
