#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import SwiftUI
import Testing
@testable import PicoMarkdownView

@Suite("macOS paragraph and list spacing", .serialized)
@MainActor
struct MacParagraphSpacingTests {
    @Test("Paragraph and list boundaries use paragraph margins while sibling items remain compact",
          arguments: [300.0, 600.0], [1.0, 1.5])
    func paragraphAndListBoundaries(width: Double, scale: Double) async throws {
        let fixture = try await ParagraphSpacingFixture(markdown: """
        Opening paragraph.

        Another paragraph.

        - First tight item.
        - Second tight item.

        Following outside paragraph.

        """, width: width, scale: scale)
        defer { fixture.close() }
        try expectGap(15 * scale, from: "Opening", to: "Another", in: fixture)
        try expectGap(15 * scale, from: "Another", to: "First tight", in: fixture)
        try expectGap(3.75 * scale, from: "First tight", to: "Second tight", in: fixture)
        try expectGap(15 * scale, from: "Second tight", to: "Following outside", in: fixture)
        #expect(fixture.view.textLayoutManager != nil)
    }

    @Test("A second paragraph inside an item has paragraph separation", arguments: [1.0, 1.5])
    func continuationParagraphs(scale: Double) async throws {
        let fixture = try await ParagraphSpacingFixture(markdown: """
        1. First item paragraph.

            Continuation paragraph inside the first item.

        2. Following list item.

        Outside the ordered list.

        """, width: 360, scale: scale)
        defer { fixture.close() }
        try expectGap(15 * scale, from: "First item", to: "Continuation", in: fixture)
        try expectGap(15 * scale, from: "Continuation", to: "Following list", in: fixture)
        try expectGap(15 * scale, from: "Following list", to: "Outside the ordered", in: fixture)
        let continuation = try fixture.paragraph(containing: "Continuation")
        #expect(continuation.first.rect.minX > fixture.view.textContainerOrigin.x,
                "paragraph separation must retain the item's hanging indentation")
    }

    @Test("Nested lists preserve compact entry and siblings, then restore paragraph spacing",
          arguments: [1.0, 1.5])
    func nestedListBoundaries(scale: Double) async throws {
        let fixture = try await ParagraphSpacingFixture(markdown: """
        - Outer item text.
          - Nested first item.
          - Nested second item.

          Outer continuation paragraph.

        Outside after the nested list.

        """, width: 360, scale: scale)
        defer { fixture.close() }
        try expectGap(0, from: "Outer item", to: "Nested first", in: fixture)
        try expectGap(3.75 * scale, from: "Nested first", to: "Nested second", in: fixture)
        try expectGap(15 * scale, from: "Nested second", to: "Outer continuation", in: fixture)
        try expectGap(15 * scale, from: "Outer continuation", to: "Outside after", in: fixture)
    }

    @Test("Empty container blocks do not replace the previous visible paragraph's margin")
    func quoteContainerBoundaries() async throws {
        let fixture = try await ParagraphSpacingFixture(markdown: """
        Opening outside paragraph.

        > First quoted paragraph.
        >
        > Another quoted paragraph.

        Following outside text.

        """, width: 360)
        defer { fixture.close() }
        try expectGap(15, from: "Opening outside", to: "First quoted", in: fixture)
        try expectGap(15, from: "First quoted", to: "Another quoted", in: fixture)
        try expectGap(15, from: "Another quoted", to: "Following outside", in: fixture)
    }

    @Test("An item whose first block is a heading does not leave a blank marker line")
    func markerOnFirstChild() async throws {
        let fixture = try await ParagraphSpacingFixture(markdown: """
        Opening outside paragraph.

        - # Child heading carrying the list marker

        Following outside text.

        """, width: 360, chunkSize: 1)
        defer { fixture.close() }
        try expectGap(24, from: "Opening outside", to: "Child heading", in: fixture)
        #expect(!fixture.view.string.contains("• \n"), "the marker must stay with its first child")
    }

    @Test("Spacing is identical in whole and single-character streams and preserves selection")
    func incrementalSpacingAndSelection() async throws {
        let initial = "Selected opening paragraph.\n\n- First streamed item.\n"
        let tail = "- Second streamed item.\n\nOutside streamed paragraph.\n\n"
        let streamed = try await ParagraphSpacingFixture(markdown: initial, width: 360, chunkSize: 1, finish: false)
        defer { streamed.close() }
        let selected = NSRange(location: 0, length: 8)
        streamed.view.setSelectedRange(selected)
        let prefix = streamed.view.string
        try await streamed.append(tail, chunkSize: 1, finish: true)
        #expect(streamed.view.string.hasPrefix(prefix))
        #expect(streamed.view.selectedRange() == selected)

        let whole = try await ParagraphSpacingFixture(markdown: initial + tail, width: 360, chunkSize: Int.max)
        defer { whole.close() }
        let streamedStorage = try #require(streamed.view.textStorage)
        let wholeStorage = try #require(whole.view.textStorage)
        #expect(streamedStorage.isEqual(to: wholeStorage),
                "chunk boundaries must not alter the resulting paragraph styles")
        try expectGap(3.75, from: "First streamed", to: "Second streamed", in: streamed)
        try expectGap(15, from: "Second streamed", to: "Outside streamed", in: streamed)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(streamed.view.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == "Selected")
        #expect(streamed.view.textLayoutManager != nil)
    }

    @Test("Opening a nested list preserves a selection inside its restyled parent")
    func nestedAppendPreservesParentSelection() async throws {
        let fixture = try await ParagraphSpacingFixture(markdown: "- Selected outer text.\n", width: 360,
                                                        chunkSize: 1, finish: false)
        defer { fixture.close() }
        let range = (fixture.view.string as NSString).range(of: "Selected")
        let location = try #require(range.location == NSNotFound ? nil : range.location)
        let selected = NSRange(location: location, length: 8)
        fixture.view.setSelectedRange(selected)
        try await fixture.append("  - A nested item.\n\n", chunkSize: 1, finish: false)
        #expect(fixture.view.selectedRange() == selected)
        try expectGap(0, from: "Selected outer", to: "A nested", in: fixture)
        try await fixture.append("Outside paragraph.\n\n", chunkSize: 1, finish: true)
        #expect(fixture.view.selectedRange() == selected)
        try expectGap(15, from: "A nested", to: "Outside paragraph", in: fixture)
    }

    @Test("Text scaling and wrapping preserve font-relative paragraph boundaries")
    func scalingAndReflow() async throws {
        let fixture = try await ParagraphSpacingFixture(markdown: """
        A long opening paragraph that wraps at a narrow width and keeps its final line separate from the next block.

        - A long list item whose text wraps at a narrow width before its following outside paragraph.

        A following outside paragraph that remains native selectable text.

        """, width: 300)
        defer { fixture.close() }
        try expectGap(15, from: "A long opening", to: "A long list", in: fixture)
        try expectGap(15, from: "A long list", to: "A following outside", in: fixture)
        let selected = NSRange(location: 2, length: 12)
        fixture.view.setSelectedRange(selected)
        let original = fixture.view.string
        await fixture.scaleText(to: 1.5)
        #expect(fixture.view.string == original)
        #expect(fixture.view.selectedRange() == selected)
        try expectGap(22.5, from: "A long opening", to: "A long list", in: fixture)
        try expectGap(22.5, from: "A long list", to: "A following outside", in: fixture)
        await fixture.resize(to: 600)
        try expectGap(22.5, from: "A long opening", to: "A long list", in: fixture)
        try expectGap(22.5, from: "A long list", to: "A following outside", in: fixture)
    }

    @Test("Spacing remains valid after earlier blocks and their cached predecessors are discarded")
    func retainedSpacingContext() async throws {
        let fixture = try await ParagraphSpacingFixture(markdown: "", width: 360, finish: false)
        defer { fixture.close() }
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler(config: AssemblerConfig(maxClosedBlocks: 2))
        let renderer = MarkdownRenderer(theme: fixture.theme) { id in await assembler.block(id) }
        var discarded = false
        func feed(_ text: String) async {
            let parsed = await tokenizer.feed(text)
            let diff = await assembler.apply(parsed)
            discarded = discarded || diff.changes.contains {
                if case .blocksDiscarded = $0 { return true }
                return false
            }
            _ = await renderer.apply(diff)
            let blocks = await renderer.renderedBlocks()
            fixture.apply(StreamingUpdate(diff: diff, blocks: blocks))
        }
        for index in 0..<4 { await feed("Old paragraph \(index).\n\n") }
        await feed("- Kept list item.\n\n")
        await feed("After retained list.\n\n")
        await fixture.settle()
        try expectGap(15, from: "Kept list", to: "After retained", in: fixture)
        fixture.view.setSelectedRange(NSRange(location: 0, length: 4))
        await feed("Latest retained paragraph.\n\n")
        let finalDiff = await assembler.apply(await tokenizer.finish())
        _ = await renderer.apply(finalDiff)
        fixture.apply(StreamingUpdate(diff: finalDiff, blocks: await renderer.renderedBlocks()))
        await fixture.settle()
        #expect(discarded)
        #expect(!fixture.view.string.contains("Old paragraph"))
        try expectGap(15, from: "After retained", to: "Latest retained", in: fixture)
        #expect(NSMaxRange(fixture.view.selectedRange()) <= fixture.view.string.utf16.count)
        #expect(fixture.view.textLayoutManager != nil)
    }

    private func expectGap(_ expected: Double, from previous: String, to next: String,
                           in fixture: ParagraphSpacingFixture) throws {
        let actual = try fixture.extraBaselineGap(from: previous, to: next)
        #expect(abs(actual - expected) < 0.05,
                "\(previous) → \(next): expected \(expected)pt extra gap, got \(actual)pt")
    }
}

