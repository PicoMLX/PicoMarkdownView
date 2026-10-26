import Foundation
import Testing
@testable import PicoMarkdownView

/// Inline CommonMark fixes from the third conformance batch: code span
/// delimiter runs, emphasis flanking and the delimiter-stack matching, and
/// the constructs that bind tighter than emphasis (code spans, autolinks, raw
/// HTML). The conformance suite proves the single-shot text; these prove that
/// streaming gives the same result at every chunk split, and pin the styles.
@Suite
struct SpecInlineFixesTests {
    /// Each document with its expected rendering: `<code>`, `<b>`, `<i>` and
    /// `<a url>` wrap runs with that style.
    static let cases: [(markdown: String, styled: String)] = [
        // Code spans: a closing run must have exactly the opener's length; one
        // space is stripped from each side.
        ("` `` `\n\n", "<code>``</code>"),
        ("` foo `` bar `\n\n", "<code>foo `` bar</code>"),
        ("`foo``bar``\n\n", "`foo<code>bar</code>"),
        ("`a``b`\n\n", "<code>a``b</code>"),
        // Code spans and raw HTML bind tighter than emphasis and each other.
        ("*foo`*`\n\n", "*foo<code>*</code>"),
        ("<a href=\"`\">`\n\n", "<a href=\"`\">`"),
        ("foo <a href=\"\\*\">\n\n", "foo <a href=\"\\*\">"),
        ("**a<https://foo.bar/?q=**>\n\n", "**a<a https://foo.bar/?q=**>https://foo.bar/?q=**</a>"),
        // Autolinks with any scheme, and email autolinks.
        ("<irc://foo.bar:2233/baz>\n\n", "<a irc://foo.bar:2233/baz>irc://foo.bar:2233/baz</a>"),
        ("<foo@bar.example.com>\n\n", "<a mailto:foo@bar.example.com>foo@bar.example.com</a>"),
        // Flanking: whitespace or punctuation around a run decides.
        ("a * foo bar*\n\n", "a * foo bar*"),
        ("*(*foo)\n\n", "*(*foo)"),
        ("foo__bar__\n\n", "foo__bar__"),
        ("**foo bar **\n\n", "**foo bar **"),
        ("\u{2764}_b_\n\n", "\u{2764}_b_"),
        ("!_b_\n\n", "!<i>b</i>"),
        // The delimiter stack: nesting, the rule of three, partial runs.
        ("*(*foo*)*\n\n", "<i>(foo)</i>"),
        ("*foo **bar** baz*\n\n", "<i>foo </i><b><i>bar</i></b><i> baz</i>"),
        ("*foo**bar*\n\n", "<i>foo**bar</i>"),
        ("***foo***\n\n", "<b><i>foo</i></b>"),
        ("**foo*\n\n", "*<i>foo</i>"),
        ("****foo*\n\n", "***<i>foo</i>"),
        // A run that closes one span and opens the next: the rule of three
        // counts the whole run, also when a chunk boundary follows the first span.
        ("**a***b** c\n\n", "<b>a</b><i>b</i>* c"),
        // A waiting opener's scan resumes at every split, past a code span,
        // raw HTML and an escaped delimiter.
        ("*a `b*` <x y=\"*\"> c\\* d*\n\n", "<i>a </i><code>b*</code><i> <x y=\"*\"> c* d</i>"),
        ("x <span title=\"a*b\">*c*</span>\n\n", "x <span title=\"a*b\"><i>c</i></span>"),
        ("<!-- *a* --> *b*\n\n", "<!-- *a* --> <i>b</i>"),
        // Math is opaque to the emphasis lookahead, as to the emitter.
        ("**The expression $\\text{`x'}$ is valid** and `code`\n\n",
         "<b>The expression </b>\\text{`x'}<b> is valid</b> and <code>code</code>"),
        ("*a $b*c$ d*\n\n", "<i>a </i>b*c<i> d</i>"),
        ("**Price: $5 per unit** and more\n\n", "<b>Price: $5 per unit</b> and more"),
        // Flanking reads code points: a mark joining the space after a run
        // does not change that the run is followed by whitespace.
        ("a * \u{301}* b\n\n", "a * \u{301}* b"),
        // `<!-->` and `<!--->` are complete comments: what follows is Markdown.
        ("foo <!--> *bar* -->\n\n", "foo <!--> <i>bar</i> -->"),
        ("foo <!---> *bar* -->\n\n", "foo <!---> <i>bar</i> -->"),
        // ASCII syntax counts by bytes: a backtick or `>` that shares a
        // grapheme with a Prepend character or a mark is still syntax.
        ("`a\u{600}` b\n\n", "<code>a\u{600}</code> b"),
        ("<irc:foo>\u{301} x\n\n", "<a irc:foo>irc:foo</a>\u{301} x"),
        ("foo *\\**\n\n", "foo <i>*</i>"),
        // Text the replacement engine holds stays before a following run.
        ("(`x`)\n\n", "(<code>x</code>)"),
        ("(c`x`)\n\n", "(c<code>x</code>)")
    ]

