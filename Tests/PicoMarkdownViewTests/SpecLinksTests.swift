import Foundation
import Testing
@testable import PicoMarkdownView

/// Links and images from the fourth conformance batch: inline destinations
/// and titles, nested brackets, inline content in link text, no links inside
/// links, and the constructs that bind tighter than brackets. The conformance
/// suite proves the single-shot text; these prove that streaming gives the
/// same result at every chunk split, and pin the styles.
@Suite
struct SpecLinksTests {
    /// Each document with its expected rendering: `<code>`, `<b>`, `<i>` and
    /// `<a url>` wrap runs with that style, `<img source>` an image's alt text.
    static let cases: [(markdown: String, styled: String)] = [
        // Destinations and titles.
        ("[link](/uri \"title\")\n\n", "<a /uri>link</a>"),
        ("[link](</my uri>)\n\n", "<a /my uri>link</a>"),
        ("[link](/my uri)\n\n", "[link](/my uri)"),
        ("[a](<b)c>)\n\n", "<a b)c>a</a>"),
        ("[link](foo\\(and\\(bar\\))\n\n", "<a foo(and(bar)>link</a>"),
        ("[link](foo(and(bar)))\n\n", "<a foo(and(bar))>link</a>"),
        ("[link](/url 'title \"and\" title')\n\n", "<a /url>link</a>"),
        ("[link](/url \"title \"and\" title\")\n\n", "[link](/url \"title \"and\" title\")"),
        ("[link]()\n\n", "<a >link</a>"),
        ("[a\nb](\n/u\n)\n\n", "<a /u>a b</a>"),
        // Link text: balanced brackets, inline content, no links inside.
        ("[link [foo [bar]]](/uri)\n\n", "<a /uri>link [foo [bar]]</a>"),
        ("[link *foo **bar** `#`*](/uri)\n\n",
         "<a /uri>link </a><i><a /uri>foo </a></i><b><i><a /uri>bar</a></i></b><i><a /uri> </a></i><code><a /uri>#</a></code>"),
        ("[foo [bar](/uri)](/uri)\n\n", "[foo <a /uri>bar</a>](/uri)"),
        ("[a [b](c) [d](e)](f)\n\n", "[a <a c>b</a> <a e>d</a>](f)"),
        ("[link [bar](/uri)\n\n", "[link <a /uri>bar</a>"),
        // Images: the alt text is the content's plain text; an image may hold
        // a link, and a link an image.
        ("![foo *bar*](/url)\n\n", "<img /url>foo bar</img>"),
        ("![[[foo](uri1)](uri2)](uri3)\n\n", "<img uri3>[foo](uri2)</img>"),
        ("[![moon](moon.jpg)](/uri)\n\n", "<img moon.jpg>moon</img>"),
        ("x ![a](b) y\n\n", "x <img b>a</img> y"),
        // Code spans, raw HTML and autolinks bind tighter than brackets.
        ("[foo`](/uri)`\n\n", "[foo<code>](/uri)</code>"),
        ("[foo <bar attr=\"](baz)\">\n\n", "[foo <bar attr=\"](baz)\">"),
        ("[foo<https://example.com/?search=](uri)>\n\n",
         "[foo<a https://example.com/?search=](uri)>https://example.com/?search=](uri)</a>"),
        // Brackets bind tighter than emphasis, on either side of the link.
        ("*[foo*](/u)\n\n", "*<a /u>foo*</a>"),
        ("[foo *bar](/u)*\n\n", "<a /u>foo *bar</a>*"),
        ("**[a](b) c**\n\n", "<b><a b>a</a></b><b> c</b>"),
        ("*a [*b*](u) c*\n\n", "<i>a </i><i><a u>b</a></i><i> c</i>"),
        // Nothing in a link's text reaches past its `]`: no bare URL is
        // linked, and strikethrough closes inside.
        ("[see https://x.com](/u)\n\n", "<a /u>see https://x.com</a>"),
        ("[a ~~b](/u)~~\n\n", "<a /u>a ~~b</a>~~"),
        // Links do not nest: the link's target wins over any link inside
        // its text, also in emphasis or strikethrough there.
        ("[*https://evil.com*](https://good.com)\n\n", "<i><a https://good.com>https://evil.com</a></i>"),
        ("[~~https://evil.com~~](https://good.com)\n\n", "<a https://good.com>https://evil.com</a>"),
        ("[<https://evil.com>](https://good.com)\n\n", "<a https://good.com>https://evil.com</a>"),
        // An image inside a link does not deactivate it, at any split.
        ("[a ![x](u)](v)\n\n", "<a v>a </a><img u>x</img>"),
        ("x [a ![x](u)](v)\n\n", "x <a v>a </a><img u>x</img>"),
        ("*x [a ![x](u)](v)*\n\n", "<i>x </i><i><a v>a </a></i><img u>x</img>"),
        // References to labels defined before them.
        ("[foo]: /url\n\n[foo] and [Foo][] and [x][FOO]\n\n",
         "<a /url>foo</a> and <a /url>Foo</a> and <a /url>x</a>"),
        ("[foo]: /url\n\n[foo][bar] then [foo]\n\n", "[foo][bar] then <a /url>foo</a>"),
        ("[foo]: /url\n\n[foo](not a link)\n\n", "<a /url>foo</a>(not a link)"),
        ("[foo]: /url\n\n[foo][bar\n\n", "<a /url>foo</a>[bar"),
        ("[foo]: /url\n\n![foo] x\n\n", "<img /url>foo</img> x"),
        ("[*foo* bar]: /url\n\n[*foo* bar]\n\n", "<i><a /url>foo</a></i><a /url> bar</a>")
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
        var groups: [(style: InlineStyle, url: String?, image: String?, text: String)] = []
        for run in blocks.flatMap({ $0.inlineRuns ?? [] }) {
            if let last = groups.last, last.style == run.style, last.url == run.linkURL, last.image == nil, run.image == nil {
                groups[groups.count - 1].text += run.text
            } else {
                groups.append((run.style, run.linkURL, run.image?.source, run.text))
            }
        }
        var result = ""
        for group in groups {
            var open = "", close = ""
            if let source = group.image { open += "<img \(source)>"; close = "</img>" + close }
            if group.style.contains(.code) { open += "<code>"; close = "</code>" + close }
            if group.style.contains(.bold) { open += "<b>"; close = "</b>" + close }
            if group.style.contains(.italic) { open += "<i>"; close = "</i>" + close }
            if let url = group.url { open += "<a \(url)>"; close = "</a>" + close }
            result += open + group.text + close
        }
        return result.trimmingCharacters(in: .newlines)
    }

