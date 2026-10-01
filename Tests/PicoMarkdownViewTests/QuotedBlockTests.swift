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
        "> | a | b |\n\nOutside\n",
        "> $$x$$y\n\n",
        "> \\[x\\]y\n\n",
        "> > ```\n> code\n> > ```\n\n",
        "> ---\n\n",
        "> ***\n\n",
        "> ___\n\n",
        "> > ```swift\n> > code\n> > ```\n\n",
        ">> ```swift\n>> code\n>> ```\n\n",
        "> - - -\n\n",
        "> * * *\n\n",
        "> _ _ _\n\n",
        "> ---\n> after\n\n",
        "> # heading\n> before\n> * * *\n> after\n\n",
        "> $$x$$\n> y\n\n",
        "> \\[x\\]\n> y\n\n",
        "> [^a]: definition\n\n",
        "> [^a]:**definition**\n\n",
        "$$x$$y\n\n",
        "\\[x\\]y\n\n",
        "$$x$$\ny\n\n",
        "> [^a]: one\n> [^b]: two\n\n",
        "> [^a]: one\n> after\n\n",
        "> [^a]: one\n>     continued\n> after\n\n",
        "> - item\n>   > nested\n\n",
        "> - item\n>   > nested\n>   continued\n> - sibling\n\n",
        "> 1. item\n>    > nested\n\n",
        "> [ref]: /url\n> [ref]\n\n",
        "> # Heading\n> [ref]: /url \"title\"\n> [ref]\n\n",
        "> # heading\n> :::note\n\n",
        "> :::note\n> body\n> :::\n\n",
        "> [^a]: one\n> [ref]: /url\n> [ref]\n\n",
        "> ```\n> [ref]: /url\n> ```\n> [ref]\n\n",
        "> # h\n>     one\n>     two\n\n",
        "> # h\n> \tone\n> \ttwo\n\n",
        "> - item\n>   ```swift\n>   code\n>   ```\n> - sibling\n\n",
        "> 1. item\n>    ```swift\n>    code\n>    ```\n\n",
        "> - item\n>   | a | b |\n>   | --- | --- |\n>   | x | y |\n>\n> - sibling\n\n",
        "> - item\n>     ```swift\n>     code\n>     ```\n\n",
        "> - item\n> \t```swift\n> \tcode\n> \t```\n\n",
        "> - item\n>   # child\n\n",
        "> - item\n>   $$x$$\n\n",
        "> - item\n>   [^a]: definition\n\n",
        "> - item\n>   ---\n\n",
        "> - item\n>   :::note\n\n"
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

    @Test("Fresh review regressions retain math suffixes, close nested fences, and recognize rules")
    func freshReviewRegressions() async {
        let math = await parse(chunks: ["> $$x$$", "y\n\n"])
        #expect(math.blocks == (await parse(chunks: [Self.documents[17]])).blocks)
        #expect(math.blocks.flatMap { $0.inlineRuns ?? [] }.map(\.text).joined().contains("y"))
        let fence = await parse(chunks: [Self.documents[19]])
        let firstFence = fence.blocks.first { if case .fencedCode = $0.kind { return true }; return false }
        #expect(firstFence != nil)
        #expect((firstFence?.codeText ?? "") == "")
        #expect(fence.blocks.contains { $0.inlineRuns?.map(\.text).joined().contains("code") == true })
        for document in Array(Self.documents[20...22]) + Self.documents[25...27] {
            #expect(await parse(chunks: [document]).blocks.map(\.kind) == [.blockquote, .horizontalRule])
        }
        let afterRule = await parse(chunks: [Self.documents[28]])
        #expect(afterRule.blocks.map(\.kind) == [.blockquote, .horizontalRule, .paragraph])
        #expect(afterRule.blocks.last?.inlineRuns?.map(\.text).joined() == "after")
    }

    @Test("Long unresolved quote spaces remain local and preserve later text")
    func longQuotedPadding() async {
        for padding in [" ", "\t "] {
            for tail in ["\n\n", "text\n\n", "> literal\n\n", "text\n> after\n\n"] {
                let source = "> " + String(repeating: padding, count: 2048) + tail
                #expect(await parse(chunks: source.map(String.init)).blocks == (await parse(chunks: [source])).blocks)
            }
        }
    }

    @Test("Quoted same-line math closes before the next line and footnotes retain block metadata")
    func latestReviewRegressions() async {
        for document in Self.documents[30...31] {
            let result = await parse(chunks: [document])
            #expect(result.blocks.map(\.kind) == [.blockquote, .math(display: true), .paragraph])
            #expect(result.blocks.last?.inlineRuns?.map(\.text).joined() == "y")
        }
        for document in Self.documents[32...33] {
            let result = await parse(chunks: [document])
            #expect(result.blocks.map(\.kind) == [.blockquote, .footnoteDefinition(id: "a", index: 1)])
            let parentRuns = result.blocks.first?.inlineRuns ?? []
            #expect(parentRuns.isEmpty)
            #expect(result.blocks.last?.inlineRuns?.map(\.text).joined() == "definition")
        }
    }

    @Test("Alternating quoted padding is bounded and later feeds emit only their own deltas")
    func quotedPaddingUsesBoundedFallback() {
        var parser = StreamingParser(maxLookBehind: 32)
        _ = parser.feed("> ")
        var unknownStarts = 0
        for index in 0..<4096 {
            let result = parser.feed(index.isMultiple(of: 2) ? " " : "\t")
            #expect(parser.bufferedLineByteCount <= 64)
            unknownStarts += result.events.filter { if case .blockStart(_, .unknown) = $0 { return true }; return false }.count
        }
        #expect(unknownStarts == 1)
        let next = parser.feed("x")
        let text = next.events.flatMap { event -> [InlineRun] in
            if case .blockAppendInline(_, let runs) = event { return runs }; return []
        }.map(\.text).joined()
        #expect(text == "x")
        _ = parser.finish()
    }

    @Test("Deferred quoted candidates use bounded raw fallback")
    func quotedTableCandidateIsBounded() {
        for prefix in ["> |", "> [ref", "> :::", "> ```swift "] {
            var parser = StreamingParser(maxLookBehind: 32)
            _ = parser.feed(prefix)
            var unknownStarts = 0
            var peakBytes = 0
            for _ in 0..<4096 {
                let result = parser.feed("x")
                peakBytes = max(peakBytes, parser.bufferedLineByteCount)
                unknownStarts += result.events.filter { if case .blockStart(_, .unknown) = $0 { return true }; return false }.count
            }
            #expect(peakBytes <= 64)
            #expect(unknownStarts == 1)
            let next = parser.feed("y")
            #expect(next.events.contains { if case .blockAppendInline(_, let runs) = $0 { return runs.map(\.text).joined() == "y" }; return false })
            _ = parser.finish()
        }
    }

    @Test("Unquoted math suffixes, footnote boundaries, and list-owned quotes retain structure")
    func finalReviewRegressions() async throws {
        for opener in ["$$x$$", "\\[x\\]"] {
            let tokenizer = MarkdownTokenizer()
            let first = await tokenizer.feed(opener)
            #expect(first.events.isEmpty)
            #expect(first.openBlocks.isEmpty)
        }
        for document in Self.documents[34...35] {
            let result = await parse(chunks: [document])
            #expect(result.blocks.map(\.kind) == [.paragraph])
            #expect(result.blocks.last?.inlineRuns?.map(\.text).joined().contains("y") == true)
        }
        let nextLine = await parse(chunks: [Self.documents[36]])
        #expect(nextLine.blocks.map(\.kind) == [.math(display: true), .paragraph])
        #expect(nextLine.blocks.last?.inlineRuns?.map(\.text).joined() == "y")
        let footnotes = await parse(chunks: [Self.documents[37]])
        #expect(footnotes.blocks.map(\.kind) == [.blockquote, .footnoteDefinition(id: "a", index: 1), .footnoteDefinition(id: "b", index: 2)])
        #expect(footnotes.blocks.dropFirst().map { $0.inlineRuns?.map(\.text).joined() } == ["one", "two"])
        for document in Self.documents[38...39] {
            let result = await parse(chunks: [document])
            #expect(result.blocks.map(\.kind) == [.blockquote, .footnoteDefinition(id: "a", index: 1), .paragraph])
            #expect(result.blocks.last?.inlineRuns?.map(\.text).joined() == "after")
        }
        let continuation = await parse(chunks: [Self.documents[39]])
        let continuedText = continuation.blocks[1].inlineRuns?.map(\.text).joined()
        #expect(continuedText == "one continued")
        for document in Self.documents[40...42] {
            let result = await parse(chunks: [document])
            let item = try #require(result.blocks.first { if case .listItem = $0.kind { return true }; return false })
            let nested = try #require(result.blocks.last { $0.kind == .blockquote })
            #expect(nested.parentID == item.id)
        }
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

    @Test("Quoted reference definitions and extension fallbacks never leak provisional text")
    func referenceAndUnknownPrefixes() async {
        let reference = await parse(chunks: ["> [ref]", ": /url", "\n> [ref]\n\n"])
        let runs = reference.blocks.flatMap { $0.inlineRuns ?? [] }
        #expect(runs.map(\.text).joined() == "ref\n")
        #expect(runs.first?.linkURL == "/url")
        let unknown = await parse(chunks: Self.documents[45].map(String.init))
        #expect(unknown.blocks.map(\.kind) == [.blockquote, .heading(level: 1), .unknown])
        #expect(unknown.blocks.last?.inlineRuns?.map(\.text).joined() == ":::note\n")
    }

    @Test("Refreshing retained children preserves styling after their quote parent is evicted")
    func retainedQuoteChildrenKeepLevel() async throws {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler(config: .init(maxClosedBlocks: 3))
        let renderer = MarkdownRenderer { await assembler.block($0) }
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed("> # H\n> retained\n\n")))
        let original = await renderer.renderedBlocks()
        let parent = try #require(original.first)
        let children = original.dropFirst().map(\.id)
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed("outside\n\n")))
        #expect(!(await renderer.renderedBlocks()).contains { $0.id == parent.id })
        _ = await renderer.refreshBlocks(Set(children))
        for child in await renderer.renderedBlocks() where children.contains(child.id) {
            #expect(child.blockquoteLevel == 1)
            let content = NSAttributedString.picoConverted(from: child.content)
            #expect(content.attribute(.picoBlockquoteLevel, at: 0, effectiveRange: nil) as? Int == 1)
            let paragraph = try #require(content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            #expect(paragraph.firstLineHeadIndent >= BlockquoteBarMetrics.textIndent(level: 1))
        }
    }

    @Test("Quoted code retains definitions and resolves partial indentation")
    func quotedVerbatimRegressions() async throws {
        let fence = await parse(chunks: [Self.documents[48]])
        #expect(fence.blocks.first(where: { $0.codeText != nil })?.codeText == "[ref]: /url\n")
        #expect(!fence.blocks.flatMap { $0.inlineRuns ?? [] }.contains { $0.linkURL != nil })
        for document in Self.documents[49...50] {
            let code = await parse(chunks: [document])
            #expect(code.blocks.first(where: { $0.codeText != nil })?.codeText == "one\ntwo\n")
        }
    }

    @Test("Indented structured quote children retain their list parent")
    func quotedStructuredListChildren() async throws {
        for document in Self.documents[51...] {
            let result = await parse(chunks: [document])
            let item = try #require(result.blocks.first { if case .listItem = $0.kind { return true }; return false })
            let child = try #require(result.blocks.first { $0.parentID == item.id })
            #expect(child.parentID == item.id)
            #expect(child.depth == item.depth + 1)
            if let code = child.codeText { #expect(code == "code\n") }
            let builder = MarkdownAttributeBuilder(theme: .default())
            let rendered = await builder.render(snapshot: child, blockquoteLevel: 1)
            let content = NSAttributedString.picoConverted(from: rendered.attributed)
            let paragraph = try #require(content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            #expect(paragraph.firstLineHeadIndent >= BlockquoteBarMetrics.textIndent(level: 1) + 20)
        }
    }

    @Test("Attachment-only quoted math receives quote indentation")
    @MainActor
    func attachmentOnlyQuoteIndentation() async throws {
        let builder = MarkdownAttributeBuilder(theme: .default())
        let snapshot = BlockSnapshot(id: 1, kind: .math(display: true), mathText: "x^{2}", isClosed: true)
        let rendered = await builder.render(snapshot: snapshot, blockquoteLevel: 1)
        let content = NSAttributedString.picoConverted(from: rendered.attributed)
        #expect(content.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        let paragraph = try #require(content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let indent = BlockquoteBarMetrics.textIndent(level: 1)
        #expect(paragraph.firstLineHeadIndent >= indent)
        let storage = NSTextStorage(attributedString: content)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 320, height: 1000))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: 0, length: 1), actualCharacterRange: nil)
        #expect(layout.boundingRect(forGlyphRange: glyphs, in: container).minX >= indent)
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