    static let documents = cases.map(\.markdown)

    private func parse(_ chunks: [String]) async -> [BlockSnapshot] {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        for chunk in chunks { _ = await assembler.apply(await tokenizer.feed(chunk)) }
        _ = await assembler.apply(await tokenizer.finish())
        return await assembler.makeSnapshot()
    }

    /// The document's inline runs with adjacent runs of one style merged and
    /// each style written as a tag.
    private func styled(_ blocks: [BlockSnapshot]) -> String {
        var groups: [(style: InlineStyle, url: String?, text: String)] = []
        for run in blocks.flatMap({ $0.inlineRuns ?? [] }) {
            if let last = groups.last, last.style == run.style, last.url == run.linkURL {
                groups[groups.count - 1].text += run.text
            } else {
                groups.append((run.style, run.linkURL, run.text))
            }
        }
        var result = ""
        for group in groups {
            var open = "", close = ""
            if group.style.contains(.code) { open += "<code>"; close = "</code>" + close }
            if group.style.contains(.bold) { open += "<b>"; close = "</b>" + close }
            if group.style.contains(.italic) { open += "<i>"; close = "</i>" + close }
            if let url = group.url { open += "<a \(url)>"; close = "</a>" + close }
            result += open + group.text + close
        }
        return result.trimmingCharacters(in: .newlines)
    }

    @Test("Each fixed construct parses the same at every chunk split", arguments: documents)
    func everyChunkSplit(markdown: String) async {
        let baseline = await parse([markdown])
        let characters = Array(markdown)
        for split in 0...characters.count {
            let streamed = await parse([String(characters[..<split]), String(characters[split...])])
            #expect(streamed == baseline, "Split at character \(split)")
        }
        #expect(await parse(characters.map(String.init)) == baseline)
    }

    @Test("Each fixed construct parses the same when split between any two scalars", arguments: documents)
    func everyScalarSplit(markdown: String) async {
        let baseline = await parse([markdown])
        let scalars = Array(markdown.unicodeScalars)
        for split in 0...scalars.count {
            var head = String.UnicodeScalarView(), tail = String.UnicodeScalarView()
            head.append(contentsOf: scalars[..<split])
            tail.append(contentsOf: scalars[split...])
            #expect(await parse([String(head), String(tail)]) == baseline, "Split at scalar \(split)")
        }
    }

    @Test("A registered tag takes precedence over math in the emphasis lookahead, as in the emitter")
    func tickerInsideEmphasis() {
        let prefixes: Set<TagPrefix> = [.mention, .hashtag, .ticker]
        let runs = InlineParser.parseAll("*$AAPL* plus $MSFT", tagPrefixes: prefixes)
        let ticker = runs.first { $0.tag != nil }
        #expect(ticker?.text == "$AAPL")
        #expect(ticker?.style.contains(.italic) == true)
        #expect(runs.map(\.text).joined() == "$AAPL plus $MSFT")
    }

    @Test("Unclosed command math is searched once, not once per opener")
    func unclosedCommandMathIsLinear() {
        let count = 4_000
        let runs = InlineParser.parseAll("**" + String(repeating: "\\(x ", count: count) + "end**")
        #expect(runs.map(\.text).joined() == String(repeating: "\\(x ", count: count) + "end")
        #expect(runs.allSatisfy { $0.style.contains(.bold) })
    }

