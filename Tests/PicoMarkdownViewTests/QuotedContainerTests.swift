import Foundation
import Testing
@testable import PicoMarkdownView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Blocks inside blockquotes: headings, fenced code, display math and rules
/// become children of the quote instead of quoted text. Fixture documents
/// come from the original container work (PR #9); the parse of each must be
/// the same whatever the chunk boundaries.
@Suite
struct QuotedContainerTests {
    static let documents = [
        "> ## Heading\n> body **bold**\n> ```swift\n> let x = 1\n>\n> > literal\n> ```\n> after\n\nOutside\n",
        ">> # Nested heading\n>> text\n> # Outer heading\n> after\n\n",
        "> Before\n> ### Title\n> **after** [link](https://example.com)\n\n",
        "> ~~~text\n> # literal\n> ~~~not a close\n> ~~~\n\n",
        "> ```swift\n> unfinished code",
        "```text\n> not a quote\n```\n",
        "   > # H\n   > para\n\n",
        "> $$\n> x\n> $$\n\n",
        "> \\[\n> x\n> \\]\n\n",
        ">   ```swift\n>   let x = 1\n>  one\n> zero\n>    three\n>   ```\n\n",
        "> $$x$$y\n\n",
        "> > ```\n> code\n> > ```\n\n",
        "> ---\n\n",
        "> ***\n\n",
        "> ___\n\n",
        "> > ```swift\n> > code\n> > ```\n\n",
        ">> ```swift\n>> code\n>> ```\n\n",
        "> - - -\n\n",
        "> * * *\n\n",
        "> ---\n> after\n\n",
        "> # heading\n> before\n> * * *\n> after\n\n",
        "> $$x$$\n> y\n\n",
        "> \\[x\\]\n> y\n\n",
        "> ````\n> code\n> `````\n> after\n\n",
        "> ~~~~\n> code\n> ~~~~~~\n> after\n\n",
        ">  # Title\n\n",
        ">   # Title\n\n",
        "> text\n***\nafter\n\n",
        "> text\n---\nafter\n\n",
        "> text\n* * *\nafter\n\n",
        "> ````\n> code\n> ```\n> ````tail\n> ~~~~~\n> `````\n> after\n\n",
        "> text\n$$\nx\n$$\nafter\n\n",
        "> text\n$$x$$\nafter\n\n",
        "> ```\n> code\n>     ```\n> after\n> ```\n\n",
        "> ```\n> code\n>    ```\n> after\n\n",
        "> > inner\n> outer\n\n",
        ">>> foo\n> bar\n>>baz\n\n",
        "> > inner\n>\n> outer\n\n",
        "> > text\n> $$x$$\n\n",
        "> > text\n> ---\n\n",
        "> # h\n> para\n>\n> # second\n\n",
        "> ```\n> \n> code\n> ```\n\n",
        "> # heading\n> ```\n> code\n\nOutside\n",
        "> ## A\n> ## B\n\n",
        "> # H\nunquoted\n\n",
        "> ```\n> x\n> ```\nunquoted\n\n",
        "> ---\nunquoted\n\n",
        "> > # H\n> unquoted\n\n",
        "> text\nlazy\n\n",
        "> ```\n# heading\n\n",
        "> $$\n# heading\n\n",
        "> ```\n~~~\n\n",
        "> ```\n    a\n\n",
        "> $$\n  \n> x\n\n",
        ">> # H",
        "> **before\n>> # H",
        "> > > deep\n> > # H",
        ">> a\n> $$x$$y\n\n",
        ">> a\n> $$x$$\n\n",
        ">> a\n> $$\n> x\n> $$\n\n",
        ">> a\n> \\[x\\]y\n\n"
    ] + emptyHeadingDocuments + markerOnlyDocuments

