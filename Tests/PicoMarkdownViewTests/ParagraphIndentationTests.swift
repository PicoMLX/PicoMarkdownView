import Foundation
import Testing
@testable import PicoMarkdownView

/// Each line of a paragraph loses its leading spaces and tabs (CommonMark),
/// at the top level, in quotes and in list items, whether the line belongs
/// to the paragraph's container or continues it lazily. The conformance
/// shapes collapse whitespace, so these check the text exactly.
@Suite
struct ParagraphIndentationTests {
    static let cases: [(markdown: String, kind: BlockKind, text: String)] = [
        ("a\n   b\n\n", .paragraph, "a b"),
        ("   a\n\tb\n\n", .paragraph, "a b"),
        ("> a\n>    b\n\n", .blockquote, "a\nb\n"),
        ("> a\n   b\n\n", .blockquote, "a\nb\n"),
        ("- a\n    b\n\n", .listItem(ordered: false, index: nil, task: nil), "a\nb\n"),
        ("- a\n\n  b\n     c\n\n", .paragraph, "b c"),
        ("[^n]: a\n   b\n\n", .footnoteDefinition(id: "n", index: 1), "a b")
    ]

    static let documents = cases.map(\.markdown)

    private func parse(_ chunks: [String]) async -> [BlockSnapshot] {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        for chunk in chunks { _ = await assembler.apply(await tokenizer.feed(chunk)) }
        _ = await assembler.apply(await tokenizer.finish())
        return await assembler.makeSnapshot()
    }

    @Test("A paragraph's lines start at their first character")
    func linesLoseLeadingWhitespace() async {
        for (markdown, kind, expected) in Self.cases {
            let blocks = await parse([markdown])
            let text = blocks.last { $0.kind == kind }.map { ($0.inlineRuns ?? []).map(\.text).joined() }
            #expect(text == expected, Comment(rawValue: markdown.debugDescription))
        }
    }

    @Test("Each document parses the same at every chunk split", arguments: documents)
    func everyChunkSplit(markdown: String) async {
        let baseline = await parse([markdown])
        let characters = Array(markdown)
        for split in 0...characters.count {
            let streamed = await parse([String(characters[..<split]), String(characters[split...])])
            #expect(streamed == baseline, "Split at character \(split)")
        }
        #expect(await parse(characters.map(String.init)) == baseline)
    }
}