    @Test("Each fixed construct has the CommonMark styles")
    func styles() async {
        for (markdown, expected) in Self.cases {
            #expect(styled(await parse([markdown])) == expected, Comment(rawValue: markdown))
        }
    }

    @Test("A closing backtick run at the end of a chunk waits: it may still grow")
    func codeSpanCloserWaits() {
        var parser = InlineParser()
        #expect(parser.append("`a`").isEmpty, "`a` then a backtick is not a closed span")
        let runs = parser.append("`b`") + parser.finish()
        #expect(runs.map(\.text) == ["a``b"])
        #expect(runs.allSatisfy { $0.style == [.code] })
    }

    @Test("A long run's unpaired delimiters are text, resolved in one scan of the run")
    func longRunResolvesOnce() {
        let count = 20_000
        let runs = InlineParser.parseAll(String(repeating: "*", count: count) + "foo*")
        #expect(runs.map(\.text).joined() == String(repeating: "*", count: count - 1) + "foo")
        #expect(runs.last?.style == [.italic])
        let unpaired = InlineParser.parseAll(String(repeating: "*", count: count) + "foo")
        #expect(unpaired.map(\.text).joined() == String(repeating: "*", count: count) + "foo")
    }

    @Test("A run's delimiters consumed by an earlier chunk still count for the rule of three")
    func ruleOfThreeAcrossChunks() async {
        let whole = await parse(["**a***b** c\n\n"])
        #expect(await parse(["**a***b", "** c\n\n"]) == whole)
        #expect(styled(whole) == "<b>a</b><i>b</i>* c")
    }

    @Test("Unpaired closers of one character do not search the other character's openers")
    func unpairedClosersStayLinear() {
        let count = 800
        let markdown = String(repeating: "*a ", count: count) + String(repeating: "b_ ", count: count) + "c*"
        let runs = InlineParser.parseAll(markdown)
        // The last star pairs with the nearest star opener; everything else is text.
        #expect(runs.map(\.text).joined() == String(repeating: "*a ", count: count - 1) + "a " + String(repeating: "b_ ", count: count) + "c")
        #expect(runs.last?.style == [.italic])
    }

    @Test("Openers between completed pairs are resolved without rescanning")
    func openersBetweenPairs() {
        let count = 800
        let runs = InlineParser.parseAll(String(repeating: "*a _b_ ", count: count))
        #expect(runs.map(\.text).joined() == String(repeating: "*a b ", count: count))
        #expect(runs.filter { $0.style == [.italic] }.count == count)
    }

    @Test("A long quoted HTML attribute streams in small chunks like the whole text")
    func longHTMLAttributeStreams() async {
        let markdown = "text <span title=\"" + String(repeating: "a", count: 16_000) + "\">*end*\n\n"
        let characters = Array(markdown)
        let chunks = stride(from: 0, to: characters.count, by: 16).map {
            String(characters[$0..<min($0 + 16, characters.count)])
        }
        let whole = await parse([markdown])
        #expect(await parse(chunks) == whole)
        #expect(styled(whole).hasSuffix("\"><i>end</i>"))
    }

    @Test("Streaming the unpaired-closer input in small chunks matches the whole parse")
    func unpairedClosersStream() async {
        let markdown = String(repeating: "*a ", count: 300) + String(repeating: "b_ ", count: 300) + "c*\n\n"
        let characters = Array(markdown)
        let chunks = stride(from: 0, to: characters.count, by: 4).map {
            String(characters[$0..<min($0 + 4, characters.count)])
        }
        #expect(await parse(chunks) == (await parse([markdown])))
    }

    @Test("Text before an emphasis run whose flanking is still open is delivered at once")
    func textBeforeAmbiguousRunStreams() {
        var parser = InlineParser()
        #expect(parser.append("see *").map(\.text).joined() == "see ")
        let runs = parser.append("this*") + parser.finish()
        #expect(runs.map(\.text) == ["this"])
        #expect(runs.first?.style == [.italic])
    }
}
