import Foundation
import Testing
@testable import PicoMarkdownView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A reference such as `[1]` that streams before anything defines its label
/// goes out as text, tagged with the label. When a definition for it
/// arrives, the tagged runs link to it; their text never changes.
@Suite
struct LateReferenceLinkTests {
    static let citations = "See [1] and [2].\n\n[1]: https://a.example\n[2]: https://b.example\n"

    private struct Parsed {
        var blocks: [BlockSnapshot]
        var diffs: [AssemblerDiff]
        var lateDefinitions: [[String: String]]
    }

    private func parse(_ chunks: [String], config: AssemblerConfig = AssemblerConfig()) async -> Parsed {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler(config: config)
        var parsed = Parsed(blocks: [], diffs: [], lateDefinitions: [])
        for chunk in chunks {
            let result = await tokenizer.feed(chunk)
            parsed.lateDefinitions.append(result.lateLinkDefinitions)
            parsed.diffs.append(await assembler.apply(result))
        }
        let result = await tokenizer.finish()
        parsed.lateDefinitions.append(result.lateLinkDefinitions)
        parsed.diffs.append(await assembler.apply(result))
        parsed.blocks = await assembler.makeSnapshot()
        return parsed
    }

    private func runs(_ markdown: String) async -> [InlineRun] {
        (await parse([markdown])).blocks.first?.inlineRuns ?? []
    }

    @Test("An undefined reference with a plain label is one run, tagged with its label, with its brackets")
    func undefinedReferenceIsTagged() async {
        let parsed = await runs("See [1] and [Smith 2020], [x].\n\n")
        #expect(parsed.map(\.text) == ["See ", "[1]", " and ", "[Smith 2020]", ", ", "[x]", "."])
        #expect(parsed.map(\.referenceLabel) == [nil, "1", nil, "smith 2020", nil, "x", nil])
        #expect(parsed.allSatisfy { $0.linkURL == nil })
    }

    @Test("Markup in a label, a link around it, or a known definition leaves it untagged")
    func untaggedReferences() async {
        let emphasis = await runs("See [*a*] now.\n\n")
        #expect(emphasis.allSatisfy { $0.referenceLabel == nil })
        #expect(emphasis.contains { $0.text == "a" && $0.style.contains(.italic) })
        let linked = await runs("[see [1] here](https://x.example)\n\n")
        #expect(linked.allSatisfy { $0.referenceLabel == nil && $0.linkURL == "https://x.example" })
        let known = await parse(["[1]: https://a.example\n\nSee [1].\n"])
        #expect(known.blocks.flatMap { $0.inlineRuns ?? [] }.allSatisfy { $0.referenceLabel == nil })
        #expect(known.lateDefinitions.allSatisfy { $0.isEmpty }, "a definition before its use is not late")
    }

    @Test("Late definitions are reported once, and link the tagged runs, whose text stays as it streamed")
    func lateDefinitionLinksTaggedRuns() async {
        let parsed = await parse([Self.citations])
        #expect(parsed.lateDefinitions.reduce(into: [:]) { $0.merge($1) { first, _ in first } }
                == ["1": "https://a.example", "2": "https://b.example"])
        #expect(parsed.lateDefinitions.map(\.count).reduce(0, +) == 2)
        let citing = parsed.blocks[0]
        #expect((citing.inlineRuns ?? []).map(\.text).joined() == "See [1] and [2].")
        let linked = (citing.inlineRuns ?? []).filter { $0.linkURL != nil }
        #expect(linked.map(\.text) == ["[1]", "[2]"])
        #expect(linked.map(\.linkURL) == ["https://a.example", "https://b.example"])
        #expect(linked.allSatisfy { $0.style.contains(.link) })
        #expect(parsed.diffs.flatMap(\.relinkedBlocks).contains(citing.id))
    }

    @Test("A reference stays plain text until its definition arrives")
    func linkArrivesWithDefinition() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        _ = await assembler.apply(await tokenizer.feed("See [1].\n\n"))
        let before = await assembler.makeSnapshot()
        #expect(before.flatMap { $0.inlineRuns ?? [] }.allSatisfy { $0.linkURL == nil })
        let diff = await assembler.apply(await tokenizer.feed("[1]: https://a.example\n\nmore\n"))
        let after = await assembler.makeSnapshot()
        // The citing paragraph, and the source line shown for it, whose own
        // `[1]` was tagged too.
        #expect(diff.relinkedBlocks == [after[0].id, after[1].id])
        #expect(after[0].inlineRuns?.first { $0.text == "[1]" }?.linkURL == "https://a.example")
    }

    @Test("An evicted block is neither relinked nor reported")
    func evictedBlockIsPruned() async {
        let parsed = await parse(["See [1].\n\nfiller one\n\nfiller two\n\n[1]: https://a.example\n"],
                                 config: AssemblerConfig(maxClosedBlocks: 1))
        let ids = Set(parsed.blocks.map(\.id))
        #expect(parsed.diffs.flatMap(\.relinkedBlocks).allSatisfy(ids.contains))
    }

    @Test("Each document links the same at every chunk split")
    func everyChunkSplit() async {
        for markdown in [Self.citations, "- See [1].\n\n  [1]: https://a.example\n", "See [1] and [sic].\n\n"] {
            let baseline = await parse([markdown]).blocks
            let characters = Array(markdown)
            for split in 0...characters.count {
                let streamed = await parse([String(characters[..<split]), String(characters[split...])]).blocks
                #expect(streamed == baseline, Comment(rawValue: markdown.debugDescription + " split at \(split)"))
            }
            #expect(await parse(characters.map(String.init)).blocks == baseline, Comment(rawValue: markdown.debugDescription))
        }
    }

    @Test("The renderer and the views' diff pick up a relinked block, its text unchanged")
    func rendererAndPipelineRefreshRelinkedBlock() async throws {
        let pipeline = MarkdownStreamingPipeline()
        let first = await pipeline.feed("See [1].\n\n")
        let citingID = try #require(first?.blocks.first?.id)
        let textBefore = try #require(first?.blocks.first.map { String($0.content.characters) })
        let update = try #require(await pipeline.feed("[1]: https://a.example\n\nmore\n"))
        #expect(update.diff.changes.contains(.blockEnded(id: citingID)), "the views refresh the relinked block")
        let citing = try #require(update.blocks.first { $0.id == citingID })
        #expect(String(citing.content.characters) == textBefore)
        let content = NSAttributedString.picoConverted(from: citing.content)
        let marker = (content.string as NSString).range(of: "[1]")
        #expect(marker.location != NSNotFound)
        #expect(content.attribute(.link, at: marker.location, effectiveRange: nil) != nil)
    }
}
