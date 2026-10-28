import Foundation
import Testing
@testable import PicoMarkdownView

/// Link reference definitions from the fifth conformance batch: definitions
/// over several lines, titles on the next line, and the lines that are not
/// definitions after all. The conformance suite proves the single-shot text;
/// these prove that streaming gives the same result at every chunk split.
@Suite
struct SpecLinkDefinitionsTests {
    /// Each document with its expected rendering: blocks are separated by
    /// ` | `, `<a url>` wraps a link and `<pre>` a code block's text.
    static let cases: [(markdown: String, rendered: String)] = [
        // The destination and the title may each go on to the next line.
        ("[foo]:\n/url\n\n[foo]\n\n", "<a /url>foo</a>"),
        ("   [foo]: \n      /url  \n           'the title'  \n\n[foo]\n\n", "<a /url>foo</a>"),
        ("[Foo bar]:\n<my url>\n'title'\n\n[Foo bar]\n\n", "<a my url>Foo bar</a>"),
        ("[foo]: /url '\ntitle\nline1\nline2\n'\n\n[foo]\n\n", "<a /url>foo</a>"),
        // So may the label.
        ("[\nfoo\n]: /url\nbar\n\n", "bar"),
        ("[Foo\n  bar]: /url\n\n[Baz][Foo bar]\n\n", "<a /url>Baz</a>"),
        // A title may not span a blank line, nor be followed by text; a title
        // that fails on the next line leaves the definition without it.
        ("[foo]: /url 'title\n\nwith blank line'\n\n[foo]\n\n", "[foo]: /url 'title | with blank line' | [foo]"),
        ("[foo]: /url \"title\" ok\n\n", "[foo]: /url \"title\" ok"),
        ("[foo]: /url\n\"title\" ok\n\n[foo]\n\n", "\"title\" ok | <a /url>foo</a>"),
        ("[foo]: <bar>(baz)\n\n[foo]\n\n", "[foo]: <bar>(baz) | [foo]"),
        // Several definitions in a row, and the paragraph after them.
        ("[foo]: /foo-url \"foo\"\n[bar]: /bar-url\n  \"bar\"\n[baz]: /baz-url\n\n[foo],\n[bar],\n[baz]\n\n",
         "<a /foo-url>foo</a>, <a /bar-url>bar</a>, <a /baz-url>baz</a>"),
        ("[foo]: /url\nbar [foo]\n\n", "bar <a /url>foo</a>"),
        ("[foo]: /url\n===\n[foo]\n\n", "=== <a /url>foo</a>"),
        // A definition cannot interrupt a paragraph, and code holds none.
        ("Foo\n[bar]: /baz\n\n[bar]\n\n", "Foo [bar]: /baz | [bar]"),
        ("```\n[foo]: /url\n```\n\n[foo]\n\n", "<pre>[foo]: /url</pre> | [foo]"),
        // A block that interrupts a paragraph ends the held lines.
        ("[foo]:\n# bar\n\n", "[foo]: | bar"),
        ("[foo]: /url\n# bar [foo]\n\n", "bar <a /url>foo</a>"),
        // Lines that only looked like a definition are a paragraph.
        ("[Note this\nis text] more\n\n", "[Note this is text] more"),
        ("[foo] [bar]: /url\n\n", "[foo] [bar]: /url"),
        ("[Foo*bar\\]]:my_(url) 'title (with parens)'\n\n[Foo*bar\\]]\n\n", "<a my_(url)>Foo*bar]</a>"),
        // The end of the text decides too.
        ("[foo]: /url\n[foo]", "<a /url>foo</a>"),
        ("[foo]:", "[foo]:")
    ]

    static let documents = cases.map(\.markdown)

    private func parse(_ chunks: [String]) async -> [BlockSnapshot] {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        for chunk in chunks { _ = await assembler.apply(await tokenizer.feed(chunk)) }
        _ = await assembler.apply(await tokenizer.finish())
        return await assembler.makeSnapshot()
    }

    private func rendered(_ blocks: [BlockSnapshot]) -> String {
        blocks.map { block in
            if let code = block.codeText { return "<pre>" + code.trimmingCharacters(in: .newlines) + "</pre>" }
            var text = ""
            for run in block.inlineRuns ?? [] {
                text += run.linkURL.map { "<a \($0)>" + run.text + "</a>" } ?? run.text
            }
            return text.trimmingCharacters(in: .newlines)
        }.joined(separator: " | ")
    }

    @Test("Each definition parses the same at every chunk split", arguments: documents)
    func everyChunkSplit(markdown: String) async {
        let baseline = await parse([markdown])
        let characters = Array(markdown)
        for split in 0...characters.count {
            let streamed = await parse([String(characters[..<split]), String(characters[split...])])
            #expect(streamed == baseline, "Split at character \(split)")
        }
        #expect(await parse(characters.map(String.init)) == baseline)
    }

    @Test("Each definition parses the same when split between any two scalars", arguments: documents)
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

    @Test("Each definition renders as CommonMark reads it")
    func rendering() async {
        for (markdown, expected) in Self.cases {
            #expect(rendered(await parse([markdown])) == expected, Comment(rawValue: markdown))
        }
    }

    @Test("Text after a complete definition streams before its line ends")
    func paragraphAfterDefinitionStreams() async {
        let tokenizer = MarkdownTokenizer()
        _ = await tokenizer.feed("[foo]: /url\n")
        let result = await tokenizer.feed("Some text")
        let streamed = result.events.compactMap { event -> String? in
            if case .blockAppendInline(_, let runs) = event { return runs.map(\.text).joined() }
            return nil
        }.joined()
        #expect(streamed == "Some text")
    }

    @Test("A long definition with an escaped bracket in its label streams in small chunks")
    func escapedLabelStreams() async {
        let markdown = "[a\\]b]: /" + String(repeating: "x", count: 16_000) + "\n\n[a\\]b]\n\n"
        let characters = Array(markdown)
        let chunks = stride(from: 0, to: characters.count, by: 16).map {
            String(characters[$0..<min($0 + 16, characters.count)])
        }
        let whole = await parse([markdown])
        #expect(await parse(chunks) == whole)
        #expect(whole.flatMap { $0.inlineRuns ?? [] }.compactMap(\.linkURL).first?.count == 16_001)
    }

    @Test("A line that may still hold a title waits for its end")
    func titleLineWaits() async {
        let tokenizer = MarkdownTokenizer()
        _ = await tokenizer.feed("[foo]: /url\n")
        let waiting = await tokenizer.feed("\"title")
        #expect(waiting.events.isEmpty)
        let done = await tokenizer.feed("\"\n\n[foo]\n\n")
        let links = done.events.flatMap { event -> [InlineRun] in
            if case .blockAppendInline(_, let runs) = event { return runs }
            return []
        }.filter { $0.linkURL == "/url" }
        #expect(links.map(\.text) == ["foo"])
    }
}
