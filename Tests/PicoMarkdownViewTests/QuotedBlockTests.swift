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
        "> - item\n>   :::note\n\n",
        "> ````\n> code\n> `````\n> after\n\n",
        "> ~~~~\n> code\n> ~~~~~~\n> after\n\n",
        ">  # Title\n\n",
        ">   # Title\n\n",
        ">    # Title\n\n",
        "> # h\n>     # literal\n\n",
        "> text\n***\nafter\n\n",
        "> text\n---\nafter\n\n",
        "> text\n___\nafter\n\n",
        "> text\n* * *\nafter\n\n",
        "> ````\n> code\n> ```\n> ````tail\n> ~~~~~\n> `````\n> after\n\n",
        "> # h\n[^b]: x\n\n",
        "> text\n[^b]: x\n\n",
        "> # h\n[ref]: /url\n[ref] text\n\n",
        "> text\n$$\nx\n$$\nafter\n\n",
        "> text\n\\[\nx\n\\]\nafter\n\n",
        "> text\n$$x$$\nafter\n\n",
        "> text\n$$x$$y\n\n",
        "> - item\n>   ```\n> outside\n>   ```\n\n",
        "> - item\n>   ```\n>  outside\n>   ```\n\n",
        "> ```\n> code\n>     ```\n> after\n> ```\n\n",
        "> ~~~\n> code\n>     ~~~\n> after\n> ~~~\n\n",
        "> ```\n> code\n> \t```\n> after\n> ```\n\n",
        "> ```\n> code\n>    ```\n> after\n\n",
        "> - item\n>   ```\n>       ```\n>   after\n>   ```\n\n",
        "> 1. item\n>    ```\n>   outside\n>    ```\n\n",
        "> - item\n>   ```\n> \tcode\n> \t```\n\n",
        ">     code\n>     more\n\n",
        "> \tcode\n> \tmore\n\n",
        ">     code",
        "> paragraph\n>     continuation\n\n",
        "> - item\n>   ```\n>   code\n>   ```\n>   after\n>   more\n\n",
        "> - item\n>   # heading\n>   after\n\n",
        "> - item\n>   $$x$$\n>   after\n\n",
        "> - item\n>   | a | b |\n>   | --- | --- |\n>   | x | y |\n>\n>   after\n\n",
        "> :::note\n> [ref]: /url\n> :::\n\n[ref] after\n",
        "> > inner\n> outer\n\n",
        ">>> foo\n> bar\n>>baz\n\n",
        "> > inner\n>\n> outer\n\n",
        "> - item\n>   ```\n>   code\n>   ```\n> after\n\n",
        "> - item\n>   ```\n>   first\n>   ```\n>   after\n>   ```\n>   second\n>   ```\n\n",
        "> - item\n>   ```\n>   code\n>   ```\n>   after\n> - sibling\n\n",
        "> 1. item\n>    ```\n>    code\n>    ```\n>    after\n> 2. sibling\n\n",
        "> - item\n>   ```\n>   code\n>   ```\n>   after\n>   - nested\n\n",
        "> - item\n>   ---\n>   after\n\n",
        "> - item\n>   | a | b |\n>   | --- | --- |\n> - sibling\n\n",
        "> 1. item\n>    | a | b |\n>    | --- | --- |\n> 2. sibling\n\n",
        "> - item\n>   | a | b |\n>   | --- | --- |\n>   | x | y |\n> - sibling\n\n",
        "> > text\n> [^b]: y\n\n",
        "> > text\n> | a | b |\n> | --- | --- |\n\n",
        "> > text\n> $$x$$\n\n",
        "> > text\n> ---\n\n",
        "> > text\n> :::note\n\n",
        "> - item\n>   ```\n>   code\n>   ```\n>   after\n>   ---\n>   more\n\n",
        "> - item\n>   ```\n>   code\n>   ```\n>   after\n> ---\n> more\n\n",
        "    ---\n\n",
        ">     ---\n\n",
        "   ---\n\n",
        ">    ---\n\n",
        "> \t---\n\n",
        "| a | b |\n| --- | --- |\n# Heading\n\n",
        "> | a | b |\n> | --- | --- |\n> # Heading\n\n",
        "> | a | b |\n> | --- | --- |\n> - item\n\n",
        "> | a | b |\n> | --- | --- |\n> ```\n> code\n> ```\n\n",
        "> | a | b |\n> | --- | --- |\n> ---\n\n",
        "> | a | b |\n> | --- | --- |\n> $$x$$\n\n",
        "> | a | b |\n> | --- | --- |\n> [^b]: y\n\n",
        "> | a | b |\n> | --- | --- |\n> plain row\n\n",
        "> paragraph\n> 2. continuation\n\n",
        "> paragraph\n> 1. item\n\n",
        "> # heading\n> paragraph\n> 2. continuation\n\n",
        "> 2. item\n\n",
        "> > paragraph\n> 2. continuation\n\n"
    ] + successorDocuments.map(\.source) + emptyMarkerDocuments + emptyHeadingDocuments.map(\.source)
      + contentIndentDocuments.map(\.source) + tabFenceDocuments
      + ["> - \n\n", "> 1.\n\n", "> paragraph\n> - [ ] \n\n"]
      + markerPaddingDocuments.map(\.source) + mixedIndentDocuments.map(\.source)
      + markerPaddingControls + ["> -     item.\n>   # heading\n\n"]

    private static let markerPaddingControls: [String] = (1...4).flatMap { padding in
        ["> -\(String(repeating: " ", count: padding))[x] item\n> \(String(repeating: " ", count: padding + 1))# heading\n\n",
         "> 1.\(String(repeating: " ", count: padding))\n>    # heading\n\n"]
    }

    private static let markerPaddingDocuments: [(source: String, owned: Bool)] = ["-", "1.", "10."].flatMap { marker in
        (1...4).flatMap { padding in
            [marker.count, marker.count + padding].map { indent in
                ("> \(marker)\(String(repeating: " ", count: padding))item\n> \(String(repeating: " ", count: indent))# heading\n\n", indent == marker.count + padding)
            }
        }
    }

    private static let mixedIndentDocuments: [(source: String, code: String)] = ["\t", "  ", "    "].flatMap { opening in
        ["  ", "\t", "    ", "      "].map { continuation in
            let openingColumns = opening == "\t" ? 4 : opening.count
            let continuationColumns = continuation == "\t" ? 4 : continuation.count
            return ("> - item\n> \(opening)```\n> \(continuation)code\n>   ```\n\n",
                String(repeating: " ", count: max(0, continuationColumns - openingColumns)) + "code\n")
        }
    }

    private static let emptyMarkerDocuments: [String] = ["> paragraph\n> ", "> # heading\n> paragraph\n> ", "> > paragraph\n> "].flatMap { prefix in
        ["- ", "* ", "+ ", "1.", "1. ", "2. ", "1.  \t"].map { prefix + $0 + "\n\n" }
    }

    private static let emptyHeadingDocuments: [(source: String, level: Int)] = (1...6).flatMap { level in
        ["> ", "> paragraph\n> "].flatMap { prefix in
            ["", "   "].flatMap { indent in
                ["\n\n", ""].map { (prefix + indent + String(repeating: "#", count: level) + $0, level) }
            }
        }
    }

    private static let contentIndentDocuments: [(source: String, kind: BlockKind, owned: Bool)] = ["1.", "10.", "123."].flatMap { marker in
        [2, marker.count + 1].flatMap { indent in
            let padding = String(repeating: " ", count: indent)
            let children: [(String, BlockKind)] = [("# heading", .heading(level: 1)), ("[^x]: def", .footnoteDefinition(id: "x", index: 1)), ("```\ncode\n```", .fencedCode(language: nil)), ("| a |\n| --- |", .table)]
            return children.flatMap { child, kind in
                let initial = "> \(marker) item\n"
                let fullPadding = String(repeating: " ", count: marker.count + 1)
                let successor = initial + "> \(fullPadding)```\n> \(fullPadding)first\n> \(fullPadding)```\n> \(fullPadding)after\n"
                let tail = child.components(separatedBy: "\n").map { "> \(padding)\($0)\n" }.joined() + "\n"
                return [initial, successor].map { ($0 + tail, kind, indent == marker.count + 1) }
            }
        }
    }

    private static let tabFenceDocuments = ["\t", " \t", "\t\t"].map { "> " + $0 + "```swift\n> \tcode\n> after\n\n" } + ["\t```swift\n\tcode\nafter\n\n"]

    private static let successorDocuments: [(source: String, kind: BlockKind, owned: Bool)] = {
        var cases: [(source: String, kind: BlockKind, owned: Bool)] = []
        let children = ["```\ncode\n```", "# heading", "$$x$$", "| a |\n| --- |\n| x |\n"]
        for (marker, indent) in [("-", "  "), ("1.", "   "), ("-", "\t")] {
            for child in children {
                let prefix = "> \(marker) item\n" + child.components(separatedBy: "\n").map { "> \(indent)\($0)\n" }.joined() + "> \(indent)after\n"
                cases.append((prefix + "> \(indent)> nested\n\n", .blockquote, true))
                cases.append((prefix + "> \(indent)[^x]: def\n\n", .footnoteDefinition(id: "x", index: 1), true))
            }
        }
        let prefix = "> - item\n>   ```\n>   code\n>   ```\n>   after\n"
        cases.append((prefix + "> > nested\n\n", .blockquote, false))
        cases.append((prefix + "> [^x]: def\n\n", .footnoteDefinition(id: "x", index: 1), false))
        return cases
    }()

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
        for prefix in ["> |", "> [ref", "> :::", "> ```swift ", "> # h\n[ref", "> # h\n[^"] {
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
        for document in Self.documents[51...60] {
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

    @Test("Quoted fence closers, heading indentation, and unmarked rules retain boundaries")
    func quotedContainerBoundaries() async throws {
        for document in Self.documents[61...62] {
            let result = await parse(chunks: [document])
            #expect(result.blocks.map(\.kind) == [.blockquote, .fencedCode(language: nil), .paragraph])
            #expect(result.blocks[1].codeText == "code\n")
            #expect(result.blocks.last?.inlineRuns?.map(\.text).joined() == "after")
        }
        for document in Self.documents[63...65] {
            let result = await parse(chunks: [document])
            #expect(result.blocks.map(\.kind) == [.blockquote, .heading(level: 1)])
            #expect(result.blocks.last?.inlineRuns?.map(\.text).joined() == "Title")
        }
        let code = await parse(chunks: [Self.documents[66]])
        #expect(code.blocks.last?.codeText == "# literal\n")
        for document in Self.documents[67...70] {
            let result = await parse(chunks: [document])
            #expect(result.blocks.map(\.kind) == [.blockquote, .horizontalRule, .paragraph])
            #expect(result.blocks.dropFirst().allSatisfy { $0.parentID == nil })
        }
        let invalidClosers = await parse(chunks: [Self.documents[71]])
        #expect(invalidClosers.blocks[1].codeText == "code\n```\n````tail\n~~~~~\n")
        #expect(invalidClosers.blocks.last?.inlineRuns?.map(\.text).joined() == "after")
    }

    @Test("Unmarked definitions and display math terminate quotes consistently")
    func unmarkedQuoteInterrupts() async throws {
        for document in Self.documents[72...73] {
            let result = await parse(chunks: document.map(String.init))
            let definition = try #require(result.blocks.last)
            #expect(definition.kind == .footnoteDefinition(id: "b", index: 1))
            #expect(definition.parentID == nil)
            #expect(definition.inlineRuns?.map(\.text).joined() == "x")
        }
        let reference = await parse(chunks: Self.documents[74].map(String.init))
        #expect(reference.blocks.last?.inlineRuns?.contains { $0.linkURL == "/url" } == true)
        for document in Self.documents[75...77] {
            let result = await parse(chunks: document.map(String.init))
            #expect(result.blocks.map(\.kind) == [.blockquote, .math(display: true), .paragraph])
            #expect(result.blocks.dropFirst().allSatisfy { $0.parentID == nil })
            #expect(result.blocks[1].mathText?.trimmingCharacters(in: .whitespacesAndNewlines) == "x")
            #expect(result.blocks.last?.inlineRuns?.map(\.text).joined() == "after")
        }
        let suffix = await parse(chunks: Self.documents[78].map(String.init))
        #expect(!suffix.blocks.contains { $0.kind == .math(display: true) })
        #expect(suffix.blocks.flatMap { $0.inlineRuns ?? [] }.map(\.text).joined().contains("y"))
    }

    @Test("Quoted fence indentation cannot consume outside list content or over-indented closers")
    func quotedFenceIndentationBoundaries() async throws {
        for document in Self.documents[79...80] {
            let result = await parse(chunks: document.map(String.init))
            #expect(result.blocks.contains { $0.kind == .paragraph && $0.inlineRuns?.map(\.text).joined().trimmingCharacters(in: .whitespaces) == "outside" })
            #expect(!result.blocks.contains { $0.codeText?.contains("outside") == true })
        }
        for document in Self.documents[81...83] {
            let result = await parse(chunks: document.map(String.init))
            let code = try #require(result.blocks.first { $0.codeText != nil }).codeText ?? ""
            #expect(code.contains("after\n"))
            #expect(code.contains(document == Self.documents[82] ? "~~~" : "```"))
            #expect(!result.blocks.contains { $0.kind == .paragraph })
        }
        let validCloser = await parse(chunks: Self.documents[84].map(String.init))
        #expect(validCloser.blocks.map(\.kind) == [.blockquote, .fencedCode(language: nil), .paragraph])
        #expect(validCloser.blocks[1].codeText == "code\n")
        let list = await parse(chunks: Self.documents[85].map(String.init))
        #expect(list.blocks.first { $0.codeText != nil }?.codeText == "    ```\nafter\n")
        let ordered = await parse(chunks: Self.documents[86].map(String.init))
        #expect(!ordered.blocks.contains { $0.codeText?.contains("outside") == true })
        let tab = await parse(chunks: Self.documents[87].map(String.init))
        #expect(tab.blocks.first { $0.codeText != nil }?.codeText == "  code\n")
    }

    @Test("Initial quoted code and post-child list text retain literal content and order")
    func quotedLiteralAndListOrder() async throws {
        for document in Self.documents[88...90] {
            let result = await parse(chunks: document.map(String.init))
            #expect(result.blocks.map(\.kind) == [.blockquote, .fencedCode(language: nil)])
            let code = try #require(result.blocks.first { $0.codeText != nil })
            #expect(code.codeText == (document == Self.documents[90] ? "code" : "code\nmore\n"))
        }
        let continuation = await parse(chunks: Self.documents[91].map(String.init))
        #expect(continuation.blocks.map(\.kind) == [.blockquote])
        for document in Self.documents[92...95] {
            let result = await parse(chunks: document.map(String.init))
            let item = try #require(result.blocks.first { if case .listItem = $0.kind { return true }; return false })
            let last = try #require(result.blocks.last)
            #expect(item.inlineRuns?.map(\.text).joined() == "item\n")
            #expect(last.kind == .paragraph)
            #expect(last.parentID == item.id)
            #expect(last.inlineRuns?.map(\.text).joined().hasPrefix("after") == true)
        }
        let literal = await parse(chunks: Self.documents[96].map(String.init))
        #expect(literal.blocks.first { $0.kind == .unknown }?.inlineRuns?.map(\.text).joined() == ":::note\n[ref]: /url\n:::\n")
        #expect(!literal.blocks.flatMap { $0.inlineRuns ?? [] }.contains { $0.linkURL != nil })
        let outside = await parse(chunks: Self.documents[100].map(String.init))
        #expect(outside.blocks.last?.kind == .paragraph)
        #expect(outside.blocks.last?.parentID == outside.blocks.first?.id)
        #expect(outside.blocks.last?.inlineRuns?.map(\.text).joined() == "after")
        let transition = await parse(chunks: Self.documents[101].map(String.init))
        #expect(transition.blocks.compactMap(\.codeText) == ["first\n", "second\n"])
    }

    @Test("Reduced quote markers preserve CommonMark lazy paragraph continuation")
    func nestedQuoteLazyContinuation() async throws {
        // CommonMark 0.31.2 examples 250-251 permit omitted inner markers.
        for document in Self.documents[97...98] {
            let result = await parse(chunks: document.map(String.init))
            let deepest = try #require(result.blocks.last)
            #expect(deepest.depth == (document == Self.documents[97] ? 1 : 2))
            #expect(deepest.inlineRuns?.map(\.text).joined() == (document == Self.documents[97] ? "inner\nouter\n" : "foo\nbar\nbaz\n"))
            let builder = MarkdownAttributeBuilder(theme: .default())
            let rendered = await builder.render(snapshot: deepest, blockquoteLevel: deepest.depth + 1)
            #expect(NSAttributedString.picoConverted(from: rendered.attributed).attribute(.picoBlockquoteLevel, at: 0, effectiveRange: nil) as? Int == deepest.depth + 1)
        }
        let separated = await parse(chunks: Self.documents[99].map(String.init))
        #expect(separated.blocks.last?.depth == 0)
        #expect(separated.blocks.last?.inlineRuns?.map(\.text).joined() == "outer\n")
    }

    @Test("Quoted list successors retain sibling ownership and rule/table boundaries")
    func quotedListSuccessors() async throws {
        for document in Self.documents[102...103] + Self.documents[106...108] {
            let result = await parse(chunks: document.map(String.init))
            let items = result.blocks.filter { if case .listItem = $0.kind { return true }; return false }
            #expect(items.count == 2)
            #expect(items.allSatisfy { $0.parentID == result.blocks.first?.id && $0.depth == 1 })
            #expect(items.last?.inlineRuns?.map(\.text).joined() == "sibling\n")
            #expect(!result.blocks.compactMap(\.table).flatMap(\.rows).flatMap { $0 }.flatMap { $0 }.contains { $0.text.contains("sibling") })
        }
        let nested = await parse(chunks: Self.documents[104].map(String.init))
        let items = nested.blocks.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 2)
        #expect(items.last?.parentID == items.first?.id)
        let rule = await parse(chunks: Self.documents[105].map(String.init))
        #expect(rule.blocks.map(\.kind) == [.blockquote, .listItem(ordered: false, index: nil, task: nil), .horizontalRule, .paragraph])
        #expect(rule.blocks.last?.parentID == rule.blocks[1].id)
        #expect(rule.blocks[1].inlineRuns?.map(\.text).joined() == "item\n")
        #expect(rule.blocks.last?.inlineRuns?.map(\.text).joined() == "after")
    }

    @Test("List-owned nested quotes include the list indentation")
    func nestedQuoteListIndentation() async throws {
        let builder = MarkdownAttributeBuilder(theme: .default())
        let documents = [(source: Self.documents[40], owned: true)] + Self.successorDocuments.filter { $0.kind == .blockquote }.map { (source: $0.source, owned: $0.owned) }
        for fixture in documents {
            let result = await parse(chunks: [fixture.source])
            let nested = try #require(result.blocks.last)
            let rendered = await builder.render(snapshot: nested, blockquoteLevel: 2)
            let content = NSAttributedString.picoConverted(from: rendered.attributed)
            let paragraph = try #require(content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            #expect(paragraph.firstLineHeadIndent == BlockquoteBarMetrics.textIndent(level: 2) + (fixture.owned ? 20 : 0))
            #expect(paragraph.headIndent == paragraph.firstLineHeadIndent)
        }
    }

    @Test("Reduced quote markers end nested containers before non-lazy blocks")
    func reducedQuoteBlockBoundaries() async throws {
        for document in Self.documents[109...113] {
            let result = await parse(chunks: document.map(String.init))
            #expect(result.blocks.last?.parentID == result.blocks.first?.id)
            #expect(result.blocks.last?.depth == 1)
            #expect(result.blocks[1].inlineRuns?.map(\.text).joined() == "text\n")
        }
        let child = await parse(chunks: Self.documents[114].map(String.init))
        #expect(child.blocks.suffix(2).map(\.kind) == [.horizontalRule, .paragraph])
        #expect(child.blocks.suffix(2).allSatisfy { $0.parentID == child.blocks[1].id })
        let outer = await parse(chunks: Self.documents[115].map(String.init))
        #expect(outer.blocks.suffix(2).allSatisfy { $0.parentID == outer.blocks.first?.id })
    }

    @Test("Bounded ambiguous list children preserve their eligible owner")
    func boundedListChildOwnership() async throws {
        for prefix in ["> - item\n>   ", "> 1. item\n>    ",
                       "> - item\n>   ```\n>   code\n>   ```\n>   after\n>   "] {
            for opener in ["[ref", "|"] {
                let document = prefix + opener + String(repeating: "x", count: 80) + "\n\n"
                let baseline = await parse(chunks: [document], maxLookBehind: 32)
                let item = try #require(baseline.blocks.first { if case .listItem = $0.kind { return true }; return false })
                let fallback = try #require(baseline.blocks.last)
                #expect(fallback.kind == .unknown && fallback.parentID == item.id)
                #expect(fallback.inlineRuns?.map(\.text).joined() == opener + String(repeating: "x", count: 80) + "\n")
                let characters = Array(document)
                for split in 0...characters.count {
                    let streamed = await parse(chunks: [String(characters[..<split]), String(characters[split...])], maxLookBehind: 32)
                    #expect(streamed.blocks == baseline.blocks)
                }
                let first = await parse(chunks: characters.map(String.init), maxLookBehind: 32)
                let repeated = await parse(chunks: characters.map(String.init), maxLookBehind: 32)
                #expect(first.blocks == baseline.blocks)
                #expect(first.events == repeated.events)
                var parser = StreamingParser(maxLookBehind: 32)
                for character in document {
                    _ = parser.feed(String(character))
                    #expect(parser.bufferedLineByteCount <= 64)
                }
            }
        }
    }

    @Test("Thematic indentation, table block boundaries, and ordered interruption follow GFM")
    func gfmBlockBoundaries() async throws {
        for index in [116, 117, 120] {
            let result = await parse(chunks: Self.documents[index].map(String.init))
            #expect(result.blocks.last?.kind == .fencedCode(language: nil))
            #expect(result.blocks.last?.codeText == (index == 116 ? "---\n\n" : "---\n"))
        }
        for index in [118, 119] {
            #expect(await parse(chunks: Self.documents[index].map(String.init)).blocks.last?.kind == .horizontalRule)
        }
        for document in Self.documents[121...127] {
            let result = await parse(chunks: document.map(String.init))
            let table = try #require(result.blocks.first { $0.kind == .table })
            #expect(table.table?.rows.isEmpty == true)
            #expect(result.blocks.last?.kind != .table)
            #expect(result.blocks.last?.parentID == table.parentID)
        }
        let row = await parse(chunks: Self.documents[128].map(String.init))
        #expect(row.blocks.last?.table?.rows.first?.first?.map(\.text).joined() == "plain row")
        for index in [129, 131, 133] {
            let result = await parse(chunks: Self.documents[index].map(String.init))
            #expect(!result.blocks.contains { if case .listItem = $0.kind { return true }; return false })
            #expect(result.blocks.last?.inlineRuns?.map(\.text).joined().contains("2. continuation") == true)
        }
        for index in [130, 132] {
            #expect(await parse(chunks: Self.documents[index].map(String.init)).blocks.last?.kind == .listItem(ordered: true, index: index == 132 ? 2 : 1, task: nil))
        }
    }

    @Test("Nested quote and footnote successors preserve only eligible list owners")
    func structuredSuccessorOwnership() async throws {
        for fixture in Self.successorDocuments {
            let result = await parse(chunks: fixture.source.map(String.init))
            let list = try #require(result.blocks.first { if case .listItem = $0.kind { return true }; return false })
            let successor = try #require(result.blocks.last)
            #expect(successor.kind == fixture.kind)
            #expect(successor.parentID == (fixture.owned ? list.id : result.blocks.first?.id))
            #expect(successor.depth == (fixture.owned ? list.depth + 1 : 1))
            #expect(result.blocks.contains { $0.kind == .paragraph && $0.inlineRuns?.map(\.text).joined() == "after" && $0.parentID == list.id })
            #expect(successor.inlineRuns?.map(\.text).joined() == (fixture.kind == .blockquote ? "nested\n" : "def"))
        }
    }

    @Test("Empty list markers stay paragraph text while marker-only headings resolve at newline or EOF")
    func emptyMarkerBoundaries() async throws {
        for source in Self.emptyMarkerDocuments {
            let result = await parse(chunks: source.map(String.init))
            #expect(!result.blocks.contains { if case .listItem = $0.kind { return true }; return false })
            #expect(result.blocks.last?.inlineRuns?.map(\.text).joined().contains("paragraph") == true)
        }
        for fixture in Self.emptyHeadingDocuments {
            let result = await parse(chunks: fixture.source.map(String.init))
            let heading = try #require(result.blocks.last)
            #expect(heading.kind == .heading(level: fixture.level))
            #expect((heading.inlineRuns ?? []).isEmpty)
        }
        for source in ["> - \n\n", "> 1.\n\n"] {
            #expect(await parse(chunks: source.map(String.init)).blocks.contains { if case .listItem = $0.kind { return true }; return false })
        }
        #expect(await parse(chunks: "> paragraph\n> - [ ] \n\n".map(String.init)).blocks.last?.kind == .listItem(ordered: false, index: nil, task: .init(checked: false)))
    }

    @Test("Quoted structured children require their ordered marker's full content indent")
    func completeOrderedContentIndent() async throws {
        for fixture in Self.contentIndentDocuments {
            let result = await parse(chunks: fixture.source.map(String.init))
            let item = try #require(result.blocks.first { if case .listItem = $0.kind { return true }; return false })
            let child = try #require(result.blocks.last)
            #expect(child.kind == fixture.kind)
            #expect(child.parentID == (fixture.owned ? item.id : result.blocks.first?.id))
        }
    }

    @Test("Tab-indented fence markers stay indented code without swallowing the following paragraph")
    func tabIndentedFenceOpeners() async throws {
        for source in Self.tabFenceDocuments {
            let result = await parse(chunks: source.map(String.init))
            let code = try #require(result.blocks.first { $0.codeText != nil })
            #expect(code.kind == .fencedCode(language: nil))
            #expect(code.codeText?.contains("```swift") == true)
            #expect(result.blocks.last?.inlineRuns?.map(\.text).joined() == "after")
        }
    }

    @Test("Quoted list content columns include all one-to-four-space marker padding")
    func completeMarkerPadding() async throws {
        for fixture in Self.markerPaddingDocuments {
            let result = await parse(chunks: fixture.source.map(String.init))
            let item = try #require(result.blocks.first { if case .listItem = $0.kind { return true }; return false })
            let heading = try #require(result.blocks.last)
            #expect(heading.kind == .heading(level: 1))
            #expect(heading.parentID == (fixture.owned ? item.id : result.blocks.first?.id))
            #expect(item.inlineRuns?.map(\.text).joined() == "item\n")
        }
        for source in Self.markerPaddingControls {
            let result = await parse(chunks: source.map(String.init))
            let item = try #require(result.blocks.first { if case .listItem = $0.kind { return true }; return false })
            #expect(result.blocks.last?.parentID == item.id)
            if source.contains("[x]") {
                #expect(item.kind == .listItem(ordered: false, index: nil, task: .init(checked: true)))
                #expect(item.inlineRuns?.map(\.text).joined() == "item\n")
            }
        }
        let overPadding = await parse(chunks: "> -     item.\n>   # heading\n\n".map(String.init))
        #expect(overPadding.blocks.last?.parentID == overPadding.blocks.first { if case .listItem = $0.kind { return true }; return false }?.id)
    }

    @Test("Quoted list-owned fences strip each line's content columns rather than the opener's character count")
    func mixedListContentIndent() async throws {
        for fixture in Self.mixedIndentDocuments {
            let result = await parse(chunks: fixture.source.map(String.init))
            #expect(result.blocks.first { $0.codeText != nil }?.codeText == fixture.code)
        }
    }

    @Test("Incomplete unquoted display math closing lines remain pending")
    func unquotedMathCloserSuffix() async throws {
        for (opening, closing) in [("$$", "$$"), ("\\[", "\\]")] {
            let source = "\(opening)\nx\n\(closing)not a closer\nafter\n\n"
            let single = await parse(chunks: [source])
            #expect(single.blocks.count == 1)
            #expect(single.blocks.first?.mathText == "x\n\(closing)not a closer\nafter\n\n")
            let characters = Array(source)
            for split in 0...characters.count {
                let chunks = [String(characters[..<split]), String(characters[split...])]
                let streamed = await parse(chunks: chunks)
                #expect(streamed.blocks == single.blocks)
                #expect(streamed.events == (await parse(chunks: chunks)).events)
            }
            #expect((await parse(chunks: source.map(String.init))).blocks == single.blocks)
            for suffix in ["\n\nafter\n\n", ""] {
                let valid = await parse(chunks: ("\(opening)\nx\n\(closing)" + suffix).map(String.init))
                #expect(valid.blocks.first?.mathText == "x\n")
                if !suffix.isEmpty { #expect(valid.blocks.last?.inlineRuns?.map(\.text).joined() == "after") }
            }
        }
    }

    private func parse(chunks: [String], maxLookBehind: Int? = nil) async -> (blocks: [BlockSnapshot], events: [BlockEvent]) {
        let tokenizer = MarkdownTokenizer(maxLookBehind: maxLookBehind)
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
