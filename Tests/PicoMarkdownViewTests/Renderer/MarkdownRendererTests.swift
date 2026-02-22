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
        #expect(await provider.callCount() == 1)

        let resizedNarrow = await renderer.updateMermaidContentWidth(320)
        #expect(resizedNarrow != nil)
        blocks = await renderer.renderedBlocks()
        guard let narrow = blocks.first?.mermaidDiagram else {
            Issue.record("Missing narrow mermaid diagram")
            return
        }
        #expect(abs(narrow.size.width - 320) < 0.1)
        #expect(abs(narrow.size.height - 160) < 0.1)
        #expect(await provider.callCount() == 2)

        let sameBucket = await renderer.updateMermaidContentWidth(323)
        #expect(sameBucket == nil)
        #expect(await provider.callCount() == 2)

        let resizedWide = await renderer.updateMermaidContentWidth(520)
        #expect(resizedWide != nil)
        blocks = await renderer.renderedBlocks()
        guard let wide = blocks.first?.mermaidDiagram else {
            Issue.record("Missing widened mermaid diagram")
            return
        }
        #expect(abs(wide.size.width - 520) < 0.1)
        #expect(abs(wide.size.height - 260) < 0.1)
        #expect(await provider.callCount() == 3)
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
        #expect(result == nil)
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
        #expect(!renderedString.contains("diagram"))
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