    /// `> #` … `> ######`, with and without a trailing newline.
    private static let emptyHeadingDocuments: [String] = (1...6).flatMap { level in
        ["> ", "> paragraph\n> "].flatMap { prefix in
            ["\n\n", ""].map { prefix + String(repeating: "#", count: level) + $0 }
        }
    }

    private static let markerOnlyDocuments: [String] = ["> ", "> paragraph\n> ", "> # h\n> "].flatMap { prefix in
        ["\n\n", ""].map { prefix + $0 }
    }

    // MARK: Helpers

    private struct Parsed {
        var events: [BlockEvent]
        var blocks: [BlockSnapshot]
    }

    private func parse(chunks: [String]) async -> Parsed {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        var events: [BlockEvent] = []
        for chunk in chunks {
            let result = await tokenizer.feed(chunk)
            events.append(contentsOf: result.events)
            _ = await assembler.apply(result)
        }
        let finished = await tokenizer.finish()
        events.append(contentsOf: finished.events)
        _ = await assembler.apply(finished)
        return Parsed(events: events, blocks: await assembler.makeSnapshot())
    }

    private func text(of block: BlockSnapshot) -> String {
        (block.inlineRuns ?? []).map(\.text).joined()
    }

    // MARK: Structure

    @Test("Headings, code and text inside a quote are its children, in order")
    func quotedBlocksHaveStructure() async throws {
        let result = await parse(chunks: [Self.documents[0]])
        #expect(result.blocks.map(\.kind) == [
            .blockquote, .heading(level: 2), .paragraph, .fencedCode(language: "swift"), .paragraph, .paragraph
        ])
        let quote = try #require(result.blocks.first)
        for child in result.blocks.dropFirst().dropLast() {
            #expect(child.parentID == quote.id)
            #expect(child.depth == 1)
        }
        #expect(result.blocks.last?.parentID == nil)
        guard result.blocks.count == 6 else { return }
        #expect(text(of: result.blocks[1]) == "Heading")
        #expect(result.blocks[2].inlineRuns?.contains(where: { $0.text == "bold" && $0.style.contains(.bold) }) == true)
        #expect(result.blocks[3].codeText == "let x = 1\n\n> literal\n")
        #expect(text(of: result.blocks[4]) == "after")
        #expect(text(of: result.blocks[5]) == "Outside")
    }

    @Test("Quoted text before a heading stays on the quote; text after it is a paragraph child")
    func textAroundChildren() async {
        let result = await parse(chunks: [Self.documents[2]])
        #expect(result.blocks.map(\.kind) == [.blockquote, .heading(level: 3), .paragraph])
        #expect(text(of: result.blocks[0]).trimmingCharacters(in: .whitespacesAndNewlines) == "Before")
        #expect(text(of: result.blocks[1]) == "Title")
        #expect(result.blocks[2].inlineRuns?.contains(where: { $0.linkURL == "https://example.com" }) == true)
    }

    @Test("Nested quotes keep their own headings and depth")
    func nestedQuoteHeadings() async throws {
        let result = await parse(chunks: [Self.documents[1]])
        #expect(result.blocks.map(\.kind) == [.blockquote, .blockquote, .heading(level: 1), .paragraph, .heading(level: 1), .paragraph])
        let inner = result.blocks[1]
        #expect(inner.parentID == result.blocks[0].id)
        #expect(result.blocks[2].parentID == inner.id)
        #expect(result.blocks[2].depth == 2)
        #expect(result.blocks[4].parentID == result.blocks[0].id, "fewer markers return to the outer quote")
        #expect(text(of: result.blocks[4]) == "Outer heading")
    }

    @Test("Quoted fences keep their indentation and only close on a matching fence")
    func quotedFences() async throws {
        let indented = await parse(chunks: [Self.documents[9]])
        #expect(indented.blocks.first(where: { $0.codeText != nil })?.codeText == "let x = 1\none\nzero\n three\n")

        let longer = await parse(chunks: [Self.documents[23]])
        #expect(longer.blocks.map(\.kind) == [.blockquote, .fencedCode(language: nil), .paragraph])
        #expect(longer.blocks.first(where: { $0.codeText != nil })?.codeText == "code\n")
        #expect(longer.blocks.last.map(text(of:)) == "after")

        let tilde = await parse(chunks: [Self.documents[3]])
        #expect(tilde.blocks.map(\.kind) == [.blockquote, .fencedCode(language: "text")])
        #expect(tilde.blocks.first(where: { $0.codeText != nil })?.codeText == "# literal\n~~~not a close\n")

        let blankLine = await parse(chunks: [Self.documents[41]])
        #expect(blankLine.blocks.last?.codeText == "\ncode\n", "a `>` line inside quoted code is a blank code line")

        let unterminated = await parse(chunks: [Self.documents[4]])
        #expect(unterminated.blocks.map(\.kind) == [.blockquote, .fencedCode(language: "swift")])
        #expect(unterminated.blocks[1].codeText == "unfinished code")
        #expect(unterminated.blocks.allSatisfy { $0.isClosed })
    }

    @Test("A blank line ends a quote even inside its code; the next text is outside")
    func blankLineClosesQuotedCode() async {
        let result = await parse(chunks: [Self.documents[42]])
        #expect(result.blocks.map(\.kind) == [.blockquote, .heading(level: 1), .fencedCode(language: nil), .paragraph])
        #expect(result.blocks[2].codeText == "code\n")
        #expect(result.blocks[3].parentID == nil)
        #expect(text(of: result.blocks[3]) == "Outside")
    }

    @Test("Quoted rules and math are children", arguments: [12, 13, 14, 17, 18])
    func quotedRules(index: Int) async {
        let result = await parse(chunks: [Self.documents[index]])
        #expect(result.blocks.map(\.kind) == [.blockquote, .horizontalRule], Comment(rawValue: Self.documents[index]))
    }

    @Test("Text after a quoted rule or math is a paragraph child")
    func afterRuleAndMath() async {
        let afterRule = await parse(chunks: [Self.documents[19]])
        #expect(afterRule.blocks.map(\.kind) == [.blockquote, .horizontalRule, .paragraph])
        #expect(text(of: afterRule.blocks[2]) == "after")

        for index in [21, 22] {
            let math = await parse(chunks: [Self.documents[index]])
            #expect(math.blocks.map(\.kind) == [.blockquote, .math(display: true), .paragraph], Comment(rawValue: Self.documents[index]))
            #expect(math.blocks.first(where: { $0.mathText != nil })?.mathText == "x")
            #expect(math.blocks.last.map(text(of:)) == "y")
        }

        for index in [7, 8] {
            let block = await parse(chunks: [Self.documents[index]])
            #expect(block.blocks.map(\.kind) == [.blockquote, .math(display: true)], Comment(rawValue: Self.documents[index]))
            #expect(block.blocks.first(where: { $0.mathText != nil })?.mathText == "x\n")
        }
    }

    @Test("An unquoted rule, fence or math after quoted text ends the quote")
    func unquotedOpenersEndTheQuote() async {
        for index in [27, 28, 29] {
            let result = await parse(chunks: [Self.documents[index]])
            #expect(result.blocks.map(\.kind) == [.blockquote, .horizontalRule, .paragraph], Comment(rawValue: Self.documents[index]))
            #expect(result.blocks[1].parentID == nil)
        }
        let math = await parse(chunks: [Self.documents[31]])
        #expect(math.blocks.map(\.kind) == [.blockquote, .math(display: true), .paragraph])
        #expect(math.blocks[1].parentID == nil)
    }

    @Test("Quote markers may be indented, and a heading marker may be padded")
    func indentedMarkers() async {
        let indented = await parse(chunks: ["   > # H\n ", "  > para\n\n"])
        #expect(indented.blocks.map(\.kind) == [.blockquote, .heading(level: 1), .paragraph])
        #expect(indented.blocks.last?.parentID == indented.blocks.first?.id)
        for index in [25, 26] {
            let padded = await parse(chunks: [Self.documents[index]])
            #expect(padded.blocks.map(\.kind) == [.blockquote, .heading(level: 1)], Comment(rawValue: Self.documents[index]))
            #expect(padded.blocks.last.map(text(of:)) == "Title")
        }
    }

    @Test("Marker-only lines separate quoted paragraphs and never leak markers")
    func markerOnlyLines() async {
        let result = await parse(chunks: [Self.documents[40]])
        #expect(result.blocks.map(\.kind) == [.blockquote, .heading(level: 1), .paragraph, .blockquote, .heading(level: 1)])
        #expect(result.blocks.flatMap { $0.inlineRuns ?? [] }.allSatisfy { !$0.text.contains(">") })
        let empty = await parse(chunks: ["> # h\n> "])
        #expect(empty.blocks.map(\.kind) == [.blockquote, .heading(level: 1)])
    }

    @Test("Unmarked text after a quoted heading, code or rule is outside the quote")
    func lazyContinuationNeedsOpenParagraph() async throws {
        for index in [44, 45, 46] {
            let markdown = Self.documents[index]
            let result = await parse(chunks: [markdown])
            let last = try #require(result.blocks.last, Comment(rawValue: markdown))
            #expect(result.blocks.count == 3, Comment(rawValue: markdown))
            #expect(last.kind == .paragraph, Comment(rawValue: markdown))
            #expect(last.parentID == nil, Comment(rawValue: markdown))
            #expect(text(of: last) == "unquoted", Comment(rawValue: markdown))
            #expect(text(of: result.blocks[0]).contains("unquoted") == false, Comment(rawValue: markdown))
        }
        let nested = await parse(chunks: [Self.documents[47]])
        #expect(nested.blocks.map(\.kind) == [.blockquote, .blockquote, .heading(level: 1), .paragraph])
        #expect(nested.blocks.last?.parentID == nested.blocks.first?.id, "fewer markers after a child return to the outer quote")
        let lazy = await parse(chunks: [Self.documents[48]])
        #expect(lazy.blocks.map(\.kind) == [.blockquote])
        #expect(text(of: lazy.blocks[0]).contains("lazy"), "a quoted paragraph still continues lazily")
    }

    @Test("An unmarked partial line closes quoted code or math before any of it is emitted")
    func unmarkedLineClosesVerbatimQuote() async {
        for (opener, kind) in [("```", BlockKind.fencedCode(language: nil)), ("$$", BlockKind.math(display: true))] {
            let tokenizer = MarkdownTokenizer()
            _ = await tokenizer.feed("> \(opener)\n")
            let partial = await tokenizer.feed("#")
            #expect(partial.events == [.blockEnd(id: 2), .blockEnd(id: 1)], Comment(rawValue: opener))
            let result = await parse(chunks: ["> \(opener)\n#", " heading\n\n"])
            #expect(result.blocks.map(\.kind) == [.blockquote, kind, .heading(level: 1)], Comment(rawValue: opener))
            #expect((result.blocks[1].codeText ?? "").isEmpty, Comment(rawValue: opener))
            #expect(result.blocks.last.map(text(of:)) == "heading", Comment(rawValue: opener))
        }
        let fence = await parse(chunks: ["> ```\n~~", "~\n\n"])
        #expect(fence.blocks.map(\.kind) == [.blockquote, .fencedCode(language: nil), .fencedCode(language: nil)])
        #expect((fence.blocks[1].codeText ?? "").isEmpty)
    }

    @Test("Whitespace of a partial unmarked line never reaches quoted code")
    func unmarkedWhitespaceStaysOutOfQuotedCode() async {
        let tokenizer = MarkdownTokenizer()
        _ = await tokenizer.feed("> ```\n ")
        let result = await tokenizer.feed("   a\n")
        // Block 2 is the quoted code; the `a` becomes outside indented code.
        #expect(!result.events.contains { if case .blockAppendFencedCode(let id, _) = $0 { return id == 2 }; return false })
        let streamed = await parse(chunks: ["> ```\n ", "   a\n\n"])
        let whole = await parse(chunks: [Self.documents[52]])
        #expect(streamed.blocks == whole.blocks)
        #expect(whole.blocks.first(where: { $0.kind == .fencedCode(language: nil) }).map { $0.codeText ?? "" } == "")
    }

    @Test("The end of input closes every enclosing quote and flushes their text")
    func endOfInputDrainsNestedQuotes() async {
        let tokenizer = MarkdownTokenizer()
        _ = await tokenizer.feed(">> # H")
        let finished = await tokenizer.finish()
        #expect(finished.openBlocks.isEmpty)
        #expect(finished.events.filter { if case .blockEnd = $0 { return true }; return false }.count == 3)

        let text = await parse(chunks: ["> **before\n>> # H"])
        #expect(text.blocks.map(\.kind) == [.blockquote, .blockquote, .heading(level: 1)])
        #expect(self.text(of: text.blocks[0]).contains("**before"), "the outer quote's pending text flushes")
        #expect(text.blocks.allSatisfy { $0.isClosed })
    }

    @Test("A quoted code line longer than the look-behind budget stays in the code")
    func quotedCodeBeyondLookBehindBudget() async {
        let long = String(repeating: "a", count: 2000)
        let markdown = "> ```\n> " + long + "b\n> ```\n> after\n\n"
        let baseline = await parse(chunks: [markdown])
        #expect(baseline.blocks.map(\.kind) == [.blockquote, .fencedCode(language: nil), .paragraph])
        #expect(baseline.blocks[1].codeText == long + "b\n")
        let characters = Array(markdown)
        for split in [7, 8, 1000, 1500, 2000, 2006, 2007, 2008, 2009, 2010, 2012] {
            let chunks = [String(characters[..<split]), String(characters[split...])]
            let streamed = await parse(chunks: chunks)
            #expect(streamed.blocks == baseline.blocks, "Split at character \(split)")
        }
        let streamed = await parse(chunks: characters.map(String.init))
        #expect(streamed.blocks == baseline.blocks)
    }

    @Test("A fence does not open a quote: `>` lines inside code are code")
    func fenceOutsideQuote() async {
        let result = await parse(chunks: [Self.documents[5]])
        #expect(result.blocks.map(\.kind) == [.fencedCode(language: "text")])
        #expect(result.blocks[0].codeText == "> not a quote\n")
    }

    // MARK: Streaming invariants

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

    // MARK: Rendering

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
        #expect(blocks.count == 6)
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
        #expect(NSAttributedString.picoConverted(from: outside.content).attribute(.picoBlockquoteLevel, at: 0, effectiveRange: nil) == nil)
    }

    @Test("Children of a nested quote carry the nested level")
    func nestedChildrenCarryLevel() async throws {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { await assembler.block($0) }
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed(Self.documents[1])))
        _ = await renderer.apply(await assembler.apply(await tokenizer.finish()))
        let blocks = await renderer.renderedBlocks()
        let innerHeading = try #require(blocks.first(where: { $0.kind == .heading(level: 1) }))
        let content = NSAttributedString.picoConverted(from: innerHeading.content)
        #expect(content.attribute(.picoBlockquoteLevel, at: 0, effectiveRange: nil) as? Int == 2)
        let outerHeading = try #require(blocks.last(where: { $0.kind == .heading(level: 1) }))
        #expect(NSAttributedString.picoConverted(from: outerHeading.content).attribute(.picoBlockquoteLevel, at: 0, effectiveRange: nil) as? Int == 1)
    }
}
