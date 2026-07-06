import Foundation
import Testing
@testable import PicoMarkdownView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite
struct MarkdownRendererTests {
    @Test("Paragraph rendering produces joined text")
    func paragraphRendering() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let first = await tokenizer.feed("Hello ")
        let diff1 = await assembler.apply(first)
        _ = await renderer.apply(diff1)

        let second = await tokenizer.feed("world\n\n")
        let diff2 = await assembler.apply(second)
        _ = await renderer.apply(diff2)

        let output = await renderer.currentAttributedString()
        let rendered = String(output.characters)
        #expect(rendered.contains("Hello world"))
    }
    
    @Test("Multiline paragraph streaming preserves content")
    func multilineParagraphRendering() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let first = await tokenizer.feed("This is a multiline\n")
        let diff1 = await assembler.apply(first)
        _ = await renderer.apply(diff1)

        let second = await tokenizer.feed("paragraph!\n\n")
        let diff2 = await assembler.apply(second)
        _ = await renderer.apply(diff2)

        let output = await renderer.currentAttributedString()
        let rendered = String(output.characters)
        #expect(rendered.contains("This is a multiline paragraph!"))
    }
    
    @Test("Multiline paragraph single feed preserves content")
    func singleFeedMultilineParagraphRendering() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let first = await tokenizer.feed("This is a multiline\nparagraph!\n\n")
        let diff1 = await assembler.apply(first)
        _ = await renderer.apply(diff1)

        let output = await renderer.currentAttributedString()
        let rendered = String(output.characters)
        #expect(rendered.contains("This is a multiline paragraph!"))
    }

    @Test("Heading and list are rendered with prefixes")
    func headingAndListRendering() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let chunk = await tokenizer.feed("# Title\n- First item\n- Second item\n\n")
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        let output = await renderer.currentAttributedString()
        let rendered = String(output.characters)
        #expect(rendered.contains("Title"))
        #expect(rendered.contains("• First item"))
        #expect(rendered.contains("• Second item"))
    }

    @Test("Table rendering flattens rows with separators")
    func tableRendering() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let chunk = await tokenizer.feed("| A | B |\n| --- | --- |\n| 1 | 2 |\n\n")
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        let output = await renderer.currentAttributedString()
        let rendered = String(output.characters)
        let normalized = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(normalized.contains("A"))
        #expect(normalized.contains("B"))
        #expect(normalized.contains("1"))
        #expect(normalized.contains("2"))
        #expect(!normalized.contains("|"))
    }

    @Test("Table cell inline bold survives cell base styling")
    func tableCellInlineBoldSurvivesCellStyling() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let chunk = await tokenizer.feed("| H1 | H2 |\n| --- | --- |\n| **bold** | plain |\n\n")
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        let blocks = await renderer.renderedBlocks()
        let table = blocks.compactMap(\.table).first
        #expect(table != nil)

        // Body cells use the regular base font, so a bold trait here can only
        // come from the run-level inline styling — which the cell's base
        // attribute pass must not overwrite.
        var foundBold = false
        if let cell = table?.rows.first?.first {
            let rendered = NSAttributedString(cell)
            rendered.enumerateAttribute(.font, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
                guard let font = value as? MarkdownFont else { return }
                #if canImport(UIKit)
                if font.fontDescriptor.symbolicTraits.contains(.traitBold) {
                    foundBold = true
                }
                #else
                if font.fontDescriptor.symbolicTraits.contains(.bold) {
                    foundBold = true
                }
                #endif
            }
        }
        #expect(foundBold, "Inline bold inside a table cell should keep its bold font")
    }

    @Test("Table rendering with inline math does not leak TeX commands")
    func tableRenderingInlineMathDoesNotLeakTeXCommands() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let markdown = """
        | Formula | Notes |
        | --- | --- |
        | \\(\\displaystyle \\int_a^b f(x)\\,dx\\) | integral |

        """

        let first = await tokenizer.feed(markdown)
        let diff1 = await assembler.apply(first)
        _ = await renderer.apply(diff1)

        let final = await tokenizer.finish()
        let diff2 = await assembler.apply(final)
        _ = await renderer.apply(diff2)

        let output = await renderer.currentAttributedString()
        let rendered = NSAttributedString(output).string

        #expect(rendered.contains("Formula"))
        #expect(rendered.contains("integral"))
        #expect(!rendered.contains("displaystyle"))
        #expect(!rendered.contains("int_a"))
    }

    @Test("Multiline code blocks avoid per-line paragraph margins")
    func multilineCodeBlocksAvoidPerLineMargins() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let markdown = "```swift\nlet a = 1\nprint(a)\n```\n\n"
        let chunk = await tokenizer.feed(markdown)
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        let finishChunk = await tokenizer.finish()
        let finishDiff = await assembler.apply(finishChunk)
        _ = await renderer.apply(finishDiff)

        let output = await renderer.currentAttributedString()
        let ns = NSAttributedString(output)
        let rendered = ns.string

        guard let firstLineIndex = rendered.range(of: "let a = 1").map({ rendered.distance(from: rendered.startIndex, to: $0.lowerBound) }),
              let secondLineIndex = rendered.range(of: "print(a)").map({ rendered.distance(from: rendered.startIndex, to: $0.lowerBound) }) else {
            Issue.record("Could not locate code lines in rendered output: \(rendered)")
            return
        }

        guard let firstStyle = ns.attribute(.paragraphStyle, at: firstLineIndex, effectiveRange: nil) as? NSParagraphStyle,
              let secondStyle = ns.attribute(.paragraphStyle, at: secondLineIndex, effectiveRange: nil) as? NSParagraphStyle else {
            Issue.record("Missing paragraph styles on code lines")
            return
        }

        #expect(firstStyle.paragraphSpacing == 0)
        #expect(secondStyle.paragraphSpacing == 0)
        #expect(secondStyle.paragraphSpacingBefore == 0)
    }

    @Test("Closed mermaid fences render diagram attachments")
    func closedMermaidFenceRendersAttachment() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let provider = TestMermaidProvider(imageSize: CGSize(width: 240, height: 120))
        let renderer = MarkdownRenderer(theme: MarkdownRenderTheme.default(),
                                        mermaidProvider: provider) { id in
            await assembler.block(id)
        }

        let markdown = """
        ```mermaid
        sequenceDiagram
        Alice->>Bob: Hello
        ```

        """
        let chunk = await tokenizer.feed(markdown)
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)
        let finishChunk = await tokenizer.finish()
        let finishDiff = await assembler.apply(finishChunk)
        _ = await renderer.apply(finishDiff)

        let blocks = await renderer.renderedBlocks()
        guard let block = blocks.first else {
            Issue.record("Missing rendered block")
            return
        }
        #expect(block.codeBlock?.language == "mermaid")
        #expect(block.mermaidDiagram != nil)
        #expect(await provider.callCount() >= 1)

        let ns = NSAttributedString(block.content)
        var foundAttachment = false
        ns.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ns.length), options: []) { value, _, stop in
            if value is NSTextAttachment {
                foundAttachment = true
                stop.pointee = true
            }
        }
        #expect(foundAttachment)
        #expect(!String(block.content.characters).contains("sequenceDiagram"))
    }

    @Test("Default theme enables mermaid rendering on fence close")
    func defaultThemeEnablesMermaid() {
        #expect(MarkdownRenderTheme.default().mermaidRenderingMode == .onFenceClose)
    }

    @Test("Mermaid diagrams resize with content width updates and bucket coalescing")
    func mermaidResizesWithContentWidthUpdates() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let provider = TestMermaidProvider(imageSize: CGSize(width: 1000, height: 500))
        let renderer = MarkdownRenderer(theme: MarkdownRenderTheme.default(),
                                        mermaidProvider: provider) { id in
            await assembler.block(id)
        }

        let markdown = """
        ```mermaid
        graph LR
        A-->B
        ```

        """
        let chunk = await tokenizer.feed(markdown)
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)
        let finishChunk = await tokenizer.finish()
        let finishDiff = await assembler.apply(finishChunk)
        _ = await renderer.apply(finishDiff)

        var blocks = await renderer.renderedBlocks()
        guard let initial = blocks.first?.mermaidDiagram else {
            Issue.record("Missing initial mermaid diagram")
            return
        }
        #expect(initial.size.width == 1000)
        let initialCallCount = await provider.callCount()
        #expect(initialCallCount >= 1)

        let resizedNarrow = await renderer.updateMermaidContentWidth(320)
        #expect(resizedNarrow != nil)
        blocks = await renderer.renderedBlocks()
        guard let narrow = blocks.first?.mermaidDiagram else {
            Issue.record("Missing narrow mermaid diagram")
            return
        }
        #expect(abs(narrow.size.width - 320) < 0.1)
        #expect(abs(narrow.size.height - 160) < 0.1)
        let narrowCallCount = await provider.callCount()
        #expect(narrowCallCount > initialCallCount)

        let sameBucket = await renderer.updateMermaidContentWidth(323)
        #expect(sameBucket == nil)
        let sameBucketCallCount = await provider.callCount()
        #expect(sameBucketCallCount == narrowCallCount)

        let resizedWide = await renderer.updateMermaidContentWidth(520)
        #expect(resizedWide != nil)
        blocks = await renderer.renderedBlocks()
        guard let wide = blocks.first?.mermaidDiagram else {
            Issue.record("Missing widened mermaid diagram")
            return
        }
        #expect(abs(wide.size.width - 520) < 0.1)
        #expect(abs(wide.size.height - 260) < 0.1)
        #expect(await provider.callCount() > sameBucketCallCount)
    }

    @Test("Mermaid width updates are ignored when mermaid rendering is disabled")
    func mermaidWidthUpdatesIgnoredWhenDisabled() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let provider = TestMermaidProvider(imageSize: CGSize(width: 300, height: 150))
        let renderer = MarkdownRenderer(theme: MarkdownRenderTheme.default().withMermaidRendering(.disabled),
                                        mermaidProvider: provider) { id in
            await assembler.block(id)
        }

        let markdown = """
        ```mermaid
        graph LR
        A-->B
        ```

        """
        let chunk = await tokenizer.feed(markdown)
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        let finishChunk = await tokenizer.finish()
        let finishDiff = await assembler.apply(finishChunk)
        _ = await renderer.apply(finishDiff)

        let widthUpdate = await renderer.updateMermaidContentWidth(240)
        #expect(widthUpdate == nil)
        #expect(await provider.callCount() == 0)

        let blocks = await renderer.renderedBlocks()
        #expect(blocks.first?.mermaidDiagram == nil)
        #expect(blocks.first?.codeBlock?.language == "mermaid")
    }

    @Test("Inline images resize with content width updates and bucket coalescing")
    func inlineImagesResizeWithContentWidthUpdates() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let provider = TestImageProvider(imageSize: CGSize(width: 1000, height: 500))
        let renderer = MarkdownRenderer(theme: MarkdownRenderTheme.default(),
                                        imageProvider: provider) { id in
            await assembler.block(id)
        }

        let chunk = await tokenizer.feed("![diagram](https://example.com/diagram.png)\n\n")
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)
        let finishChunk = await tokenizer.finish()
        let finishDiff = await assembler.apply(finishChunk)
        _ = await renderer.apply(finishDiff)

        var blocks = await renderer.renderedBlocks()
        guard let initialBlock = blocks.first else {
            Issue.record("Missing rendered image block")
            return
        }
        guard let initialBounds = firstAttachmentBounds(in: initialBlock.content) else {
            Issue.record("Missing initial image attachment")
            return
        }
        #expect(abs(initialBounds.width - 1000) < 0.1)
        #expect(abs(initialBounds.height - 500) < 0.1)
        let initialCallCount = await provider.callCount()
        #expect(initialCallCount >= 1)

        let resizedNarrow = await renderer.updateMermaidContentWidth(320)
        #expect(resizedNarrow != nil)
        blocks = await renderer.renderedBlocks()
        guard let narrowBounds = blocks.first.flatMap({ firstAttachmentBounds(in: $0.content) }) else {
            Issue.record("Missing narrow image attachment")
            return
        }
        #expect(abs(narrowBounds.width - 320) < 0.1)
        #expect(abs(narrowBounds.height - 160) < 0.1)
        let narrowCallCount = await provider.callCount()
        #expect(narrowCallCount > initialCallCount)

        let sameBucket = await renderer.updateMermaidContentWidth(323)
        #expect(sameBucket == nil)
        #expect(await provider.callCount() == narrowCallCount)

        let resizedWide = await renderer.updateMermaidContentWidth(520)
        #expect(resizedWide != nil)
        blocks = await renderer.renderedBlocks()
        guard let wideBounds = blocks.first.flatMap({ firstAttachmentBounds(in: $0.content) }) else {
            Issue.record("Missing widened image attachment")
            return
        }
        #expect(abs(wideBounds.width - 520) < 0.1)
        #expect(abs(wideBounds.height - 260) < 0.1)
        #expect(await provider.callCount() > narrowCallCount)
    }

    @Test("Open mermaid fences remain code until closed")
    func openMermaidFenceDefersRendering() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let provider = TestMermaidProvider(imageSize: CGSize(width: 160, height: 90))
        let renderer = MarkdownRenderer(theme: MarkdownRenderTheme.default().withMermaidRendering(.onFenceClose),
                                        mermaidProvider: provider) { id in
            await assembler.block(id)
        }

        let first = await tokenizer.feed("```mermaid\nsequenceDiagram\nAlice->>Bob: Hi")
        let diff1 = await assembler.apply(first)
        _ = await renderer.apply(diff1)

        var blocks = await renderer.renderedBlocks()
        guard let openBlock = blocks.first else {
            Issue.record("Missing open rendered block")
            return
        }
        #expect(openBlock.codeBlock?.language == "mermaid")
        #expect(openBlock.mermaidDiagram == nil)
        #expect(await provider.callCount() == 0)

        let second = await tokenizer.feed("\n```\n\n")
        let diff2 = await assembler.apply(second)
        _ = await renderer.apply(diff2)
        let final = await tokenizer.finish()
        let finalDiff = await assembler.apply(final)
        _ = await renderer.apply(finalDiff)

        blocks = await renderer.renderedBlocks()
        guard let closedBlock = blocks.first else {
            Issue.record("Missing closed rendered block")
            return
        }
        #expect(closedBlock.mermaidDiagram != nil)
        #expect(await provider.callCount() >= 1)
    }

    @Test("Empty diff produces no update")
    func emptyDiffReturnsNil() async {
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let diff = AssemblerDiff(documentVersion: 0, changes: [])
        let result = await renderer.apply(diff)
        #expect(result == false)
    }

    @Test("Paragraph soft line breaks emit spaces")
    func paragraphSoftBreaksEmitSpaces() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let sample = "Readability, however, is emphasized above all else. A Markdown-formatted\ndocument should be publishable as-is.\n\n"
        let chunk = await tokenizer.feed(sample)
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        guard let firstEvent = chunk.events.first else {
            Issue.record("Missing events")
            return
        }
        let blockID: BlockID
        switch firstEvent {
        case .blockStart(let id, _):
            blockID = id
        default:
            Issue.record("Unexpected first event: \(firstEvent)")
            return
        }

        let snapshot = await assembler.block(blockID)
        let texts = snapshot.inlineRuns?.map(\.text) ?? []
        let joined = texts.joined()
        #expect(joined.contains("Markdown-formatted document"))

        let output = await renderer.currentAttributedString()
        let rendered = String(output.characters)
        #expect(rendered.contains("Markdown-formatted document"))
    }

    @Test("Renderer surfaces inline images")
    func rendererSurfacesInlineImages() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let chunk = await tokenizer.feed("Intro ![diagram](https://example.com/diagram.png) outro\n\n")
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        let blocks = await renderer.renderedBlocks()
        guard let paragraph = blocks.first else {
            Issue.record("Missing rendered blocks")
            return
        }

        #expect(paragraph.images.count == 1)
        if let descriptor = paragraph.images.first {
            #expect(descriptor.source == "https://example.com/diagram.png")
            #expect(descriptor.url == URL(string: "https://example.com/diagram.png"))
            #expect(descriptor.altText == "diagram")
        }

        let renderedString = String(paragraph.content.characters)
        #expect(renderedString.contains("Intro"))
        #expect(renderedString.contains("outro"))
        #expect(renderedString.contains("diagram"))
    }

    @Test("Tables render with text table blocks")
    func tablesRenderWithStyledBlocks() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let tableMarkdown = """
        | Col A | Col B |
        | :--- | ---: |
        | A1 | B1 |
        | A2 | B2 |

        """

        let chunk = await tokenizer.feed(tableMarkdown)
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        let finishChunk = await tokenizer.finish()
        let finishDiff = await assembler.apply(finishChunk)
        _ = await renderer.apply(finishDiff)

        let output = await renderer.currentAttributedString()
        let ns = NSAttributedString(output)

