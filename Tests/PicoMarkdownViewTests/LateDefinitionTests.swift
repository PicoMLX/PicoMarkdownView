import Foundation
import Testing
@testable import PicoMarkdownView

/// A link definition that arrives after the text already used its label,
/// as in a list of sources after the text that cites them: those
/// references went out as text, so the definition shows as a paragraph
/// instead of disappearing. It still links the references after it. A
/// definition nothing used yet stays hidden (CommonMark).
@Suite
struct LateDefinitionTests {
    static let documents = [
        "See [1] and [2].\n\n[1]: https://a.example\n[2]: https://b.example \"B\"\n\nAgain [1].\n",
        "[1]: https://a.example\n\nSee [1].\n",
        "Text.\n\n[x]: /url\n",
        "- See [1].\n\n  [1]: https://a.example\n"
    ]

    private func parse(_ chunks: [String]) async -> [BlockSnapshot] {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        for chunk in chunks { _ = await assembler.apply(await tokenizer.feed(chunk)) }
        _ = await assembler.apply(await tokenizer.finish())
        return await assembler.makeSnapshot()
    }

    private func text(_ block: BlockSnapshot) -> String {
        (block.inlineRuns ?? []).map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func links(_ block: BlockSnapshot) -> [String] {
        (block.inlineRuns ?? []).compactMap(\.linkURL)
    }

    @Test("Sources defined after the text that cites them are shown, and link what follows them")
    func sourcesAfterCitations() async {
        let blocks = await parse([Self.documents[0]])
        #expect(blocks.map(\.kind) == [.paragraph, .paragraph, .paragraph, .paragraph])
        #expect(blocks.map(text) == ["See [1] and [2].", "[1]: https://a.example", "[2]: https://b.example \"B\"", "Again 1."])
        // The citations keep their streamed text and link once their source
        // arrives; so does each source's own marker, beside its address.
        #expect(links(blocks[0]) == ["https://a.example", "https://b.example"])
        #expect(links(blocks[1]) == ["https://a.example", "https://a.example"])
        #expect(links(blocks[2]) == ["https://b.example", "https://b.example"])
        // A reference after its definition is a link, as usual.
        #expect(links(blocks[3]) == ["https://a.example"])
    }

    @Test("A definition before its use, or never used, stays hidden")
    func earlyAndUnusedDefinitionsStayHidden() async {
        let early = await parse([Self.documents[1]])
        #expect(early.map(text) == ["See 1."])
        #expect(early.flatMap(links) == ["https://a.example"])
        let unused = await parse([Self.documents[2]])
        #expect(unused.map(text) == ["Text."])
    }

    @Test("A late definition inside a list item is shown in the item")
    func lateDefinitionInItem() async {
        let blocks = await parse([Self.documents[3]])
        #expect(blocks.map(\.kind) == [.listItem(ordered: false, index: nil, task: nil), .paragraph])
        #expect(blocks[1].parentID == blocks[0].id)
        #expect(text(blocks[1]) == "[1]: https://a.example")
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
