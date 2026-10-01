import Foundation
import Testing
@testable import PicoMarkdownView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite
struct QuotedBlockTests {
    static let documents = [
        "> ## Heading\n> - **first**\n> - second\n> ```swift\n> let x = 1\n>\n> > literal\n> ```\n> after\n\nOutside\n",
        ">> # Nested heading\n>> 1. item\n>> 2. another\n> # Outer heading\n> after\n\n",
        "> Before\n> ### Title\n> **after** [link](https://example.com)\n\n",
        "> - first\n>   - nested\n> - final\n>\n> paragraph\n\n",
        "> ~~~text\n> # literal\n> ~~~not a close\n> ~~~\n\n",
        "> ```swift\n> unfinished code",
        "```text\n> not a quote\n```\n",
        "[link](https://example.com) and ![image](image.png)\n\n",
        "> | **a** | b |\n> | --- | --- |\n> | one | two |\n\n",
        "> | not | a table |\n> no separator\n\n",
        "> - [x] task\n> - [ ] pending\n> 1. [X] ordered\n\n",
        "   > # H\n   > para\n\n",
        "> $$\n> x\n> $$\n\n",
        "> \\[\n> x\n> \\]\n\n",
        ">   ```swift\n>   let x = 1\n>  one\n> zero\n>    three\n>   ```\n\n",
        "> | a | b |",
        "> | a | b |\n\nOutside\n"
    ]

    @Test("Quoted review regressions preserve tables, task metadata, math, and fence indentation")
    func reviewRegressions() async throws {
        let table = await parse(chunks: [Self.documents[8]])
        #expect(table.blocks.map(\.kind) == [.blockquote, .table])
        #expect(table.blocks.dropFirst().first?.parentID == table.blocks.first?.id)
        #expect(table.events.contains { if case .tableAppendRow = $0 { return true }; return false })
        let fallback = await parse(chunks: [Self.documents[15]])
        #expect(fallback.blocks.map(\.kind) == [.blockquote, .unknown])
        #expect(fallback.blocks.last?.inlineRuns?.map(\.text).joined().contains("| a | b |") == true)

        let tasks = await parse(chunks: ["> - ", "[x] task\n\n"])
        #expect(tasks.blocks.map(\.kind) == [.blockquote, .listItem(ordered: false, index: nil, task: .init(checked: true))])

        let indented = await parse(chunks: ["   > # H\n ", "  > para\n\n"])
        #expect(indented.blocks.map(\.kind) == [.blockquote, .heading(level: 1), .paragraph])
        #expect(indented.blocks.last?.parentID == indented.blocks.first?.id)

        for opener in ["$$", "\\["] {
            let closer = opener == "$$" ? "$$" : "\\]"
            let math = await parse(chunks: ["> " + String(opener.prefix(1)), String(opener.suffix(1)) + "\n> x\n> " + closer + "\n\n"])
            #expect(math.blocks.map(\.kind) == [.blockquote, .math(display: true)])
            #expect((math.blocks.first?.inlineRuns?.map(\.text).joined() ?? "") == "")
        }

        let fence = await parse(chunks: [Self.documents[14]])
        #expect(fence.blocks.first(where: { $0.codeText != nil })?.codeText == "let x = 1\none\nzero\n three\n")
    }