#if canImport(AppKit)
        let searchRange = NSRange(location: 0, length: ns.length)
        var foundTableBlock = false
        ns.enumerateAttribute(.paragraphStyle, in: searchRange, options: []) { value, _, stop in
            guard let paragraph = value as? NSParagraphStyle else { return }
            if paragraph.textBlocks.contains(where: { $0 is NSTextTableBlock }) {
                foundTableBlock = true
                stop.pointee = true
            }
        }

        #expect(foundTableBlock)
#else
        // iOS has no NSTextTable; tables render as text rows with a thin
        // U+2502 separator between cells.
        #expect(ns.string.contains("\u{2502}"))
#endif

#if canImport(UIKit)
        typealias TestFont = UIFont
#else
        typealias TestFont = NSFont
#endif

        if ns.length > 0, let font = ns.attribute(.font, at: 0, effectiveRange: nil) as? TestFont {
#if canImport(UIKit)
            #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
#else
            #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
#endif
        } else {
            Issue.record("Missing font attribute for table header")
        }
    }

    @Test("Paragraphs apply custom spacing")
    func paragraphsApplyCustomSpacing() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let chunk = await tokenizer.feed("Body paragraph of text that is fairly long to inspect spacing.\n\n")
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        let finishChunk = await tokenizer.finish()
        let finishDiff = await assembler.apply(finishChunk)
        _ = await renderer.apply(finishDiff)

        let output = await renderer.currentAttributedString()
        let ns = NSAttributedString(output)
        guard ns.length > 0,
              let paragraph = ns.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle else {
            Issue.record("Missing paragraph style for body paragraph")
            return
        }

        #expect(abs(paragraph.lineHeightMultiple - 1.24) < 0.01)
        #expect(paragraph.paragraphSpacing >= 3.5)
        #expect(paragraph.paragraphSpacingBefore == 0)
    }

    @Test("Headings apply expanded spacing")
    func headingsApplyExpandedSpacing() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let chunk = await tokenizer.feed("# Heading Level One\n\n")
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        let finishChunk = await tokenizer.finish()
        let finishDiff = await assembler.apply(finishChunk)
        _ = await renderer.apply(finishDiff)

        let output = await renderer.currentAttributedString()
        let ns = NSAttributedString(output)
        guard ns.length > 0,
              let paragraph = ns.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle else {
            Issue.record("Missing paragraph style for heading")
            return
        }

        #expect(abs(paragraph.lineHeightMultiple - 1.18) < 0.01)
        #expect(paragraph.paragraphSpacingBefore >= 15.0)
        #expect(paragraph.paragraphSpacing >= 9.0)
    }

    @Test("List items use margin-system spacing, not a hardcoded separator gap")
    func listItemsUseMarginSystemSpacing() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        // Nested bullet list: a top-level item with one indented sub-item, like a TOC.
        let markdown = "* Top item\n    * Nested item\n\n"
        let chunk = await tokenizer.feed(markdown)
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)
        let finish = await tokenizer.finish()
        let finishDiff = await assembler.apply(finish)
        _ = await renderer.apply(finishDiff)

        let blocks = await renderer.renderedBlocks()
        let listItems = blocks.filter { $0.listItem != nil }
        guard let topLevel = listItems.first(where: { $0.snapshot.depth == 0 }),
              let nested = listItems.first(where: { $0.snapshot.depth == 1 }) else {
            Issue.record("Expected a top-level and a nested list item, got depths \(listItems.map(\.snapshot.depth))")
            return
        }

        // The body run and the terminating "\n" of a list item form one paragraph.
        // A paragraph's trailing paragraphSpacing is resolved from its terminator's
        // style, so both must agree and must equal the margin-system value:
        // 2pt at depth 0, 0pt at depth 1 (bottomMargin 2, minus the depth penalty).
        // The previous code hardcoded 6pt on the terminator, overriding the
        // depth-based reduction and loosening every gap.
        func paragraphSpacings(in content: AttributedString) -> (first: CGFloat, last: CGFloat)? {
            let ns = NSAttributedString(content)
            guard ns.length > 0,
                  let first = ns.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
                  let last = ns.attribute(.paragraphStyle, at: ns.length - 1, effectiveRange: nil) as? NSParagraphStyle
            else { return nil }
            return (first.paragraphSpacing, last.paragraphSpacing)
        }

        guard let top = paragraphSpacings(in: topLevel.content),
              let sub = paragraphSpacings(in: nested.content) else {
            Issue.record("Missing paragraph styles on list items")
            return
        }

        // Terminator governs the inter-item gap.
        #expect(top.last == 2)
        #expect(sub.last == 0)
        // The whole item paragraph is uniform (body == terminator), as for paragraphs/headings.
        #expect(top.first == top.last)
        #expect(sub.first == sub.last)
    }

    @Test("List item ending in a styled span does not gain a blank line")
    func listItemEndingInCodeSpanStaysTight() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        // The first item ends in an inline-code span, so its trailing "\n"
        // run cannot coalesce into the plain text. It used to survive into
        // the render and, combined with the item's own "\n" terminator,
        // produce an empty paragraph — a full blank line between bullets.
        let markdown = "* Ends with `code`\n* Second item\n\n"
        let chunk = await tokenizer.feed(markdown)
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)
        let finish = await tokenizer.finish()
        let finishDiff = await assembler.apply(finish)
        _ = await renderer.apply(finishDiff)

        let blocks = await renderer.renderedBlocks()
        let listItems = blocks.filter { $0.listItem != nil }
        #expect(listItems.count == 2)

        for item in listItems {
            let text = String(NSAttributedString(item.content).string)
            #expect(!text.contains("\n\n"), "list item rendered an empty paragraph: \(text.debugDescription)")
            #expect(text.hasSuffix("\n") && !text.hasSuffix("\n\n"))
        }
    }

    @Test("Nested blockquotes carry the drawn-bar level attribute, not glyphs")
    func nestedBlockquotesCarryLevelAttribute() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let markdown = "> Level one\n>> Level two\n> > > Level three\n\n"
        let chunk = await tokenizer.feed(markdown)
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)
        let finish = await tokenizer.finish()
        let finishDiff = await assembler.apply(finish)
        _ = await renderer.apply(finishDiff)

        let blocks = await renderer.renderedBlocks()
        let quotes = blocks.filter { $0.blockquote != nil }
        #expect(quotes.count == 3, "expected three nested blockquote blocks, got \(quotes.count)")

        for block in quotes {
            let ns = NSAttributedString.picoConverted(from: block.content)
            // Bars are drawn by the view layer, not baked into the text —
            // selection/copy must not contain bar characters. The custom
            // attribute must survive the AttributedString round-trip, cover
            // the whole block (incl. the trailing newline, so adjacent quote
            // bars merge), and match depth + 1.
            #expect(!ns.string.contains("│"), "bar glyphs leaked into text: \(ns.string.debugDescription)")
            guard ns.length > 0 else {
                Issue.record("empty quote block")
                continue
            }
            var effective = NSRange(location: 0, length: 0)
            let level = ns.attribute(.picoBlockquoteLevel, at: 0, effectiveRange: &effective) as? Int
            #expect(level == block.snapshot.depth + 1)
            #expect(effective == NSRange(location: 0, length: ns.length),
                    "level attribute must span the whole block")
            let style = ns.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.headIndent == BlockquoteBarMetrics.textIndent(level: block.snapshot.depth + 1))
        }
    }

    @Test("Marker-only separators split quotes and return to the outer level")
    func quoteSeparatorReturnsToOuterLevel() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        // The classic Markdown.pl nested-quote sample. GitHub renders:
        // level 1, a nested level 2, then back to level 1.
        let markdown = "> First level.\n>\n> > Nested.\n>\n> Back to first.\n\n"
        let chunk = await tokenizer.feed(markdown)
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)
        let finish = await tokenizer.finish()
        let finishDiff = await assembler.apply(finish)
        _ = await renderer.apply(finishDiff)

        let blocks = await renderer.renderedBlocks()
        let quotes = blocks.filter { $0.blockquote != nil }
        let shapes = quotes.map { block -> (depth: Int, level: Int?, text: String) in
            let ns = NSAttributedString.picoConverted(from: block.content)
            let level = ns.length > 0
                ? ns.attribute(.picoBlockquoteLevel, at: 0, effectiveRange: nil) as? Int
                : nil
            return (block.snapshot.depth, level, ns.string)
        }

        // Document order: first level, the nested quote (its container-only
        // level-1 parent renders nothing), then a fresh level-1 block.
        #expect(shapes.count == 3, "expected 3 rendered quote blocks, got \(shapes)")
        guard shapes.count == 3 else { return }
        #expect(shapes[0].depth == 0 && shapes[0].level == 1 && shapes[0].text.hasPrefix("First level."))
        #expect(shapes[1].depth == 1 && shapes[1].level == 2 && shapes[1].text.hasPrefix("Nested."))
        #expect(shapes[2].depth == 0 && shapes[2].level == 1 && shapes[2].text.hasPrefix("Back to first."))
    }

    @Test("Image-only quote parents are not suppressed as container-only")
    func imageOnlyQuoteParentKeepsContent() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        // The parent quote's only content is an image with an empty alt text;
        // it must still render (and surface its image), not be treated as a
        // container-only parent of the nested quote.
        let markdown = "> ![](https://example.com/a.png)\n>> nested\n\n"
        let chunk = await tokenizer.feed(markdown)
        _ = await renderer.apply(await assembler.apply(chunk))
        let finish = await tokenizer.finish()
        _ = await renderer.apply(await assembler.apply(finish))

        let blocks = await renderer.renderedBlocks()
        let quotes = blocks.filter { $0.blockquote != nil }
        #expect(quotes.count == 2, "expected image parent + nested quote, got \(quotes.count)")
        let parent = quotes.first { $0.snapshot.depth == 0 }
        #expect(parent?.images.isEmpty == false, "parent quote must surface its image")
    }

    @Test("Empty quote parents refresh when their child streams in later")
    func emptyQuoteParentRefreshesOnChildInsertion() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        // Split the nested marker across chunks: the outer quote opens (and
        // renders as a blank quoted line) before its child exists. Inserting
        // the child must refresh the parent so the blank line disappears
        // while the quote is still streaming.
        let first = await tokenizer.feed("> ")
        _ = await renderer.apply(await assembler.apply(first))
        let second = await tokenizer.feed("> nested\n")
        _ = await renderer.apply(await assembler.apply(second))

        let blocks = await renderer.renderedBlocks()
        let parent = blocks.first { $0.kind == .blockquote && $0.snapshot.depth == 0 }
        #expect(parent != nil)
        #expect(NSAttributedString(parent?.content ?? AttributedString()).length == 0,
                "container-only parent must render empty mid-stream")
    }

    @Test("Quote ending in a styled span does not gain a blank quoted line")
    func quoteEndingInCodeSpanStaysTight() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let markdown = "> ends with `code`\n\n"
        let chunk = await tokenizer.feed(markdown)
        _ = await renderer.apply(await assembler.apply(chunk))
        let finish = await tokenizer.finish()
        _ = await renderer.apply(await assembler.apply(finish))

        let blocks = await renderer.renderedBlocks()
        let quote = blocks.first { $0.blockquote != nil }
        let text = NSAttributedString.picoConverted(from: quote?.content ?? AttributedString()).string
        #expect(!text.contains("\n\n"), "quote rendered a blank quoted line: \(text.debugDescription)")
        #expect(text.hasSuffix("\n") && !text.hasSuffix("\n\n"))
    }

    @Test("Trailing space inside a quoted code span is preserved")
    func quotedCodeSpanTrailingSpaceSurvives() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        // The code span's final character is a meaningful space; trimming
        // must only remove the synthetic trailing newline, not content.
        let markdown = "> run `git push `\n\n"
        let chunk = await tokenizer.feed(markdown)
        _ = await renderer.apply(await assembler.apply(chunk))
        let finish = await tokenizer.finish()
        _ = await renderer.apply(await assembler.apply(finish))

        let blocks = await renderer.renderedBlocks()
        let quote = blocks.first { $0.blockquote != nil }
        let text = NSAttributedString.picoConverted(from: quote?.content ?? AttributedString()).string
        #expect(text.contains("git push "), "code span trailing space was trimmed: \(text.debugDescription)")
    }

    @Test("Blockquote bar attributes survive the AttributedString round-trip")
    func blockquoteAttributesSurviveConversion() {
        let source = NSMutableAttributedString(string: "quoted text\n")
        source.addAttributes([
            .picoBlockquoteLevel: 2,
            .picoBlockquoteBarColor: MarkdownColor.red
        ], range: NSRange(location: 0, length: source.length))

        // The pipeline's interchange type is AttributedString; the view layer
        // reads these keys back out of NSTextStorage. The PLAIN conversion
        // initializers drop custom keys, which is why every conversion at the
        // pipeline seams must go through the pico-scoped helpers. If this
        // fails, drawn blockquote bars are silently lost.
        let roundTripped = NSAttributedString.picoConverted(from: .picoConverted(from: source))
        let level = roundTripped.attribute(.picoBlockquoteLevel, at: 0, effectiveRange: nil) as? Int
        let color = roundTripped.attribute(.picoBlockquoteBarColor, at: 0, effectiveRange: nil) as? MarkdownColor
        #expect(level == 2)
        #expect(color != nil)
    }

    @Test("Removing trailing blocks updates cache without crashing")
    func removingTrailingBlocksDoesNotCrash() async {
        let store = TestSnapshotStore()
        let renderer = MarkdownRenderer { id in
            await store.snapshot(for: id)
        }

        let blockID: BlockID = 42
        let paragraph = InlineRun(text: "Hello world", style: [])
        let snapshot = BlockSnapshot(id: blockID,
                                     kind: .paragraph,
                                     inlineRuns: [paragraph],
                                     isClosed: true)
        await store.set(snapshot)

        let diff = AssemblerDiff(documentVersion: 1, changes: [
            .blockStarted(id: blockID, kind: .paragraph, position: 0),
            .blockEnded(id: blockID),
            .blocksDiscarded(range: 0..<1)
        ])

        _ = await renderer.apply(diff)
        let output = await renderer.currentAttributedString()
        #expect(output.characters.isEmpty)
    }
}

