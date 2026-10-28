import Foundation
import Testing
@testable import PicoMarkdownView

/// Entity and numeric character references from the sixth conformance batch.
/// The conformance suite proves the single-shot text; these prove that
/// streaming gives the same result at every chunk split, and pin the text.
@Suite
struct SpecEntitiesTests {
    /// Each document with its expected rendering: blocks are separated by
    /// ` | `, `<a url>` wraps a link, `<code>` a code span and `<pre lang>` a
    /// code block.
    static let cases: [(markdown: String, rendered: String)] = [
        ("&nbsp; &amp; &copy; &AElig; &Dcaron;\n\n", "\u{A0} & © Æ Ď"),
        ("&ClockwiseContourIntegral; &ngE;\n\n", "∲ ≧̸"),
        ("&#35; &#1234; &#992; &#0;\n\n", "# Ӓ Ϡ \u{FFFD}"),
        ("&#X22; &#XD06; &#xcab;\n\n", "\" ആ ಫ"),
        // Not references: no semicolon, no digits, an unknown name, too many
        // digits.
        ("&nbsp &x; &#; &#x; &#abcdef0; &ThisIsNotDefined; &hi?; &#12345678;\n\n",
         "&nbsp &x; &#; &#x; &#abcdef0; &ThisIsNotDefined; &hi?; &#12345678;"),
        ("AT&T and R&D\n\n", "AT&T and R&D"),
        // Digits are ASCII only, in text and in destinations.
        ("&#１２３; &#xＦＦ;\n\n", "&#１２３; &#xＦＦ;"),
        ("[a](/&#x４１;)\n\n", "<a /&#x４１;>a</a>"),
        // A reference is text, never markup; an escaped `&` starts none.
        ("&#42;foo&#42; *bar*\n\n", "*foo* bar"),
        ("&#42; foo\n\n", "* foo"),
        ("\\&amp; &amp;amp;\n\n", "&amp; &amp;"),
        // Not in code spans or code blocks; in destinations, titles and info
        // strings.
        ("`f&ouml;&ouml;` f&ouml;&ouml;\n\n", "<code>f&ouml;&ouml;</code> föö"),
        ("[a](/f&ouml;&ouml; \"f&ouml;&ouml;\")\n\n", "<a /föö>a</a>"),
        ("[a](url &quot;tit&quot;)\n\n", "[a](url \"tit\")"),
        ("[foo]: /f&ouml;&ouml;\n\n[foo]\n\n", "<a /föö>foo</a>"),
        ("``` f&ouml;&ouml;\nfoo\n```\n\n", "<pre föö>foo</pre>"),
        // Emphasis and brackets treat a reference as one unit.
        ("*a &amp; b*\n\n", "a & b"),
        ("[a &#93; b](/u)\n\n", "<a /u>a ] b</a>")
    ]

    static let documents = cases.map(\.markdown)

    /// Without tag prefixes: `&#x;` would otherwise hold a `#x` hashtag.
    private func parse(_ chunks: [String]) async -> [BlockSnapshot] {
        let tokenizer = MarkdownTokenizer(tagPrefixes: [])
        let assembler = MarkdownAssembler()
        for chunk in chunks { _ = await assembler.apply(await tokenizer.feed(chunk)) }
        _ = await assembler.apply(await tokenizer.finish())
        return await assembler.makeSnapshot()
    }

    private func rendered(_ blocks: [BlockSnapshot]) -> String {
        blocks.map { block in
            if let code = block.codeText {
                var language = ""
                if case .fencedCode(let info?) = block.kind { language = " " + info }
                return "<pre\(language)>" + code.trimmingCharacters(in: .newlines) + "</pre>"
            }
            var text = ""
            for run in block.inlineRuns ?? [] {
                var piece = run.style.contains(.code) ? "<code>" + run.text + "</code>" : run.text
                if let url = run.linkURL { piece = "<a \(url)>" + piece + "</a>" }
                text += piece
            }
            return text.trimmingCharacters(in: .newlines)
        }.joined(separator: " | ")
    }

    @Test("Each reference parses the same at every chunk split", arguments: documents)
    func everyChunkSplit(markdown: String) async {
        let baseline = await parse([markdown])
        let characters = Array(markdown)
        for split in 0...characters.count {
            let streamed = await parse([String(characters[..<split]), String(characters[split...])])
            #expect(streamed == baseline, "Split at character \(split)")
        }
        #expect(await parse(characters.map(String.init)) == baseline)
    }

    @Test("Each reference parses the same when split between any two scalars", arguments: documents)
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

    @Test("Each reference renders as CommonMark reads it")
    func rendering() async {
        for (markdown, expected) in Self.cases {
            let actual = rendered(await parse([markdown]))
            #expect(actual == expected, Comment(rawValue: markdown + " → " + actual))
        }
    }

    @Test("An `&` waits only while it may still become a reference")
    func ampersandWaitsBriefly() {
        var parser = InlineParser()
        #expect(parser.append("a &am").map(\.text).joined() == "a ")
        #expect(parser.append("p; b").map(\.text).joined() == "& b")
        #expect(parser.append(" & c").map(\.text).joined() == " & c")
    }
}