@MainActor
private final class ParagraphSpacingFixture {
    let controller = TextKitStreamingController()
    let view: NSTextView
    let pipeline: MarkdownStreamingPipeline
    let theme: MarkdownRenderTheme
    private let window: NSWindow
    private var replaceToken: UInt64 = 1
    private let configuration = PicoTextKitConfiguration(
        contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))

    init(markdown: String, width: Double, scale: Double = 1, chunkSize: Int = 11,
         finish: Bool = true) async throws {
        _ = NSApplication.shared
        let font = FontSpec(size: 15)
        theme = MarkdownRenderTheme(bodyFont: font, codeFont: font,
                                    blockquoteColor: .secondaryLabel, linkColor: .link,
                                    headingFonts: [:]).scaled(by: scale)
        pipeline = MarkdownStreamingPipeline(theme: theme)
        view = controller.makeTextKit2View(configuration: configuration)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 1800)
        window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        try await append(markdown, chunkSize: chunkSize, finish: finish)
    }

    func append(_ markdown: String, chunkSize: Int, finish: Bool) async throws {
        var start = markdown.startIndex
        while start < markdown.endIndex {
            let end = markdown.index(start, offsetBy: chunkSize, limitedBy: markdown.endIndex) ?? markdown.endIndex
            if let update = await pipeline.feed(String(markdown[start..<end])) { apply(update) }
            start = end
        }
        if finish, let update = await pipeline.finish() { apply(update) }
        await settle()
    }

    func scaleText(to scale: CGFloat) async {
        if let blocks = await pipeline.updateTextScale(scale) {
            replaceToken &+= 1
            controller.update(textView: view, blocks: blocks, diffs: [], replaceToken: replaceToken,
                              configuration: configuration, documentIdentity: 1)
        }
        await settle()
    }

    func resize(to width: CGFloat) async {
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
        await settle()
    }

    func close() { window.close() }

    func paragraph(containing text: String) throws -> (first: SpacingLine, last: SpacingLine) {
        let found = (view.string as NSString).range(of: text).location
        let index = try #require(found == NSNotFound ? nil : found, "missing fixture text \(text)")
        let manager = try #require(view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: index))
        let fragment = try #require(manager.textLayoutFragment(for: location))
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }.map { line in
            let rect = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x,
                                                       dy: fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y)
            return SpacingLine(rect: rect, baseline: rect.minY + line.glyphOrigin.y)
        }
        return (try #require(lines.first), try #require(lines.last))
    }

    func extraBaselineGap(from previous: String, to next: String) throws -> Double {
        let last = try paragraph(containing: previous).last
        let first = try paragraph(containing: next).first
        // TextKit 2 line typographic bounds exclude paragraph margins. Correct
        // the baseline step for both lines' ascent offsets, which can differ
        // between body and quote paragraphs, and subtract the prior line box.
        let baselineStep = first.baseline - last.baseline
        let ascentDifference = (first.baseline - first.rect.minY) - (last.baseline - last.rect.minY)
        return baselineStep - ascentDifference - last.rect.height
    }

    func apply(_ update: StreamingUpdate) {
        controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                          replaceToken: replaceToken, configuration: configuration, documentIdentity: 1)
    }

    func settle() async {
        for _ in 0..<3 {
            if let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
            }
            view.layoutSubtreeIfNeeded()
            await Task.yield()
        }
    }
}

private struct SpacingLine {
    let rect: CGRect
    let baseline: CGFloat
}
#endif