private actor TestMermaidProvider: MermaidDiagramProvider {
    private let imageSize: CGSize?
    private var calls = 0

    init(imageSize: CGSize?) {
        self.imageSize = imageSize
    }

    func render(_ request: MermaidRenderRequest) async -> MermaidRenderResult? {
        calls += 1
        guard let imageSize else { return nil }
        let image = makeTestImage(size: imageSize)
        return MermaidRenderResult(image: image, intrinsicSize: imageSize, diagnostics: nil)
    }

    func callCount() -> Int {
        calls
    }
}

private actor TestImageProvider: MarkdownImageProvider {
    private let imageSize: CGSize?
    private var calls = 0

    init(imageSize: CGSize?) {
        self.imageSize = imageSize
    }

    func image(for url: URL) async -> MarkdownImageResult? {
        calls += 1
        guard let imageSize else { return nil }
        let image = makeTestImage(size: imageSize)
        return MarkdownImageResult(image: image, size: imageSize)
    }

    func callCount() -> Int {
        calls
    }
}

private func firstAttachmentBounds(in content: AttributedString) -> CGRect? {
    let ns = NSAttributedString(content)
    var found: CGRect?
    ns.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ns.length), options: []) { value, _, stop in
        if let attachment = value as? NSTextAttachment {
            found = attachment.bounds
            stop.pointee = true
        }
    }
    return found
}

private func makeTestImage(size: CGSize) -> MarkdownImage {
    #if canImport(UIKit)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { context in
        UIColor.systemBlue.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
    #else
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
    image.unlockFocus()
    return image
    #endif
}

private actor TestSnapshotStore {
    private var storage: [BlockID: BlockSnapshot] = [:]

    func set(_ snapshot: BlockSnapshot) {
        storage[snapshot.id] = snapshot
    }

    func snapshot(for id: BlockID) -> BlockSnapshot {
        if let snapshot = storage[id] {
            return snapshot
        }
        return BlockSnapshot(id: id,
                             kind: .unknown,
                             inlineRuns: [InlineRun(text: "", style: [])],
                             isClosed: true)
    }
}