    @Test("Each link construct parses the same at every chunk split", arguments: documents)
    func everyChunkSplit(markdown: String) async {
        let baseline = await parse([markdown])
        let characters = Array(markdown)
        for split in 0...characters.count {
            let streamed = await parse([String(characters[..<split]), String(characters[split...])])
            #expect(streamed == baseline, "Split at character \(split)")
        }
        #expect(await parse(characters.map(String.init)) == baseline)
    }

    @Test("Each link construct parses the same when split between any two scalars", arguments: documents)
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

    @Test("Each link construct has the CommonMark styles")
    func styles() async {
        for (markdown, expected) in Self.cases {
            #expect(styled(await parse([markdown])) == expected, Comment(rawValue: markdown))
        }
    }

    @Test("Unclosed openers are decided by one scan, not one scan each")
    func unclosedOpenersAreLinear() {
        let count = 20_000
        let runs = InlineParser.parseAll(String(repeating: "[", count: count) + "a")
        #expect(runs.map(\.text).joined() == String(repeating: "[", count: count) + "a")
    }

    @Test("A bracket waiting for its `]` resumes its scan with each chunk")
    func waitingBracketStreams() async {
        let markdown = "see [" + String(repeating: "a ", count: 8_000) + "*b*](/u) and *c*\n\n"
        let characters = Array(markdown)
        let chunks = stride(from: 0, to: characters.count, by: 16).map {
            String(characters[$0..<min($0 + 16, characters.count)])
        }
        let whole = await parse([markdown])
        #expect(await parse(chunks) == whole)
        #expect(styled(whole).hasSuffix("<i><a /u>b</a></i> and <i>c</i>"))
    }

    @Test("Deeply nested images are parsed in one pass, not once per level")
    func deepImagesAreFlat() {
        let depth = 2_000
        let runs = InlineParser.parseAll(String(repeating: "![", count: depth) + "a" + String(repeating: "](b)", count: depth))
        #expect(runs.count == 1)
        #expect(runs.first?.text == "a")
        #expect(runs.first?.image?.source == "b")
    }

    @Test("A link deactivates the openers before it, which stay text")
    func linksInsideLinkTextAreLinear() {
        let count = 2_000
        let runs = InlineParser.parseAll(String(repeating: "[a ", count: count) + "[b](c)" + String(repeating: "](d)", count: count))
        #expect(runs.map(\.text).joined() == String(repeating: "[a ", count: count) + "b" + String(repeating: "](d)", count: count))
        #expect(runs.filter { $0.linkURL != nil }.map(\.text) == ["b"])
    }

    @Test("Links inside nested images deactivate nothing in constant time each")
    func linksInsideNestedImagesAreLinear() {
        let count = 4_000
        let markdown = String(repeating: "![", count: count) + String(repeating: "[x](u)", count: count)
            + String(repeating: "](i)", count: count)
        let runs = InlineParser.parseAll(markdown)
        #expect(runs.count == 1)
        #expect(runs.first?.text == String(repeating: "x", count: count))
        #expect(runs.first?.image?.source == "i")
    }
}
