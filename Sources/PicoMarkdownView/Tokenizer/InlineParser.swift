import Foundation

struct LinkDefinition: Equatable {
    let url: String
    let title: String?
}

final class LinkReferenceStore {
    private var definitions: [String: LinkDefinition] = [:]
    /// Labels the text used as references before anything defined them:
    /// those references went out as text.
    private var usedUndefined: Set<String> = []

    func define(label: String, url: String, title: String?) {
        let key = normalizeLinkLabel(label)
        guard definitions[key] == nil else { return }
        definitions[key] = LinkDefinition(url: url, title: title)
    }

    func resolve(label: String) -> LinkDefinition? {
        definitions[normalizeLinkLabel(label)]
    }

    /// A reference to `label` found no definition and went out as text.
    func noteUndefined(label: String) {
        usedUndefined.insert(normalizeLinkLabel(label))
    }

    /// Whether a definition of `label` would come too late for references
    /// already shown as text: the text used it, and nothing defines it yet.
    func isUsedUndefined(label: String) -> Bool {
        let key = normalizeLinkLabel(label)
        return definitions[key] == nil && usedUndefined.contains(key)
    }

    private func normalizeLinkLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "\n" || $0 == "\r" })
        // Labels match by Unicode case folding (`ẞ` matches `SS`).
        return parts.joined(separator: " ").folding(options: .caseInsensitive, locale: nil)
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
        /// A pair the algorithm formed: the opener's and the closer's
        /// delimiters it took, and whether it is emphasis (1) or strong (2).
        struct Pair {
            var openerStart: Int
            var openerEnd: Int
            var closerStart: Int
            var closerEnd: Int
            var length: Int

            func shifted(by delta: Int) -> Pair {
                Pair(openerStart: openerStart + delta, openerEnd: openerEnd + delta,
                     closerStart: closerStart + delta, closerEnd: closerEnd + delta, length: length)
            }
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
        /// Every pair formed so far, in the order they formed.
        var pairs: [Pair]
    }
    private var emphasisScan: EmphasisScan?

    /// What the delimiter algorithm decided for a delimiter of emphasis
    /// content (see `emphasisPlan`).
    private enum EmphasisAction {
        case open(pair: Int, length: Int, style: InlineStyle)
        case close(pair: Int, length: Int)
    }

    /// For the nested parse of emphasis content: the pairs the delimiter
    /// algorithm formed inside it, by UTF-8 offset into the content. The
    /// content is styled by them instead of matching its delimiters again,
    /// so nesting costs neither another parse nor another parser per level.
    private var emphasisPlan: [Int: EmphasisAction]?

    /// Where the raw HTML grammar stands after the bytes seen so far. The
    /// grammar is ASCII and is read by bytes, so a mark or Prepend character
    /// that shares a grapheme with a `>` or quote does not hide it.
    private enum HTMLState: Equatable {
        case begin
        case bang
        /// Right after `<!--`: `>` or `->` already ends the comment.
        case commentStart
        case terminator([UInt8])
        case closingStart
        case closingName
        case closingSpace
        case tagName
        case attributes(spaced: Bool)
        case attributeName
        case afterAttributeName
        case beforeValue
        case quoted(UInt8)
        case unquoted
        case slash
        case notHTML
    }

    /// How far the search for the end of a construct that binds tighter than
    /// emphasis got when the text ran out: raw HTML or an autolink after a
    /// `<`, a code span, or inline math. The next chunk continues it instead
    /// of searching from the construct's start again, whichever of the main
    /// loop and the emphasis lookahead asks. Offsets are UTF-8 offsets into
    /// `pending`.
    private struct ConstructProgress {
        enum Kind {
            /// The autolink candidate is checked up to `autolinkCursor`, and
            /// the HTML grammar stands at `html` at `htmlCursor`.
            case angle(autolinkCursor: Int, html: HTMLState, htmlCursor: Int)
            case codeSpan(resume: Int)
            case math(resume: Int)
            /// A `<kbd>`, `<sup>` or `<sub>` element's closing tag is
            /// searched from `resume`.
            case element(resume: Int)
        }
        var start: Int
        var kind: Kind

        /// The progress after `delta` bytes were consumed from the front of
        /// `pending`, or `nil` once the construct itself was consumed.
        func shifted(by delta: Int) -> ConstructProgress? {
            guard start >= delta else { return nil }
            let kind: Kind
            switch self.kind {
            case .angle(let autolinkCursor, let html, let htmlCursor):
                kind = .angle(autolinkCursor: autolinkCursor - delta, html: html, htmlCursor: htmlCursor - delta)
            case .codeSpan(let resume):
                kind = .codeSpan(resume: resume - delta)
            case .math(let resume):
                kind = .math(resume: resume - delta)
            case .element(let resume):
                kind = .element(resume: resume - delta)
            }
            return ConstructProgress(start: start - delta, kind: kind)
        }
    }
    private var constructProgress: ConstructProgress?

    /// A bracket scan (see `bracket(at:)` in `consume`) that ran out of
    /// text: its open brackets and where it stopped, as UTF-8 offsets. The
    /// next chunk resumes it rather than scanning again from the opener.
    private struct BracketProgress {
        struct Opener {
            var offset: Int
            var image: Bool
        }
        var start: Int
        var openers: [Opener]
        var deactivatedBelow: Int
        var cursor: Int

        func shifted(by delta: Int) -> BracketProgress? {
            guard start >= delta else { return nil }
            return BracketProgress(start: start - delta,
                                   openers: openers.map { Opener(offset: $0.offset - delta, image: $0.image) },
                                   deactivatedBelow: deactivatedBelow,
                                   cursor: cursor - delta)
        }
    }
    private var bracketProgress: BracketProgress?

    /// For the nested parse of emphasis content: what follows the content in
    /// the enclosing text, which is the closer. Flanking at the content's end
    /// reads it instead of the end of the text, and a delimiter run there
    /// that continues into the closer's run is judged as that whole run, as
    /// the delimiter algorithm sees it in the enclosing text. (What precedes
    /// the content arrives the same way, as `lastConsumed`.)
    private struct FollowingContext {
        /// The first code point after the content: the closer's delimiter.
        var scalar: Unicode.Scalar
        var delimiter: Character
        /// Delimiters of the closer's run from the content's end on.
        var runLength: Int
        /// The first code point after the closer's run; `nil` is the end.
        var afterRun: Unicode.Scalar?
    }
    private var following: FollowingContext?
    /// This parser reads content inside a link's text (emphasis content
    /// there), where no bare URL is linked.
    private var insideLinkText = false
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
    /// punctuation (P) category. This is cmark-gfm's definition; symbols such
    /// as `£` are not punctuation. Flanking looks at code points, as cmark
    /// does: the last scalar before a delimiter run and the first after it,
    /// neither of which a later chunk can change.
    /// CommonMark's Unicode whitespace: the Zs category, tab, line feed, form
    /// feed and carriage return. Zero-width and other format characters are
    /// not whitespace, so they do not stop emphasis.
    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .spaceSeparator { return true }
        return scalar == "\t" || scalar == "\n" || scalar == "\u{0C}" || scalar == "\r"
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
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
        constructProgress = nil
        bracketProgress = nil
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

        /// Emphasis opened by the plan (`emphasisPlan`) and not yet closed;
        /// it styles every run appended meanwhile, except code, math and
        /// images, as an enclosing emphasis span does.
        var planStyles: [(pair: Int, style: InlineStyle)] = []

        /// A link or image whose text is being parsed (see `bracket(at:)`):
        /// its text runs to `close`, the `]`, and the whole construct to
        /// `end`. A link styles every run appended meanwhile; an image
        /// gathers them (from `runsStart` on) into its alt text when it
        /// closes. Runs never merge across the start of one (`floor` is the
        /// enclosing one's).
        struct BracketContext {
            var close: String.Index
            var end: String.Index
            var image: InlineImage?
            var runsStart: Int
            var floor: Int
            /// The enclosing link's target, restored when this one closes.
            var outerLinkURL: String?
        }
        var contexts: [BracketContext] = []
        var contextLinkURL: String?
        var imageDepth = 0
        var coalesceFloor = 0
        /// Outcomes by opener (the `[`, or the `!` of `![`) for this text;
        /// see `bracket(at:)`. One scan decides every opener it closes.
        var bracketOutcomes: [String.Index: BracketOutcome] = [:]

        func planStyled(_ run: InlineRun) -> InlineRun {
            var styled = run
            if run.style.intersection([.code, .math, .image]).isEmpty {
                for entry in planStyles { styled.style.formUnion(entry.style) }
            }
            // A link's text is the link, code spans included. Links do not
            // nest: the link's own target wins over an autolink or tag
            // inside it.
            if let url = contextLinkURL, styled.image == nil, styled.math == nil {
                styled.style.insert(.link)
                styled.linkURL = url
            }
            return styled
        }

        func appendProcessed(_ text: String) {
            guard !text.isEmpty else { return }
            let newRuns = makePlainRuns(from: text).map(planStyled)
            guard let first = newRuns.first else { return }
            if runs.count > coalesceFloor, let last = runs.last, last.canCoalesce(with: first),
               !last.text.hasSuffix("\n"), !first.text.hasPrefix("\n") {
                runs[runs.count - 1].text += first.text
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
            runs.append(planStyled(run))
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

        /// Whitespace and punctuation of a character *before* something are
        /// those of its last scalar (the code point cmark sees), which a later
        /// chunk cannot change.
        func isWhitespace(_ character: Character) -> Bool {
            character.unicodeScalars.last.map(Self.isWhitespace) ?? false
        }

        func isPunctuation(_ character: Character) -> Bool {
            character.unicodeScalars.last.map(Self.isPunctuation) ?? false
        }

        /// A character with the same class as `character` for everything the
        /// parser asks of a preceding character (alphanumeric, whitespace,
        /// punctuation, other); `nil` is the start of the text.
        /// A Prepend character (U+0600 and the like) joins the next character
        /// into its grapheme, but CommonMark reads code points: an ASCII
        /// syntax character inside such a grapheme is still syntax. Its
        /// position, so the caller handles it there, or `nil`. Whether a chunk
        /// boundary falls between the two then makes no difference.
        func syntaxInsideGrapheme(at index: String.Index) -> String.Index? {
            let scalars = text.unicodeScalars
            guard index < text.endIndex, !scalars[index].isASCII else { return nil }
            let graphemeEnd = text.index(after: index)
            var cursor = scalars.index(after: index)
            while cursor < graphemeEnd {
                let scalar = scalars[cursor]
                if scalar.isASCII, "*_`~<[]!$&\\".unicodeScalars.contains(scalar) { return cursor }
                cursor = scalars.index(after: cursor)
            }
            return nil
        }

        /// The character at `index` as syntax sees it: an ASCII syntax
        /// character followed by combining marks (`*` + U+0301) is that
        /// syntax character, as CommonMark reads code points, and the marks
        /// are what follows it. Anything else is the grapheme.
        func syntaxCharacter(at index: String.Index) -> Character {
            let leading = text.unicodeScalars[index]
            if leading.isASCII, "*_`~<[!$&\\".unicodeScalars.contains(leading) { return Character(leading) }
            return text[index]
        }

        func standIn(_ character: Character?) -> Character? {
            character.map { character in
                if isAlphanumeric(character) { return "a" }
                if isWhitespace(character) { return " " }
                return isPunctuation(character) ? "." : "©"
            }
        }

        func utf8Offset(of position: String.Index) -> Int {
            text.utf8.distance(from: text.utf8.startIndex, to: position)
        }

        func position(ofUTF8 offset: Int) -> String.Index {
            text.utf8.index(text.utf8.startIndex, offsetBy: offset)
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
            // The code point before `index`, which may sit inside a grapheme
            // (see `syntaxInsideGrapheme`); its class is the one callers ask.
            let scalars = text.unicodeScalars
            return Character(scalars[scalars.index(before: index)])
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

        /// `leading` and `trailing` describe what surrounds `text` in the
        /// enclosing text, for emphasis content; without them its edges read
        /// as the start and end of a line. With a `plan`, the content's
        /// emphasis was already decided in the enclosing text (see
        /// `emphasisPlan`), and the complete content is parsed in one pass.
        func parseNestedRuns(from text: String, inheriting style: InlineStyle,
                             leading: ConsumedContext? = nil,
                             trailing: FollowingContext? = nil,
                             plan: [Int: EmphasisAction]? = nil) -> [InlineRun] {
            guard !text.isEmpty else { return [] }
            // Use the fast-path init: the outer parser already sorted the
            // prefix array and computed the first-char set, so the nested
            // parser doesn't need to redo either on every emphasis span.
            var nested = InlineParser(sortedTagPrefixes: parserTagPrefixes,
                                      tagPrefixOpeningFirstChars: parserTagPrefixOpeningFirstChars)
            nested.lastConsumed = leading
            nested.following = trailing
            nested.linkReferences = linkReferences
            nested.footnoteRegistry = footnoteRegistry
            nested.insideLinkText = insideLinkText || !contexts.isEmpty
            var result: [InlineRun]
            if let plan {
                nested.emphasisPlan = plan
                nested.pending = text
                result = nested.finish()
            } else {
                result = nested.append(text)
                result += nested.finish()
            }
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

        func appendRun(_ unstyled: InlineRun) {
            settleReplacements()
            let run = planStyled(unstyled)
            // Payload-identity check is shared with the assembler and the
            // state machine via `InlineRun.canCoalesce(with:)`; the two
            // line-break guards are local to inline parsing (don't merge
            // across a hard line break) and stay here.
            if runs.count > coalesceFloor, let last = runs.last,
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
            let scalars = text.unicodeScalars
            var backslashes = 0
            var cursor = index
            while cursor > text.startIndex {
                let previous = scalars.index(before: cursor)
                guard scalars[previous] == "\\" else { break }
                backslashes += 1
                cursor = previous
            }
            return backslashes % 2 == 1
        }

        /// The run of the delimiter at `index` around it: a delimiter run
        /// (CommonMark) is judged as a whole. An escaped delimiter is text,
        /// not part of the run. Delimiters are ASCII code points, so the run
        /// is found by scalars, whatever graphemes they share.
        func delimiterRun(containing index: String.Index) -> Range<String.Index> {
            let scalars = text.unicodeScalars
            let delimiter = scalars[index]
            var start = index
            while start > text.startIndex {
                let previous = scalars.index(before: start)
                guard scalars[previous] == delimiter, !isEscaped(previous) else { break }
                start = previous
            }
            var end = index
            while end < text.endIndex, scalars[end] == delimiter {
                end = scalars.index(after: end)
            }
            return start..<end
        }

        /// Delimiters in a range of a run, one byte each.
        func delimiterCount(from start: String.Index, to end: String.Index) -> Int {
            text.utf8.distance(from: start, to: end)
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
               trailing.delimiter == Character(text.unicodeScalars[run.lowerBound]) {
                return trailing.before
            }
            return character(before: run.lowerBound)
        }

        /// The length of a delimiter run, including delimiters of it that an
        /// earlier chunk consumed: the rule of three counts the whole run.
        func runLength(_ run: Range<String.Index>) -> Int {
            var length = delimiterCount(from: run.lowerBound, to: run.upperBound)
            if run.lowerBound == text.startIndex, let trailing = lastConsumed?.trailingRun,
               trailing.delimiter == Character(text.unicodeScalars[run.lowerBound]) {
                length += trailing.length
            }
            if run.upperBound == text.endIndex, let following, following.delimiter == Character(text.unicodeScalars[run.lowerBound]) {
                length += following.runLength
            }
            return length
        }

        /// CommonMark flanking of a delimiter run. The start and end of the
        /// text count as whitespace; `nil` while the character after the run
        /// has not arrived yet.
        func flanking(of run: Range<String.Index>) -> Flanking? {
            // The code point before the run is the last scalar of the
            // character before it; the one after is the first scalar of the
            // character after it. A later chunk can extend neither.
            let before = characterBefore(run: run) ?? " "
            let after: Unicode.Scalar
            if run.upperBound < text.endIndex, let first = text[run.upperBound].unicodeScalars.first {
                after = first
            } else if let following {
                // Emphasis content: the closer follows, and a run that goes
                // on into the closer's run is followed by what ends that run.
                after = following.delimiter == Character(text.unicodeScalars[run.lowerBound]) ? (following.afterRun ?? " ") : following.scalar
            } else if includeUnterminated {
                after = " "
            } else {
                return nil
            }
            let beforeIsSpace = isWhitespace(before)
            let afterIsSpace = Self.isWhitespace(after)
            let beforeIsPunctuation = isPunctuation(before), afterIsPunctuation = Self.isPunctuation(after)
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
        /// after `start`: a longer or shorter run is code content. Read by
        /// bytes, so a backtick that shares a grapheme with a Prepend
        /// character or a mark still counts.
        func findCodeClosing(delimiterLength: Int, from start: String.Index) -> Range<String.Index>? {
            let bytes = text.utf8
            var search = start
            while let tick = bytes[search...].firstIndex(of: 0x60) {
                var end = tick
                var length = 0
                while end < bytes.endIndex, bytes[end] == 0x60 {
                    length += 1
                    end = bytes.index(after: end)
                }
                if length == delimiterLength { return tick..<end }
                search = end
            }
            return nil
        }

        func saveProgress(start: String.Index, _ kind: ConstructProgress.Kind) {
            constructProgress = ConstructProgress(start: utf8Offset(of: start), kind: kind)
        }

        func savedProgress(start: String.Index) -> ConstructProgress.Kind? {
            guard let progress = constructProgress, progress.start == utf8Offset(of: start) else { return nil }
            return progress.kind
        }

        enum CodeSpan {
            case closed(content: Range<String.Index>, end: String.Index)
            /// No closer, and the text is final: the opening run is text.
            case unclosed(runEnd: String.Index)
            case needMore
        }

        /// A code span opening at the backtick run at `index`. A closer at
        /// the end of the text may still grow into a longer run, so it waits.
        /// While waiting, the search resumes where it stopped.
        func codeSpan(at index: String.Index) -> CodeSpan {
            let bytes = text.utf8
            var contentStart = index
            var length = 0
            while contentStart < bytes.endIndex, bytes[contentStart] == 0x60 {
                length += 1
                contentStart = bytes.index(after: contentStart)
            }
            var from = contentStart
            if case .codeSpan(let resume)? = savedProgress(start: index) {
                from = max(from, position(ofUTF8: resume))
            }
            if let closing = findCodeClosing(delimiterLength: length, from: from) {
                if closing.upperBound == text.endIndex, !includeUnterminated {
                    saveProgress(start: index, .codeSpan(resume: utf8Offset(of: closing.lowerBound)))
                    return .needMore
                }
                return .closed(content: contentStart..<closing.lowerBound, end: closing.upperBound)
            }
            if includeUnterminated { return .unclosed(runEnd: contentStart) }
            // An opening run at the end may still grow; anything else resumes
            // at a trailing backtick run, which may still become the closer.
            if contentStart < bytes.endIndex {
                var resume = bytes.endIndex
                while resume > from, bytes[bytes.index(before: resume)] == 0x60 {
                    resume = bytes.index(before: resume)
                }
                saveProgress(start: index, .codeSpan(resume: utf8Offset(of: resume)))
            }
            return .needMore
        }

        /// For `\(` and `\[` math in the final text: the earliest content
        /// start from which a search found no closer. A later opener of the
        /// same kind finds none either, since its search covers a suffix of
        /// that one, so it is resolved without searching again.
        var commandMathUnclosedFrom: [UInt8: String.Index] = [:]

        /// Inline math starting at `index`, opened and closed exactly as the
        /// emitter does (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`, by bytes), or `nil`
        /// when no math opens there. Math is opaque: the emphasis lookahead
        /// skips it. `.none` once the text is final and the math never
        /// closed, which the emitter then shows as text.
        /// The end of the opening marker of math that never closed, which
        /// is text: `$`, `$$`, `\(` or `\[`.
        func mathMarkerEnd(at index: String.Index) -> String.Index {
            let bytes = text.utf8
            var markerEnd = bytes.index(after: index)
            if markerEnd < bytes.endIndex, bytes[index] == 0x5C || bytes[markerEnd] == 0x24 {
                markerEnd = bytes.index(after: markerEnd)
            }
            return markerEnd
        }

        func mathScan(at index: String.Index) -> SpanScan? {
            let bytes = text.utf8
            let next = bytes.index(after: index)
            var contentStart: String.Index
            var dollars = 0
            var commandClosing: UInt8 = 0
            if bytes[index] == 0x24 {
                dollars = 1
                contentStart = next
                if contentStart < bytes.endIndex, bytes[contentStart] == 0x24 {
                    dollars = 2
                    contentStart = bytes.index(after: contentStart)
                } else if contentStart == bytes.endIndex, !includeUnterminated {
                    return .needMore // `$` may still become `$$`
                }
            } else if bytes[index] == 0x5C, next < bytes.endIndex, bytes[next] == 0x28 || bytes[next] == 0x5B {
                commandClosing = bytes[next] == 0x28 ? 0x29 : 0x5D
                contentStart = bytes.index(after: next)
            } else {
                return nil
            }
            if dollars == 0, includeUnterminated, let unclosedFrom = commandMathUnclosedFrom[commandClosing],
               contentStart >= unclosedFrom {
                return SpanScan.none
            }
            var cursor = contentStart
            if case .math(let resume)? = savedProgress(start: index) {
                cursor = max(cursor, position(ofUTF8: resume))
            }
            func wait(at resume: String.Index) -> SpanScan {
                saveProgress(start: index, .math(resume: utf8Offset(of: resume)))
                return .needMore
            }
            while cursor < bytes.endIndex {
                let byte = bytes[cursor]
                let following = bytes.index(after: cursor)
                if byte == 0x5C {
                    if following == bytes.endIndex {
                        if !includeUnterminated { return wait(at: cursor) }
                        cursor = following
                        continue
                    }
                    if dollars == 0, bytes[following] == commandClosing {
                        return .end(bytes.index(after: following))
                    }
                    cursor = dollars > 0 ? bytes.index(after: following) : following
                    continue
                }
                if dollars > 0, byte == 0x24 {
                    var run = cursor
                    var length = 0
                    while run < bytes.endIndex, bytes[run] == 0x24, length < dollars {
                        length += 1
                        run = bytes.index(after: run)
                    }
                    if length == dollars { return .end(run) }
                    if run == bytes.endIndex, !includeUnterminated { return wait(at: cursor) }
                }
                cursor = following
            }
            guard includeUnterminated else { return wait(at: bytes.endIndex) }
            if dollars == 0 {
                commandMathUnclosedFrom[commandClosing] = min(commandMathUnclosedFrom[commandClosing] ?? contentStart, contentStart)
            }
            return SpanScan.none
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
            let start = text.unicodeScalars.index(after: index)
            var cursor = start
            var htmlState = HTMLState.begin
            var htmlCursor = start
            // A search that ran out of text resumes where it stopped.
            if case .angle(let autolinkCursor, let state, let resume)? = savedProgress(start: index) {
                cursor = position(ofUTF8: autolinkCursor)
                htmlState = state
                htmlCursor = position(ofUTF8: resume)
            }
            // An autolink ends at the first `>` and holds no `<`, space or
            // ASCII control character (CommonMark), read by bytes so a mark
            // or Prepend character sharing a grapheme with the `>` does not
            // hide it.
            let bytes = text.utf8
            while cursor < bytes.endIndex {
                let byte = bytes[cursor]
                if byte == 0x3E || byte == 0x3C || byte == 0x20 || byte < 0x20 || byte == 0x7F { break }
                cursor = bytes.index(after: cursor)
            }
            var autolinkPending = false
            if cursor < bytes.endIndex, bytes[cursor] == 0x3E {
                let candidate = String(text[start..<cursor])
                let end = bytes.index(after: cursor)
                if isURIAutolink(candidate) {
                    return .autolink(end: end, display: candidate, url: candidate)
                }
                if isEmailAutolink(candidate) {
                    return .autolink(end: end, display: candidate, url: "mailto:" + candidate)
                }
            } else if cursor == bytes.endIndex {
                autolinkPending = !includeUnterminated
            }
            let (scan, state, stop) = htmlScan(from: htmlState, at: htmlCursor)
            switch scan {
            case .end(let end):
                return .html(end: end)
            case .needMore:
                break
            case .none:
                guard autolinkPending else { return .none }
            }
            saveProgress(start: index, .angle(autolinkCursor: utf8Offset(of: cursor), html: state, htmlCursor: utf8Offset(of: stop)))
            return .needMore
        }

        /// A `<kbd>`, `<sup>` or `<sub>` element at `index`, which the
        /// emitter parses apart up to its closing tag, or `nil` when none
        /// starts there. `.none` once the text is final and the element never
        /// closed: the opening tag is then ordinary raw HTML. While waiting,
        /// the search for the closing tag resumes where it stopped.
        func elementScan(at index: String.Index) -> SpanScan? {
            let elements = [("<kbd>", "</kbd>"), ("<sup>", "</sup>"), ("<sub>", "</sub>")]
            guard let (open, close) = elements.first(where: { text[index...].hasPrefix($0.0) }) else { return nil }
            let bytes = text.utf8
            let closing = Array(close.utf8)
            var search = bytes.index(index, offsetBy: open.utf8.count)
            if case .element(let resume)? = savedProgress(start: index) {
                search = max(search, position(ofUTF8: resume))
            }
            while search < bytes.endIndex {
                if bytes[search] == closing[0] {
                    var probe = search
                    var matched = 0
                    while matched < closing.count, probe < bytes.endIndex, bytes[probe] == closing[matched] {
                        matched += 1
                        probe = bytes.index(after: probe)
                    }
                    if matched == closing.count { return .end(probe) }
                    if probe == bytes.endIndex {
                        // A closing tag split by the end of the text is searched again.
                        guard !includeUnterminated else { return SpanScan.none }
                        saveProgress(start: index, .element(resume: utf8Offset(of: search)))
                        return .needMore
                    }
                }
                search = bytes.index(after: search)
            }
            guard !includeUnterminated else { return SpanScan.none }
            saveProgress(start: index, .element(resume: utf8Offset(of: bytes.endIndex)))
            return .needMore
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
        /// processing instruction, a declaration or a CDATA section, read as a
        /// state machine from `initial` at `start`. Returns the result, and
        /// the state and position to resume from when the text ran out.
        func htmlScan(from initial: HTMLState, at start: String.Index) -> (SpanScan, HTMLState, String.Index) {
            let pending: SpanScan = includeUnterminated ? .none : .needMore
            let bytes = text.utf8
            var state = initial
            var cursor = start
            func isLetter(_ b: UInt8) -> Bool { (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }
            func isDigit(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) }
            func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D }
            func isTagNameByte(_ b: UInt8) -> Bool { isLetter(b) || isDigit(b) || b == 0x2D }
            func isAttributeNameStart(_ b: UInt8) -> Bool { isLetter(b) || b == 0x5F || b == 0x3A }
            func isAttributeNameByte(_ b: UInt8) -> Bool {
                isLetter(b) || isDigit(b) || b == 0x5F || b == 0x2E || b == 0x3A || b == 0x2D
            }
            /// How `pattern` relates to the bytes at `position`: all present,
            /// a prefix of it up to the end of the text, or a mismatch.
            func compare(_ pattern: [UInt8], at position: String.Index) -> (matches: Bool, partial: Bool) {
                var index = position
                for byte in pattern {
                    guard index < bytes.endIndex else { return (false, true) }
                    guard bytes[index] == byte else { return (false, false) }
                    index = bytes.index(after: index)
                }
                return (true, false)
            }
            let dashDash: [UInt8] = Array("--".utf8)
            let cdata: [UInt8] = Array("[CDATA[".utf8)
            while true {
                switch state {
                case .notHTML:
                    return (.none, state, cursor)
                case .terminator(let terminator):
                    var search = cursor
                    while search < bytes.endIndex {
                        if bytes[search] == terminator[0] {
                            let (matches, partial) = compare(terminator, at: search)
                            if matches { return (.end(bytes.index(search, offsetBy: terminator.count)), state, cursor) }
                            // A terminator split by the end of the text is searched again.
                            if partial { return (pending, state, search) }
                        }
                        search = bytes.index(after: search)
                    }
                    return (pending, state, bytes.endIndex)
                case .quoted(let quote):
                    guard let close = bytes[cursor...].firstIndex(of: quote) else { return (pending, state, bytes.endIndex) }
                    cursor = bytes.index(after: close)
                    state = .attributes(spaced: false)
                    continue
                case .bang:
                    let comment = compare(dashDash, at: cursor), section = compare(cdata, at: cursor)
                    if comment.matches {
                        cursor = bytes.index(cursor, offsetBy: 2)
                        state = .commentStart
                    } else if section.matches {
                        cursor = bytes.index(cursor, offsetBy: cdata.count)
                        state = .terminator(Array("]]>".utf8))
                    } else if comment.partial || section.partial {
                        return (pending, state, cursor)
                    } else if isLetter(bytes[cursor]) {
                        state = .terminator([0x3E])
                    } else {
                        return (.none, .notHTML, cursor)
                    }
                    continue
                case .commentStart:
                    // `<!-->` and `<!--->` are complete comments (CommonMark).
                    guard cursor < bytes.endIndex else { return (pending, state, cursor) }
                    if bytes[cursor] == 0x3E { return (.end(bytes.index(after: cursor)), state, cursor) }
                    let empty = compare(Array("->".utf8), at: cursor)
                    if empty.matches { return (.end(bytes.index(cursor, offsetBy: 2)), state, cursor) }
                    if empty.partial { return (pending, state, cursor) }
                    state = .terminator(Array("-->".utf8))
                    continue
                default:
                    break
                }
                guard cursor < bytes.endIndex else { return (pending, state, cursor) }
                let b = bytes[cursor]
                var next: HTMLState?
                var closes = false
                switch state {
                case .begin:
                    if b == 0x21 { next = .bang }
                    else if b == 0x3F { next = .terminator(Array("?>".utf8)) }
                    else if b == 0x2F { next = .closingStart }
                    else if isLetter(b) { next = .tagName }
                case .closingStart:
                    if isLetter(b) { next = .closingName }
                case .closingName:
                    if isTagNameByte(b) { next = .closingName }
                    else if isSpace(b) { next = .closingSpace }
                    else if b == 0x3E { closes = true }
                case .closingSpace:
                    if isSpace(b) { next = .closingSpace }
                    else if b == 0x3E { closes = true }
                case .tagName:
                    if isTagNameByte(b) { next = .tagName }
                    else if isSpace(b) { next = .attributes(spaced: true) }
                    else if b == 0x3E { closes = true }
                    else if b == 0x2F { next = .slash }
                case .attributes(let spaced):
                    // An attribute needs whitespace before it.
                    if isSpace(b) { next = .attributes(spaced: true) }
                    else if b == 0x3E { closes = true }
                    else if b == 0x2F { next = .slash }
                    else if spaced, isAttributeNameStart(b) { next = .attributeName }
                case .attributeName:
                    if isAttributeNameByte(b) { next = .attributeName }
                    else if isSpace(b) { next = .afterAttributeName }
                    else if b == 0x3D { next = .beforeValue }
                    else if b == 0x3E { closes = true }
                    else if b == 0x2F { next = .slash }
                case .afterAttributeName:
                    if isSpace(b) { next = .afterAttributeName }
                    else if b == 0x3D { next = .beforeValue }
                    else if b == 0x3E { closes = true }
                    else if b == 0x2F { next = .slash }
                    else if isAttributeNameStart(b) { next = .attributeName }
                case .beforeValue:
                    // Unquoted values exclude `"`, `'`, `=`, `<`, `>` and `` ` ``.
                    if isSpace(b) { next = .beforeValue }
                    else if b == 0x22 || b == 0x27 { next = .quoted(b) }
                    else if ![0x3D, 0x3C, 0x3E, 0x60].contains(b) { next = .unquoted }
                case .unquoted:
                    if isSpace(b) { next = .attributes(spaced: true) }
                    else if b == 0x3E { closes = true }
                    else if ![0x22, 0x27, 0x3D, 0x3C, 0x60].contains(b) { next = .unquoted }
                case .slash:
                    if b == 0x3E { closes = true }
                case .bang, .commentStart, .terminator, .quoted, .notHTML:
                    break
                }
                cursor = bytes.index(after: cursor)
                if closes { return (.end(cursor), state, cursor) }
                guard let next else { return (.none, .notHTML, cursor) }
                state = next
            }
        }

        enum EmphasisMatch {
            /// After `literalPrefix` delimiters that stay text, the opener's
            /// leftmost delimiters pair with `closer`, as emphasis (`length`
            /// 1) or strong emphasis (2). `inner` are the pairs formed inside
            /// it, by UTF-8 offset in this text.
            case matched(closer: Range<String.Index>, length: Int, literalPrefix: Int, inner: [EmphasisScan.Pair])
            /// No delimiter of the opener pairs: the run is text.
            case none
            case needMore
        }

        /// What a scan that reached the end of the final text found for every
        /// opener it saw. A later scan from one of those openers would find
        /// the same, provided no pair in the scan spans it (an opener before
        /// it paired with a closer after it): runs before it then either
        /// pair among themselves or stay inert, and the processing from it on
        /// is identical. Openers are thus resolved once, not rescanned each
        /// (`*a *a … c*`, `*a _b_ *a _b_ …`). Positions are UTF-8 offsets;
        /// `spans` are the outermost pairs, in order.
        struct EmphasisOutcomes {
            enum Outcome {
                case pair(EmphasisScan.Pair, literalPrefix: Int)
                case none
            }
            var spans: [(start: Int, end: Int)]
            /// Every pair the scan formed, by opener position.
            var pairs: [EmphasisScan.Pair]
            var results: [Int: Outcome]

            /// The pairs inside `lower..<upper`. Pairs nest, so they are the
            /// ones whose opener lies inside.
            func pairs(inside lower: Int, _ upper: Int) -> [EmphasisScan.Pair] {
                var low = 0, high = pairs.count
                while low < high {
                    let middle = (low + high) / 2
                    if pairs[middle].openerStart < lower { low = middle + 1 } else { high = middle }
                }
                var inside: [EmphasisScan.Pair] = []
                while low < pairs.count, pairs[low].openerStart < upper {
                    inside.append(pairs[low])
                    low += 1
                }
                return inside
            }

            func spanned(_ offset: Int) -> Bool {
                // The last outermost pair that starts before `offset`.
                var low = 0, high = spans.count
                while low < high {
                    let middle = (low + high) / 2
                    if spans[middle].start < offset { low = middle + 1 } else { high = middle }
                }
                return low > 0 && spans[low - 1].end > offset
            }
        }
        var emphasisOutcomes: EmphasisOutcomes?
        /// The same for the text of the link or image closing at `close`.
        var linkTextOutcomes: (close: String.Index, outcomes: EmphasisOutcomes)?

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
            func resolved(_ outcome: EmphasisOutcomes.Outcome, in outcomes: EmphasisOutcomes) -> EmphasisMatch {
                switch outcome {
                case .none:
                    return .none
                case .pair(let pair, let literalPrefix):
                    let utf8 = text.utf8
                    return .matched(closer: utf8.index(utf8.startIndex, offsetBy: pair.closerStart)..<utf8.index(utf8.startIndex, offsetBy: pair.closerEnd),
                                    length: pair.length, literalPrefix: literalPrefix,
                                    inner: outcomes.pairs(inside: pair.openerEnd, pair.closerStart))
                }
            }
            // Inside a link's or image's text, emphasis is matched within the
            // text, which is final: its `]` has arrived.
            let limit = contexts.last?.close
            let cached = limit == nil ? emphasisOutcomes : linkTextOutcomes.flatMap { $0.close == limit ? $0.outcomes : nil }
            if let outcomes = cached, let known = outcomes.results[base], !outcomes.spanned(base) {
                return resolved(known, in: outcomes)
            }
            func position(_ offset: Int) -> String.Index {
                text.utf8.index(text.utf8.startIndex, offsetBy: base + offset)
            }
            func offset(_ position: String.Index) -> Int { utf8Offset(of: position) - base }
            // One stack per delimiter character (`*`, `_`): a closer only ever
            // looks at its own character's openers.
            func slot(_ character: Character) -> Int { character == "*" ? 0 : 1 }
            let delimiter = syntaxCharacter(at: index)
            let targetSlot = slot(delimiter)
            // A scan saved by an earlier chunk resumes when its opener is this
            // one, now at the start of the text (see the end of `consume`).
            var resumed = base == 0 && limit == nil ? emphasisScan : nil
            if limit == nil { emphasisScan = nil }
            var scan: EmphasisScan
            if resumed != nil {
                scan = resumed!
                resumed = nil
            } else {
                let openerRun = delimiterRun(containing: index)
                scan = EmphasisScan(targetOffset: base, cursor: offset(openerRun.upperBound), openers: [[], []],
                                    searchFloor: Array(repeating: Int.min, count: 12),
                                    lastPairs: [:], usedUp: [], pairs: [])
                scan.openers[targetSlot].append(Delimiter(character: delimiter,
                                                          start: 0,
                                                          count: delimiterCount(from: index, to: openerRun.upperBound),
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
            let scanEnd = limit ?? text.endIndex
            while cursor < scanEnd {
                if let syntax = syntaxInsideGrapheme(at: cursor) {
                    cursor = syntax
                    continue
                }
                // A registered tag comes first, as in the emitter (a `$AAPL`
                // ticker is not math); a tag never holds a delimiter.
                if let prefix = matchingTagPrefix(at: cursor) {
                    switch parseTag(at: cursor, prefix: prefix, dryRun: true) {
                    case .handled(let next):
                        cursor = next
                        continue
                    case .needMore:
                        return suspend(at: cursor)
                    case .literal:
                        break
                    }
                }
                // Math opens on a `$` byte or `\(` / `\[`, before escapes, as
                // in the emitter; nothing inside it is a delimiter.
                if let math = mathScan(at: cursor) {
                    switch math {
                    case .end(let end): cursor = end
                    case .needMore: return suspend(at: cursor)
                    case .none:
                        // Math that never closed in the final text is text:
                        // the scan goes on after its opening marker, so
                        // `**Price: $5**` is still strong emphasis.
                        cursor = mathMarkerEnd(at: cursor)
                    }
                    continue
                }
                let character = syntaxCharacter(at: cursor)
                // A character reference is text: nothing in it is markup.
                if character == "&" {
                    switch HTMLEntities.scan(text[...], at: cursor) {
                    case .reference(_, let end):
                        cursor = end
                        continue
                    case .partial where !includeUnterminated && limit == nil:
                        return suspend(at: cursor)
                    case .partial, .none:
                        break
                    }
                }
                // A bare URL is one unit to the emitter, as is `~~…~~`, whose
                // content it parses apart: nothing inside pairs with a
                // delimiter outside.
                if limit == nil, !insideLinkText, "hHwW".contains(character), let autolink = parseAutolink(at: cursor) {
                    switch autolink {
                    case .handled(let next, _, _):
                        cursor = next
                        continue
                    case .needMore:
                        return suspend(at: cursor)
                    }
                }
                if character == "~" {
                    let second = text.unicodeScalars.index(after: cursor)
                    if second == text.endIndex, !includeUnterminated { return suspend(at: cursor) }
                    if second < text.endIndex, text[second] == "~" {
                        if let closeAfter = findStrikethroughClosing(in: text, from: text.index(after: second), before: scanEnd) {
                            cursor = closeAfter
                            continue
                        }
                        if !includeUnterminated, limit == nil { return suspend(at: cursor) }
                    }
                }
                // A link, image or footnote reference is one unit to the
                // emitter, which shows its label as text: nothing in its label
                // or destination pairs with a delimiter outside it.
                if character == "[" || character == "!" {
                    let image = character == "!"
                    let open = image ? text.unicodeScalars.index(after: cursor) : cursor
                    if image, open == text.endIndex, !includeUnterminated, limit == nil { return suspend(at: cursor) }
                    if !image || (open < text.endIndex && text.unicodeScalars[open] == "[") {
                        switch bracket(at: cursor) {
                        case .decided(.link(_, let end, _)), .decided(.image(_, let end, _, _)),
                             .decided(.footnote(let end, _)):
                            cursor = end
                            continue
                        case .needMore:
                            return suspend(at: cursor)
                        case .decided(.literal):
                            break
                        }
                    }
                }
                if character == "\\" {
                    let escaped = text.unicodeScalars.index(after: cursor)
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
                    switch codeSpan(at: cursor) {
                    case .closed(_, let end): cursor = end
                    case .needMore: return suspend(at: cursor)
                    case .unclosed(let runEnd): cursor = runEnd
                    }
                    continue
                }
                if character == "<" {
                    // A `<kbd>`, `<sup>` or `<sub>` element is parsed apart
                    // by the emitter up to its closing tag, so nothing inside
                    // it pairs with a delimiter outside.
                    switch elementScan(at: cursor) {
                    case .end(let end)?:
                        cursor = end
                        continue
                    case .needMore?:
                        return suspend(at: cursor)
                    case .none?, nil:
                        break
                    }
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
                    let length = delimiterCount(from: run.lowerBound, to: run.upperBound)
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
                            let entry = scan.openers[own][openerIndex]
                            let used = closer.count >= 2 && entry.count >= 2 ? 2 : 1
                            // Delimiters are ASCII: one UTF-8 byte each. An
                            // opener gives up its rightmost (innermost)
                            // delimiters first.
                            let closerEnd = closer.start + used
                            let pair = EmphasisScan.Pair(openerStart: entry.start + entry.count - used,
                                                         openerEnd: entry.start + entry.count,
                                                         closerStart: closer.start, closerEnd: closerEnd, length: used)
                            // The opener at `index` pairs here once this match
                            // takes its leftmost (outermost) delimiters; every
                            // pair formed so far lies inside it.
                            if own == targetSlot, openerIndex == 0, entry.count == used {
                                return .matched(closer: position(closer.start)..<position(closerEnd), length: used, literalPrefix: 0,
                                                inner: scan.pairs.map { $0.shifted(by: base) })
                            }
                            let openerStart = entry.start
                            scan.lastPairs[openerStart] = pair
                            scan.pairs.append(pair)
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
            guard includeUnterminated || limit != nil else { return suspend(at: text.endIndex) }
            // The text is final: an opener still on a stack keeps its
            // unpaired delimiters at the left as text; one used up pairs
            // whole. (An opener dropped between a pair is not recorded.)
            var results: [Int: EmphasisOutcomes.Outcome] = [:]
            for stack in scan.openers {
                for opener in stack {
                    results[base + opener.start] = scan.lastPairs[opener.start].map {
                        .pair($0.shifted(by: base), literalPrefix: opener.count)
                    } ?? .none
                }
            }
            for start in scan.usedUp {
                if let pair = scan.lastPairs[start] { results[base + start] = .pair(pair.shifted(by: base), literalPrefix: 0) }
            }
            // Pairs nest or follow each other; the outermost, in order, tell
            // which openers a later lookup may reuse.
            let pairs = scan.pairs.map { $0.shifted(by: base) }.sorted { $0.openerStart < $1.openerStart }
            var spans: [(start: Int, end: Int)] = []
            for pair in pairs {
                if let last = spans.last, pair.openerStart < last.end { continue }
                spans.append((pair.openerStart, pair.closerEnd))
            }
            let outcomes = EmphasisOutcomes(spans: spans, pairs: pairs, results: results)
            if let limit {
                linkTextOutcomes = (limit, outcomes)
            } else {
                emphasisOutcomes = outcomes
            }
            return results[base].map { resolved($0, in: outcomes) } ?? .none
        }

        /// What a `[` or `![` opener turned out to be. `close` is its `]`,
        /// `end` the end of the whole construct.
        enum BracketOutcome {
            case link(close: String.Index, end: String.Index, url: String)
            case image(close: String.Index, end: String.Index, source: String, title: String?)
            case footnote(end: String.Index, id: String)
            case literal
        }

        enum BracketScan {
            case decided(BracketOutcome)
            case needMore
        }

        enum LinkTail {
            case link(end: String.Index, destination: String, title: String?)
            case invalid
            case needMore
        }

        enum LabelScan {
            case label(Substring, end: String.Index)
            case invalid
            case needMore
        }

        /// The `(destination "title")` of an inline link, from its `(`:
        /// spaces, tabs and line endings may surround both parts, a title
        /// must be separated from the destination, and backslash escapes
        /// are resolved in each.
        func inlineLinkTail(from paren: String.Index) -> LinkTail {
            let scalars = text.unicodeScalars
            let unfinished: LinkTail = includeUnterminated ? .invalid : .needMore
            var cursor = scalars.index(after: paren)
            func skipWhitespace() {
                while cursor < text.endIndex, scalars[cursor] == " " || scalars[cursor] == "\t" || scalars[cursor] == "\n" {
                    cursor = scalars.index(after: cursor)
                }
            }
            /// The escaped character after a backslash at `cursor`, if it is
            /// escapable; `nil` leaves the backslash as text.
            func escaped() -> Unicode.Scalar? {
                let next = scalars.index(after: cursor)
                guard next < text.endIndex, Self.asciiPunctuation.contains(scalars[next]) else { return nil }
                return scalars[next]
            }
            /// A character reference at `cursor`, appended to `target`.
            func reference(into target: inout String.UnicodeScalarView) -> Bool {
                guard scalars[cursor] == "&", case .reference(let replacement, let end) = HTMLEntities.scan(text[...], at: cursor) else {
                    return false
                }
                target.append(contentsOf: replacement.unicodeScalars)
                cursor = end
                return true
            }
            skipWhitespace()
            guard cursor < text.endIndex else { return unfinished }
            var destination = String.UnicodeScalarView()
            if scalars[cursor] == "<" {
                cursor = scalars.index(after: cursor)
                while true {
                    guard cursor < text.endIndex else { return unfinished }
                    let scalar = scalars[cursor]
                    if scalar == ">" { break }
                    if scalar == "\n" || scalar == "<" { return .invalid }
                    if scalar == "\\" {
                        if scalars.index(after: cursor) == text.endIndex { return unfinished }
                        if let escaped = escaped() {
                            destination.append(escaped)
                            cursor = scalars.index(cursor, offsetBy: 2)
                            continue
                        }
                    }
                    if reference(into: &destination) { continue }
                    destination.append(scalar)
                    cursor = scalars.index(after: cursor)
                }
                cursor = scalars.index(after: cursor)
            } else {
                var depth = 0
                while cursor < text.endIndex {
                    let scalar = scalars[cursor]
                    if scalar == "\\" {
                        if scalars.index(after: cursor) == text.endIndex { return unfinished }
                        if let escaped = escaped() {
                            destination.append(escaped)
                            cursor = scalars.index(cursor, offsetBy: 2)
                            continue
                        }
                    }
                    if scalar.value <= 0x20 || scalar.value == 0x7F { break }
                    if reference(into: &destination) { continue }
                    if scalar == "(" {
                        depth += 1
                        if depth > 32 { return .invalid }
                    } else if scalar == ")" {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    destination.append(scalar)
                    cursor = scalars.index(after: cursor)
                }
                guard cursor < text.endIndex else { return unfinished }
                if depth != 0 { return .invalid }
            }
            let afterDestination = cursor
            skipWhitespace()
            guard cursor < text.endIndex else { return unfinished }
            var title: String?
            let opening = scalars[cursor]
            if opening != ")" {
                guard cursor > afterDestination, opening == "\"" || opening == "'" || opening == "(" else { return .invalid }
                let closing: Unicode.Scalar = opening == "(" ? ")" : opening
                var content = String.UnicodeScalarView()
                cursor = scalars.index(after: cursor)
                while true {
                    guard cursor < text.endIndex else { return unfinished }
                    let scalar = scalars[cursor]
                    if scalar == closing { break }
                    if opening == "(", scalar == "(" { return .invalid }
                    if scalar == "\\" {
                        if scalars.index(after: cursor) == text.endIndex { return unfinished }
                        if let escaped = escaped() {
                            content.append(escaped)
                            cursor = scalars.index(cursor, offsetBy: 2)
                            continue
                        }
                    }
                    if reference(into: &content) { continue }
                    content.append(scalar)
                    cursor = scalars.index(after: cursor)
                }
                title = String(content)
                cursor = scalars.index(after: cursor)
                skipWhitespace()
                guard cursor < text.endIndex else { return unfinished }
                guard scalars[cursor] == ")" else { return .invalid }
            }
            return .link(end: scalars.index(after: cursor), destination: String(destination), title: title)
        }

        /// A link label (`[ref]`) is at most 999 characters, has a
        /// non-whitespace character, and holds no unescaped bracket.
        func isLinkLabel(_ label: Substring) -> Bool {
            var count = 0
            var escaping = false
            var blank = true
            for scalar in label.unicodeScalars {
                count += 1
                if count > 999 { return false }
                if escaping {
                    escaping = false
                } else if scalar == "\\" {
                    escaping = true
                } else if scalar == "[" || scalar == "]" {
                    return false
                }
                if !Self.isWhitespace(scalar) { blank = false }
            }
            return !blank
        }

        /// The link label at the `[` at `open`; an empty one is `[]`.
        func linkLabel(at open: String.Index) -> LabelScan {
            let scalars = text.unicodeScalars
            let start = scalars.index(after: open)
            var cursor = start
            var count = 0
            while cursor < text.endIndex {
                let scalar = scalars[cursor]
                if scalar == "]" {
                    let label = text[start..<cursor]
                    guard label.isEmpty || isLinkLabel(label) else { return .invalid }
                    return .label(label, end: scalars.index(after: cursor))
                }
                if scalar == "[" { return .invalid }
                if scalar == "\\" {
                    cursor = scalars.index(after: cursor)
                    count += 1
                    if cursor == text.endIndex { break }
                }
                count += 1
                if count > 999 { return .invalid }
                cursor = scalars.index(after: cursor)
            }
            return includeUnterminated ? .invalid : .needMore
        }

        /// CommonMark's brackets from the opener at `start` on: each `]`
        /// closes the nearest open bracket, which becomes a link or image
        /// when an inline destination or a defined label follows it, and a
        /// link deactivates the link openers before it (no links in links).
        /// Code spans, autolinks, raw HTML, math and tags bind tighter, and
        /// an escaped bracket is text. A decision depends only on the text up
        /// to the end of its construct, so once made it is final; one that
        /// needs text yet to arrive is `needMore`.
        func bracket(at start: String.Index) -> BracketScan {
            if let known = bracketOutcomes[start] { return .decided(known) }
            let scalars = text.unicodeScalars
            struct Opener {
                var position: String.Index
                var image: Bool
            }
            func opener(at position: String.Index) -> (Opener, contentStart: String.Index) {
                let image = scalars[position] == "!"
                let bracket = image ? scalars.index(after: position) : position
                return (Opener(position: position, image: image), scalars.index(after: bracket))
            }
            func closing(_ opener: Opener, at close: String.Index) -> BracketScan {
                let bracket = opener.image ? scalars.index(after: opener.position) : opener.position
                let label = text[scalars.index(after: bracket)..<close]
                if !opener.image, label.hasPrefix("^") {
                    guard label.count > 1, footnoteRegistry != nil else { return .decided(.literal) }
                    return .decided(.footnote(end: scalars.index(after: close), id: String(label.dropFirst())))
                }
                func made(end: String.Index, destination: String, title: String?) -> BracketScan {
                    .decided(opener.image ? .image(close: close, end: end, source: destination, title: title)
                                          : .link(close: close, end: end, url: destination))
                }
                func reference(_ label: Substring, end: String.Index) -> BracketScan {
                    guard isLinkLabel(label) else { return .decided(.literal) }
                    guard let definition = linkReferences?.resolve(label: String(label)) else {
                        linkReferences?.noteUndefined(label: String(label))
                        return .decided(.literal)
                    }
                    return made(end: end, destination: definition.url, title: definition.title)
                }
                let after = scalars.index(after: close)
                guard after < text.endIndex else {
                    return includeUnterminated ? reference(label, end: after) : .needMore
                }
                if scalars[after] == "(" {
                    switch inlineLinkTail(from: after) {
                    case .link(let end, let destination, let title):
                        return made(end: end, destination: destination, title: title)
                    case .needMore:
                        return .needMore
                    case .invalid:
                        break
                    }
                } else if scalars[after] == "[" {
                    switch linkLabel(at: after) {
                    case .label(let inner, let end):
                        // `[text][]` takes its label from the text.
                        return reference(inner.isEmpty ? label : inner, end: end)
                    case .needMore:
                        return .needMore
                    case .invalid:
                        break
                    }
                }
                // A shortcut reference: the text is the label.
                return reference(label, end: after)
            }

            var stack: [Opener]
            // A link deactivates every link opener then on the stack, which
            // are the openers below this index (an image opener stays active).
            var deactivatedBelow = 0
            var cursor: String.Index
            // A scan saved by an earlier chunk resumes where it stopped.
            if let saved = bracketProgress, saved.start == utf8Offset(of: start) {
                stack = saved.openers.map { Opener(position: position(ofUTF8: $0.offset), image: $0.image) }
                deactivatedBelow = saved.deactivatedBelow
                cursor = position(ofUTF8: saved.cursor)
                bracketProgress = nil
            } else {
                let (first, content) = opener(at: start)
                stack = [first]
                cursor = content
            }
            func isActive(_ index: Int) -> Bool { stack[index].image || index >= deactivatedBelow }
            func wait(at stop: String.Index) -> BracketScan {
                bracketProgress = BracketProgress(
                    start: utf8Offset(of: start),
                    openers: stack.map { BracketProgress.Opener(offset: utf8Offset(of: $0.position), image: $0.image) },
                    deactivatedBelow: deactivatedBelow,
                    cursor: utf8Offset(of: stop))
                return .needMore
            }
            while cursor < text.endIndex {
                if let syntax = syntaxInsideGrapheme(at: cursor) {
                    cursor = syntax
                    continue
                }
                if let prefix = matchingTagPrefix(at: cursor) {
                    switch parseTag(at: cursor, prefix: prefix, dryRun: true) {
                    case .handled(let next):
                        cursor = next
                        continue
                    case .needMore:
                        return wait(at: cursor)
                    case .literal:
                        break
                    }
                }
                if let math = mathScan(at: cursor) {
                    switch math {
                    case .end(let end): cursor = end
                    case .needMore: return wait(at: cursor)
                    case .none: cursor = mathMarkerEnd(at: cursor)
                    }
                    continue
                }
                let scalar = scalars[cursor]
                if scalar == "&" {
                    switch HTMLEntities.scan(text[...], at: cursor) {
                    case .reference(_, let end):
                        cursor = end
                        continue
                    case .partial where !includeUnterminated:
                        return wait(at: cursor)
                    case .partial, .none:
                        break
                    }
                }
                if scalar == "\\" {
                    let escaped = scalars.index(after: cursor)
                    if escaped == text.endIndex {
                        if !includeUnterminated { return wait(at: cursor) }
                        cursor = escaped
                        continue
                    }
                    cursor = text.index(after: escaped)
                    continue
                }
                if scalar == "`" {
                    switch codeSpan(at: cursor) {
                    case .closed(_, let end): cursor = end
                    case .needMore: return wait(at: cursor)
                    case .unclosed(let runEnd): cursor = runEnd
                    }
                    continue
                }
                if scalar == "<" {
                    switch elementScan(at: cursor) {
                    case .end(let end)?:
                        cursor = end
                        continue
                    case .needMore?:
                        return wait(at: cursor)
                    case .none?, nil:
                        break
                    }
                    switch angleSpan(at: cursor) {
                    case .autolink(let end, _, _), .html(let end): cursor = end
                    case .needMore: return wait(at: cursor)
                    case .none: cursor = text.index(after: cursor)
                    }
                    continue
                }
                if scalar == "!", scalars.index(after: cursor) == text.endIndex, !includeUnterminated {
                    return wait(at: cursor) // `![` may still open an image
                }
                if scalar == "[" || (scalar == "!" && scalars.index(after: cursor) < text.endIndex
                                     && scalars[scalars.index(after: cursor)] == "[") {
                    let (inner, content) = opener(at: cursor)
                    stack.append(inner)
                    cursor = content
                    continue
                }
                if scalar == "]" {
                    let top = stack[stack.count - 1]
                    var outcome = BracketOutcome.literal
                    if isActive(stack.count - 1) {
                        switch closing(top, at: cursor) {
                        case .needMore: return wait(at: cursor)
                        case .decided(let decided): outcome = decided
                        }
                    }
                    stack.removeLast()
                    deactivatedBelow = min(deactivatedBelow, stack.count)
                    bracketOutcomes[top.position] = outcome
                    if stack.isEmpty { return .decided(outcome) }
                    switch outcome {
                    case .link(_, let end, _):
                        deactivatedBelow = stack.count
                        cursor = end
                    case .image(_, let end, _, _), .footnote(let end, _):
                        cursor = end
                    case .literal:
                        cursor = scalars.index(after: cursor)
                    }
                    // The first opener can no longer be a link once one forms
                    // inside it; neither can the other inactive openers.
                    if !isActive(0) {
                        for opener in stack[..<deactivatedBelow] where !opener.image { bracketOutcomes[opener.position] = .literal }
                        return .decided(.literal)
                    }
                    continue
                }
                cursor = text.index(after: cursor)
            }
            guard includeUnterminated else { return wait(at: text.endIndex) }
            for opener in stack { bracketOutcomes[opener.position] = .literal }
            return .decided(.literal)
        }

        /// Opens the link or image `outcome` describes (its text is parsed
        /// next) or emits the footnote reference, and returns where parsing
        /// continues; `nil` when the opener is text.
        func open(_ outcome: BracketOutcome, at opener: String.Index) -> String.Index? {
            let scalars = text.unicodeScalars
            switch outcome {
            case .literal:
                return nil
            case .footnote(let end, let id):
                guard let registry = footnoteRegistry else { return nil }
                appendStructured(InlineRun(text: String(registry.index(for: id)), style: [.footnote, .superscript]))
                consumedEnd = end
                plainStart = end
                return end
            case .link(let close, let end, let url):
                settleReplacements()
                contexts.append(BracketContext(close: close, end: end, image: nil,
                                               runsStart: runs.count, floor: coalesceFloor, outerLinkURL: contextLinkURL))
                contextLinkURL = url
            case .image(let close, let end, let source, let title):
                settleReplacements()
                contexts.append(BracketContext(close: close, end: end,
                                               image: InlineImage(source: source, title: title),
                                               runsStart: runs.count, floor: coalesceFloor, outerLinkURL: contextLinkURL))
                imageDepth += 1
            }
            coalesceFloor = runs.count
            let bracket = scalars[opener] == "!" ? scalars.index(after: opener) : opener
            let content = scalars.index(after: bracket)
            consumedEnd = content
            plainStart = content
            return content
        }

        /// Ends the innermost link or image at its `]`: an image becomes one
        /// run whose text is the plain text of its content (the outermost
        /// image does this for any inside it). Parsing continues after it.
        func closeContext() -> String.Index {
            let context = contexts.removeLast()
            flushPlain(upTo: context.close)
            settleReplacements()
            coalesceFloor = context.floor
            contextLinkURL = context.outerLinkURL
            if context.image != nil { imageDepth -= 1 }
            if let image = context.image, imageDepth == 0 {
                let alt = runs[context.runsStart...].map(\.text).joined()
                runs.removeSubrange(context.runsStart...)
                appendStructured(InlineRun(text: alt, style: [.image], image: image))
            }
            consumedEnd = context.end
            plainStart = context.end
            return context.end
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

        /// A bare URL starts a word: the whole grapheme before it decides, as
        /// it does at the start of a chunk (`lastConsumed`), so `❤️` with its
        /// variation selector is not a word character. (Flanking reads the
        /// code point instead, as CommonMark does.)
        func isAutolinkBoundaryBefore(_ index: String.Index) -> Bool {
            if index > text.startIndex, index < text.endIndex,
               text.index(before: text.index(after: index)) == index {
                let previousIndex = text.index(before: index)
                let previous = text[previousIndex]
                // The text's first grapheme may extend the one consumed before
                // it (`❤` then U+FE0F): the joined grapheme decides.
                if previousIndex == text.startIndex, let context = lastConsumed,
                   (context.tail + String(previous)).count < context.tail.count + 1 {
                    return !(context.alphanumeric && isAlphanumeric(previous))
                }
                return !isAlphanumeric(previous)
            }
            guard let prev = character(before: index) else { return true }
            return !isAlphanumeric(prev)
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
            guard isAutolinkBoundaryBefore(index) else { return nil }
            guard let prefix = isAutolinkPrefix(at: index) else {
                // `ht` or `www` at the end of the text may still become a
                // link's scheme: wait rather than deliver it as text.
                let rest = text[index...]
                let couldStillMatch = ["http://", "https://", "www.", "HTTP://", "HTTPS://", "WWW."].contains { $0.hasPrefix(rest) }
                return couldStillMatch && !includeUnterminated ? .needMore : nil
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
                // Trailing punctuation is not part of the link (GFM's
                // extended autolinks), including `*`, `_` and `~`, so a link
                // at the end of emphasis leaves the closer outside it.
                if ".,:;!?*_~".contains(prevChar) {
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
            let start = text.unicodeScalars.index(after: index)
            guard start < text.endIndex else { return .needMore }
            // Only `<http://`, `<https://` and `<www.` take this form; anything
            // else is decided from its first characters, without searching
            // the rest of the text for a `>`.
            guard let prefix = isAutolinkPrefix(at: start) else {
                let rest = text[start...]
                let couldStillMatch = ["http://", "https://", "www.", "HTTP://", "HTTPS://", "WWW."].contains { $0.hasPrefix(rest) }
                return couldStillMatch && !includeUnterminated ? .needMore : nil
            }
            // The link holds no whitespace or `<`; it ends at the first `>`.
            var cursor = start
            while cursor < text.endIndex, text[cursor] != ">" {
                if text[cursor].isWhitespace || text[cursor] == "<" { return nil }
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex else { return includeUnterminated ? nil : .needMore }
            let closing = cursor
            let candidate = String(text[start..<closing])
            guard let normalized = normalizeAutolink(display: candidate, prefix: prefix) else { return nil }
            let afterClose = text.index(after: closing)
            return .handled(nextIndex: afterClose, display: normalized.display, url: normalized.url)
        }

        func parseLineBreakTag(at index: String.Index) -> LineBreakParseResult? {
            // Counting only the first four characters keeps this check
            // constant-time on a long pending text.
            if text[index...].prefix(4).count < 4 {
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
                                      bracketStart: String.Index,
                                      dryRun: Bool = false) -> TagParseResult? {
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
            if dryRun { return .handled(nextIndex: nextIndex) }
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
        /// With `dryRun`, only reports where the tag ends, emitting nothing:
        /// the emphasis lookahead gives tags the emitter's precedence.
        func parseTag(at index: String.Index, prefix: TagPrefix, dryRun: Bool = false) -> TagParseResult {
            // Left-boundary check — see suppressesAdjacentTag above.
            // Skip for beginning-of-buffer (no preceding char) and for paired
            // delimiters (their multi-char opening already provides a natural
            // boundary; "abc[[wiki]]" still recognises the wiki link).
            if index > text.startIndex, prefix.closing == nil {
                let prev = Character(text.unicodeScalars[text.unicodeScalars.index(before: index)])
                if suppressesAdjacentTag(prev) {
                    return .literal
                }
            }

            guard let openEnd = text.unicodeScalars.index(index, offsetBy: prefix.opening.unicodeScalars.count, limitedBy: text.endIndex) else {
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
                if dryRun { return .handled(nextIndex: nextIndex) }
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
                                                         bracketStart: openEnd,
                                                         dryRun: dryRun) {
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
            if dryRun { return .handled(nextIndex: endIndex) }

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

        /// Math that never closed, once the text is final: its opener is
        /// text (`$` stays itself, `\(` and `\[` are escaped brackets, as in
        /// CommonMark), and what followed it is parsed as usual, from where
        /// its content began. Returns whether any of the text is left.
        func reparseUnclosedMath() -> Bool {
            guard includeUnterminated, let state = mathState else { return false }
            let contentIndex = mathContentIndex(state)
            mathState = nil
            switch state.delimiter {
            case .dollar:
                appendPlain(state.openingMarker)
            case .command(let closing, _):
                appendPlain(String(state.openingMarker.dropFirst()))
                commandMathUnclosedFrom[closing] = min(commandMathUnclosedFrom[closing] ?? contentIndex, contentIndex)
            }
            index = contentIndex
            plainStart = contentIndex
            consumedEnd = contentIndex
            return index < text.endIndex
        }

        parsing: while index < text.endIndex || reparseUnclosedMath() {
            // The text of the innermost link or image ends at its `]`.
            if mathState == nil, let context = contexts.last, index >= context.close {
                index = closeContext()
                continue parsing
            }
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
            // ASCII syntax that a Prepend character joined into its grapheme
            // is handled where it stands; what precedes it stays plain text.
            if let syntax = syntaxInsideGrapheme(at: index) {
                index = syntax
                continue parsing
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
            if !contexts.isEmpty, case .none? = mathScan(at: index) {
                index = mathMarkerEnd(at: index)
                continue parsing
            }
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
                // Within the reach of an opener of the same kind that found no
                // closer, none is found either: the backslash is an escape.
                let unclosed = next < bytes.endIndex
                    && commandMathUnclosedFrom[bytes[next] == 0x28 ? 0x29 : 0x5D].map { bytes.index(after: next) >= $0 } == true
                if next < bytes.endIndex, bytes[next] == 0x28 || bytes[next] == 0x5B, !(includeUnterminated && unclosed) {
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

            let ch = syntaxCharacter(at: index)
            switch ch {
            case "\\":
                let nextIndex = text.unicodeScalars.index(after: index)
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
                let nextIndex = text.unicodeScalars.index(after: index)
                guard nextIndex < text.endIndex else {
                    if includeUnterminated {
                        index = nextIndex
                        continue parsing
                    } else {
                        consumedAll = false
                        break parsing
                    }
                }
                guard text.unicodeScalars[nextIndex] == "[" else {
                    index = nextIndex
                    continue parsing
                }
                flushPlain(upTo: index)
                switch bracket(at: index) {
                case .decided(let outcome):
                    if let next = open(outcome, at: index) {
                        index = next
                    } else {
                        // `![` that is not an image may still open a link.
                        plainStart = index
                        index = nextIndex
                    }
                case .needMore:
                    consumedAll = false
                    break parsing
                }
            case "[":
                flushPlain(upTo: index)
                switch bracket(at: index) {
                case .decided(let outcome):
                    if let next = open(outcome, at: index) {
                        index = next
                    } else {
                        plainStart = index
                        index = text.index(after: index)
                    }
                case .needMore:
                    consumedAll = false
                    break parsing
                }
            case "*", "_":
                let delimiter = ch
                if let plan = emphasisPlan, contexts.isEmpty {
                    // Emphasis content: the enclosing text already paired its
                    // delimiters (but not those in a link's text, which it
                    // skipped). Each one opens or closes the style of its
                    // pair, or is text.
                    switch plan[utf8Offset(of: index)] {
                    case .open(let pair, let length, let style)?:
                        flushPlain(upTo: index)
                        settleReplacements()
                        planStyles.append((pair, style))
                        index = text.utf8.index(index, offsetBy: length)
                        consumedEnd = index
                        plainStart = index
                    case .close(let pair, let length)?:
                        flushPlain(upTo: index)
                        settleReplacements()
                        planStyles.removeAll { $0.pair == pair }
                        index = text.utf8.index(index, offsetBy: length)
                        consumedEnd = index
                        plainStart = index
                    case nil:
                        index = text.index(after: index)
                    }
                    continue parsing
                }
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
                let innerPairs: [EmphasisScan.Pair]
                switch matchEmphasis(openerAt: index, flank: flank) {
                case .matched(let closer, let length, let literalPrefix, let inner):
                    // Unpaired delimiters at the left of the run are text
                    // (`**foo*` reads `*` then emphasis).
                    index = text.utf8.index(index, offsetBy: literalPrefix)
                    closingRange = closer
                    markerLength = length
                    innerPairs = inner
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
                let innerStart = text.utf8.index(index, offsetBy: markerLength)
                let inner = String(text[innerStart..<closingRange.lowerBound])
                let style: InlineStyle = markerLength == 2 ? [.bold] : [.italic]
                // The content is parsed apart, but its delimiter runs are
                // judged as in this text: the opener's delimiter precedes it
                // (and a run it starts with continues the opener's run), and
                // the closer follows it (and a run it ends with continues into
                // the closer's run).
                let openerRun = delimiterRun(containing: index)
                let leading = ConsumedContext(
                    tail: String(delimiter), alphanumeric: false, whitespace: false, punctuation: true,
                    trailingRun: ConsumedContext.TrailingRun(
                        delimiter: delimiter,
                        before: standIn(characterBefore(run: openerRun)),
                        length: runLength(openerRun) - delimiterCount(from: innerStart, to: openerRun.upperBound)))
                let closerRun = delimiterRun(containing: closingRange.lowerBound)
                var closerRunLength = delimiterCount(from: closingRange.lowerBound, to: closerRun.upperBound)
                var afterCloserRun = closerRun.upperBound < text.endIndex ? text[closerRun.upperBound].unicodeScalars.first : nil
                if closerRun.upperBound == text.endIndex, let following, following.delimiter == delimiter {
                    closerRunLength += following.runLength
                    afterCloserRun = following.afterRun
                }
                let trailing = FollowingContext(scalar: text[closingRange.lowerBound].unicodeScalars.first!,
                                                delimiter: delimiter, runLength: closerRunLength, afterRun: afterCloserRun)
                // The pairs inside were formed by the same algorithm in this
                // text; the content is styled by them, not matched again.
                let innerBase = utf8Offset(of: innerStart)
                var plan: [Int: EmphasisAction] = [:]
                for (number, pair) in innerPairs.enumerated() {
                    plan[pair.openerStart - innerBase] = .open(pair: number, length: pair.openerEnd - pair.openerStart,
                                                               style: pair.length == 2 ? [.bold] : [.italic])
                    plan[pair.closerStart - innerBase] = .close(pair: number, length: pair.closerEnd - pair.closerStart)
                }
                let nestedRuns = parseNestedRuns(from: inner, inheriting: style, leading: leading, trailing: trailing, plan: plan)
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
                let nextIndex = text.unicodeScalars.index(after: index)
                if nextIndex < text.endIndex && text[nextIndex] == "~" {
                    let searchStart = text.index(after: nextIndex)
                    if let closeAfter = findStrikethroughClosing(in: text, from: searchStart, before: contexts.last?.close) {
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
                    } else if !includeUnterminated, contexts.isEmpty {
                        // Streaming: we haven’t seen the closing "~~" yet. Emit all unambiguous
                        // plain text *before* the opener, then pause so we don’t emit provisional runs.
                        flushPlain(upTo: index)
                        consumedEnd = index
                        plainStart = index
                        consumedAll = false
                        break parsing
                    }
                }
                // A `~` at the end of the text may still become `~~`: wait.
                if nextIndex == text.endIndex, !includeUnterminated {
                    flushPlain(upTo: index)
                    consumedAll = false
                    break parsing
                }
                // No "~~" or still incomplete: treat the first "~" as plain and keep scanning.
                index = nextIndex
            case "`":
                // A closing run at the end of the text may still grow into a
                // longer run, which would be content (`` `a` `` then `` ` ``);
                // a span still open resumes its search with the next chunk.
                let content: Range<String.Index>
                let closingEnd: String.Index
                switch codeSpan(at: index) {
                case .closed(let range, let end):
                    content = range
                    closingEnd = end
                case .unclosed(let runEnd):
                    index = runEnd
                    continue parsing
                case .needMore:
                    consumedAll = false
                    break parsing
                }
                flushPlain(upTo: index)
                // Line endings inside a code span are spaces (CommonMark); this
                // also covers a hard-break newline the block layer inserted
                // before it could know the line ended inside a span.
                var inner = String(text[content]).replacingOccurrences(of: "\n", with: " ")
                // One space is stripped from each side when both are spaces and
                // the content is not only spaces (`` ` `` `` ` `` reads ``` `` ```).
                if inner.count >= 2, inner.first == " ", inner.last == " ", inner.contains(where: { $0 != " " }) {
                    inner = String(inner.dropFirst().dropLast())
                }
                appendStructured(InlineRun(text: inner, style: [.code]))
                let afterClose = closingEnd
                consumedEnd = afterClose
                index = afterClose
                plainStart = afterClose
            case "&":
                switch HTMLEntities.scan(text[...], at: index) {
                case .reference(let replacement, let end):
                    flushPlain(upTo: index)
                    appendPlain(replacement)
                    consumedEnd = end
                    index = end
                    plainStart = end
                case .partial where !includeUnterminated:
                    // `&am` may still become `&amp;`.
                    flushPlain(upTo: index)
                    consumedAll = false
                    break parsing
                case .partial, .none:
                    index = text.index(after: index)
                }
            case "h", "H", "w", "W":
                // No bare URL is linked inside a link's or image's text.
                if contexts.isEmpty, !insideLinkText, let result = parseAutolink(at: index) {
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
        bracketProgress = bracketProgress?.shifted(by: utf8Offset(of: consumedEnd))

        if consumedEnd > text.startIndex {
            let consumedBytes = text.utf8.distance(from: text.utf8.startIndex, to: consumedEnd)
            // Saved construct progress follows the text it describes.
            constructProgress = constructProgress?.shifted(by: consumedBytes)
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
                let punctuation = isPunctuation(last)
                // A trailing delimiter run keeps the class of the character
                // before it, carried over when the run began even earlier.
                var trailingRun: ConsumedContext.TrailingRun?
                // `consumedEnd` may sit inside a grapheme (math resumes at a
                // scalar boundary, syntax a Prepend character joined is
                // handled in place), so the run is found by scalars.
                let consumedScalars = consumed.unicodeScalars
                if let lastScalar = consumedScalars.last, lastScalar == "*" || lastScalar == "_",
                   case let lastIndex = consumedScalars.index(before: consumedScalars.endIndex), !isEscaped(lastIndex) {
                    let scalars = text.unicodeScalars
                    var runStart = lastIndex
                    while runStart > text.startIndex {
                        let previous = scalars.index(before: runStart)
                        guard scalars[previous] == lastScalar, !isEscaped(previous) else { break }
                        runStart = previous
                    }
                    let consumedLength = delimiterCount(from: runStart, to: consumedEnd)
                    if runStart == text.startIndex, var previous = lastConsumed?.trailingRun, previous.delimiter == Character(lastScalar) {
                        previous.length += consumedLength
                        trailingRun = previous
                    } else {
                        trailingRun = ConsumedContext.TrailingRun(delimiter: Character(lastScalar), before: standIn(character(before: runStart)),
                                                                  length: consumedLength)
                    }
                }
                if let previous = lastConsumed, consumed.dropFirst().isEmpty,
                   let merged = (previous.tail + String(last)).last,
                   (previous.tail + String(last)).count < previous.tail.count + 1 {
                    // A joined grapheme's last scalar is the one just consumed,
                    // which decides whitespace and punctuation.
                    lastConsumed = ConsumedContext(tail: joiningTail(of: merged),
                                                   alphanumeric: previous.alphanumeric && alphanumeric,
                                                   whitespace: whitespace,
                                                   punctuation: punctuation,
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
    private func findStrikethroughClosing(in s: String, from: String.Index, before limit: String.Index? = nil) -> String.Index? {
        let limit = limit ?? s.endIndex
        var i = from
        while i < limit {
            let ch = s[i]
            if ch == "\\" { // skip escaped next char
                i = s.index(after: i)
                if i < limit { i = s.index(after: i) }
                continue
            }
            if ch == "~" {
                let n = s.index(after: i)
                if n < limit, s[n] == "~" {
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