    @Test("Quoted blocks are structured children with no leaked markers")
    func quotedBlocksHaveStructure() async throws {
        let result = await parse(chunks: [Self.documents[0]])
        #expect(result.blocks.map(\.kind) == [
            .blockquote, .heading(level: 2),
            .listItem(ordered: false, index: nil, task: nil),
            .listItem(ordered: false, index: nil, task: nil),
            .fencedCode(language: "swift"), .paragraph, .paragraph
        ])
        let quote = try #require(result.blocks.first)
        for child in result.blocks.dropFirst().dropLast() {
            #expect(child.parentID == quote.id)
            #expect(child.depth == 1)
        }
        #expect(result.blocks.last?.parentID == nil)
        #expect(result.blocks.first(where: { $0.codeText != nil })?.codeText == "let x = 1\n\n> literal\n")
        #expect(result.blocks[1].inlineRuns?.map(\.text).joined() == "Heading")
        #expect(result.blocks[2].inlineRuns?.contains(where: { $0.text == "first" && $0.style.contains(.bold) }) == true)
    }

    @Test("Quoted block parsing is equivalent at every chunk split", arguments: documents)
    func everyChunkSplit(markdown: String) async {
        let baseline = await parse(chunks: [markdown])
        let characters = Array(markdown)
        for split in 0...characters.count {
            let chunks = [String(characters[..<split]), String(characters[split...])]
            let streamed = await parse(chunks: chunks)
            #expect(streamed.blocks == baseline.blocks, "Split at character \(split)")
        }
        let oneCharacterChunks = characters.map(String.init)
        let streamed = await parse(chunks: oneCharacterChunks)
        #expect(streamed.blocks == baseline.blocks)
        let repeated = await parse(chunks: oneCharacterChunks)
        #expect(repeated.events == streamed.events)
    }

    @Test("Ambiguous quoted markers do not escape before resolution")
    func quotedMarkerGolden() async {
        let tokenizer = MarkdownTokenizer()
        let first = await tokenizer.feed("> #")
        #expect(first.events == [.blockStart(id: 1, kind: .blockquote)])
        let second = await tokenizer.feed("# Title\n> `")
        #expect(second.events.contains(.blockStart(id: 2, kind: .heading(level: 2))))
        #expect(!second.events.contains { event in
            if case .blockAppendInline(_, let runs) = event { return runs.contains { $0.text.contains("#") || $0.text.contains("`") } }
            return false
        })
        let third = await tokenizer.feed("``swift\n> value\n> `")
        #expect(third.events.contains(.blockStart(id: 3, kind: .fencedCode(language: "swift"))))
        #expect(third.events.contains(.blockAppendFencedCode(id: 3, textChunk: "value\n")))
        let fourth = await tokenizer.feed("``\n")
        #expect(fourth.events == [.blockEnd(id: 3)])
        let finished = await tokenizer.finish()
        #expect(finished.events == [.blockEnd(id: 1)])
        #expect(finished.openBlocks.isEmpty)
    }

    @Test("Quoted children inherit bars without losing heading or code styles")
    func quotedChildrenRenderWithBars() async throws {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { await assembler.block($0) }
        for character in Self.documents[0] {
            let diff = await assembler.apply(await tokenizer.feed(String(character)))
            _ = await renderer.apply(diff)
        }
        _ = await renderer.apply(await assembler.apply(await tokenizer.finish()))
        let blocks = await renderer.renderedBlocks()
        for child in blocks.dropFirst().dropLast() {
            let content = NSAttributedString.picoConverted(from: child.content)
            #expect(content.length > 0)
            #expect(content.attribute(.picoBlockquoteLevel, at: 0, effectiveRange: nil) as? Int == 1)
            let paragraph = try #require(content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            #expect(paragraph.firstLineHeadIndent >= BlockquoteBarMetrics.textIndent(level: 1))
        }
        let heading = try #require(blocks.first(where: { $0.kind == .heading(level: 2) }))
        let headingFont = try #require(NSAttributedString(heading.content).attribute(.font, at: 0, effectiveRange: nil) as? MarkdownFont)
        #expect(headingFont.pointSize > MarkdownRenderTheme.default().bodyFont.pointSize)
        #expect(blocks.first(where: { $0.codeBlock != nil })?.codeBlock?.code == "let x = 1\n\n> literal\n")
        let outside = try #require(blocks.last)
        #expect(NSAttributedString(outside.content).attribute(.picoBlockquoteLevel, at: 0, effectiveRange: nil) == nil)
    }

    private func parse(chunks: [String]) async -> (blocks: [BlockSnapshot], events: [BlockEvent]) {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        var events: [BlockEvent] = []
        var open: [BlockID] = []
        var started: Set<BlockID> = []
        for chunk in chunks {
            let result = await tokenizer.feed(chunk)
            check(result, open: &open, started: &started)
            events += result.events
            _ = await assembler.apply(result)
        }
        let final = await tokenizer.finish()
        check(final, open: &open, started: &started)
        events += final.events
        _ = await assembler.apply(final)
        #expect(open.isEmpty)
        var blocks = await assembler.makeSnapshot()
        for index in blocks.indices {
            if let runs = blocks[index].inlineRuns {
                var normalized: [InlineRun] = []
                for run in runs {
                    if let last = normalized.last, last.canCoalesce(with: run) {
                        normalized[normalized.count - 1].text += run.text
                    } else {
                        normalized.append(run)
                    }
                }
                blocks[index].inlineRuns = normalized
            }
            #expect(blocks[index].isClosed)
        }
        return (blocks, events)
    }

    private func check(_ result: ChunkResult, open: inout [BlockID], started: inout Set<BlockID>) {
        for event in result.events {
            switch event {
            case .blockStart(let id, _):
                #expect(started.insert(id).inserted)
                open.append(id)
            case .blockEnd(let id):
                #expect(open.last == id)
                _ = open.popLast()
            case .blockAppendInline(let id, _), .blockAppendFencedCode(let id, _), .blockAppendMath(let id, _),
                 .tableHeaderCandidate(let id, _), .tableHeaderConfirmed(let id, _), .tableAppendRow(let id, _):
                #expect(open.contains(id))
            }
        }
        #expect(result.openBlocks.map(\.id) == open)
    }
}
