#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import SwiftUI
import Testing
@testable import PicoMarkdownView

@Suite("macOS hosted attachment integration")
@MainActor
struct MacHostedAttachmentTests {
    @Test("Real table stream retains its attachment, selection and current Markdown")
    @available(macOS 27.0, *)
    func tableStreamRetainsAttachmentAndSelection() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline()
        await feed(tablePrefix, pipeline: pipeline, controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let original = try #require(hostedAttachments(in: storage).first)
        #expect(hostedAttachments(in: storage).count == 1)
        #expect(markerCount(in: storage) == 1)
        let originalLength = storage.length
        view.setSelectedRange(NSRange(location: 0, length: originalLength))
        let selected = view.selectedRange()

        await feed("| Two | Newly streamed row |\n", pipeline: pipeline, controller: controller, view: view)
        let current = try #require(hostedAttachments(in: storage).first)
        #expect(current === original)
        #expect(storage.length == originalLength)
        #expect(view.selectedRange() == selected)
        #expect(current.markdownRepresentation().contains("Two"))
        #expect(current.markdownRepresentation().contains("Newly streamed row"))

        await feed("\nAfter paragraph arrives through the actual parser.\n\n",
                   pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        await settle(view)
        #expect(storage.string.contains("After paragraph arrives"))
        #expect(view.textLayoutManager != nil)
        #expect(hostedAttachments(in: storage).first === original)
        #expect(markerCount(in: storage) == 1)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let copied = copySelection(from: view)
        #expect(copied.contains("Before paragraph"))
        #expect(copied.contains("Newly streamed row"))
        #expect(copied.contains("After paragraph arrives"))
        #expect(copied.components(separatedBy: current.markdownRepresentation()).count == 2)
        #expect(!copied.contains("\u{FFFC}"))
    }

    @Test("Quotes, a rule and a hosted table keep a genuine TextKit 2 graph")
    @available(macOS 27.0, *)
    func supportedMarkdownNeverIntroducesLegacyTextBlocks() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline()
        let markdown = """
        > Quoted paragraph with [a link](https://example.com).
        >
        > | Name | Value |
        > | --- | --- |
        > | Quoted | Table |

        ---

        Final paragraph.

        """
        await feed(markdown, pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        await settle(view)
        let storage = try #require(view.textStorage)
        #expect(view.textLayoutManager != nil)
        #expect(!hostedAttachments(in: storage).isEmpty)
        #expect(storage.string.contains("Quoted paragraph"))
        #expect(storage.string.contains("Final paragraph"))
        var foundQuoteAttribute = false
        var legacyTextBlocks = 0
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
            if (attributes[.picoBlockquoteLevel] as? Int ?? 0) > 0 { foundQuoteAttribute = true }
            legacyTextBlocks += (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.count ?? 0
        }
        #expect(foundQuoteAttribute)
        #expect(legacyTextBlocks == 0)
    }

    @Test("Pause freezes hosted payloads and replacement retires the prior table")
    @available(macOS 27.0, *)
    func pauseResumeAndReplacementRespectHostedPayloads() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline()
        await feed(tablePrefix, pipeline: pipeline, controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let original = try #require(hostedAttachments(in: storage).first)
        let originalMarkdown = original.markdownRepresentation()
        let originalText = storage.string
        var paused = PicoTextKitConfiguration()
        paused.isPaused = true
        await feed("| Paused | Deferred table payload |\n", pipeline: pipeline,
                   controller: controller, view: view, configuration: paused)
        #expect(storage.string == originalText)
        #expect(original.markdownRepresentation() == originalMarkdown)

        controller.update(textView: view, blocks: await pipeline.blocksSnapshot(), diffs: [],
                          replaceToken: 1, configuration: .default())
        #expect(hostedAttachments(in: storage).first === original)
        #expect(original.markdownRepresentation().contains("Deferred table payload"))

        let replacement = MarkdownStreamingPipeline()
        await feed("Replacement document.\n\n| Fresh | Table |\n| --- | --- |\n| New | Value |\n\n",
                   pipeline: replacement, controller: controller, view: view, replaceToken: 2)
        apply(await replacement.finish(), controller: controller, view: view, replaceToken: 2)
        await settle(view)
        let replaced = try #require(hostedAttachments(in: storage).first)
        #expect(replaced !== original)
        #expect(replaced.markdownRepresentation().contains("Fresh"))
        #expect(!replaced.markdownRepresentation().contains("Paused"))
        #expect(!storage.string.contains("Before paragraph"))
        #expect(storage.string.contains("Replacement document"))
        #expect(view.textLayoutManager != nil)
    }

    @Test("Real assembler retention removes a hosted table without stale copy data")
    @available(macOS 27.0, *)
    func assemblerRetentionRemovesHostedTables() async throws {
        let (controller, view) = makeView()
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler(config: AssemblerConfig(maxClosedBlocks: 2))
        let renderer = MarkdownRenderer { await assembler.block($0) }

        func applyChunk(_ text: String) async {
            let result = await tokenizer.feed(text)
            let diff = await assembler.apply(result)
            _ = await renderer.apply(diff)
            controller.update(textView: view, blocks: await renderer.renderedBlocks(), diffs: [diff],
                              replaceToken: 1, configuration: .default())
        }

        await applyChunk("| Retained | Initially |\n| --- | --- |\n| Old | Table |\n\n")
        let storage = try #require(view.textStorage)
        #expect(hostedAttachments(in: storage).count == 1)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        await applyChunk("First later paragraph.\n\n")
        await applyChunk("Second later paragraph.\n\n")
        await applyChunk("Third later paragraph.\n\n")
        let final = await tokenizer.finish()
        let diff = await assembler.apply(final)
        _ = await renderer.apply(diff)
        controller.update(textView: view, blocks: await renderer.renderedBlocks(), diffs: [diff],
                          replaceToken: 1, configuration: .default())
        await settle(view)
        #expect(hostedAttachments(in: storage).isEmpty)
        #expect(markerCount(in: storage) == 0)
        #expect(NSMaxRange(view.selectedRange()) <= storage.length)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let copied = copySelection(from: view)
        #expect(!copied.contains("Retained"))
        #expect(copied.contains("Third later paragraph"))
        #expect(view.textLayoutManager != nil)
    }

    @Test("Existing image and math attachments retain raster content beside hosted tables")
    @available(macOS 27.0, *)
    func imageMathAndLinkRoutingRemainNative() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(imageProvider: HostedAttachmentImageProvider())
        let markdown = """
        Image ![fixture](https://example.com/fixture.png) and math $x^{2}$ with [a link](https://example.com).

        | Name | Value |
        | --- | --- |
        | Table | Hosted |

        """
        await feed(markdown, pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        await settle(view)
        let storage = try #require(view.textStorage)
        let attachments = attachments(in: storage)
        let raster = attachments.filter { !($0 is PicoHostedAttachment) }
        #expect(hostedAttachments(in: storage).count == 1)
        #expect(raster.count >= 2)
        #expect(raster.allSatisfy { $0.image != nil && $0.bounds.width > 0 && $0.bounds.height > 0 })
        #expect(view.textLayoutManager != nil)
        let linkRange = (storage.string as NSString).range(of: "a link")
        #expect(linkRange.location != NSNotFound)
        let url = try #require(URL(string: "https://example.com"))
        var routed: [(URL, String)] = []
        controller.installLinkHandler(on: view) { routed.append(($0, $1)) }
        view.clicked(onLink: url, at: linkRange.location)
        #expect(routed.count == 1)
        #expect(routed.first?.0 == url)
        #expect(routed.first?.1 == "a link")
    }

    @Test("The production controller accepts a reusable interactive hosted attachment")
    @available(macOS 27.0, *)
    func genericInteractiveAttachmentUsesSameHostAndExportPath() async throws {
        let (controller, view) = makeView()
        let attachment = PicoHostedAttachment(interaction: .interactive,
                                               markdown: { "[Run tool](pico-test://run)" }) { _ in
            Button("Run tool") {}
        }
        let content = NSMutableAttributedString(string: "Before widget.\n")
        content.append(NSAttributedString(attachment: attachment))
        content.append(NSAttributedString(string: "\nAfter widget.\n"))
        let snapshot = BlockSnapshot(id: 900, kind: .unknown, isClosed: true)
        let block = RenderedBlock(id: 900, kind: .unknown, content: .picoConverted(from: content),
                                  snapshot: snapshot, table: nil, listItem: nil,
                                  blockquote: nil, math: nil)
        controller.update(textView: view, blocks: [block], diffs: [], replaceToken: 1, configuration: .default())
        await settle(view)
        let storage = try #require(view.textStorage)
        #expect(hostedAttachments(in: storage).first === attachment)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let copied = copySelection(from: view)
        #expect(copied.contains("[Run tool](pico-test://run)"))
        #expect(copied.contains("Before widget"))
        #expect(copied.contains("After widget"))
        #expect(!copied.contains("\u{FFFC}"))
        #expect(view.textLayoutManager != nil)
    }

    private var tablePrefix: String {
        "Before paragraph.\n\n| Name | Notes |\n| --- | --- |\n| One | Existing row |\n"
    }

    private func makeView() -> (TextKitStreamingController, NSTextView) {
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        return (controller, view)
    }

    private func feed(_ text: String, pipeline: MarkdownStreamingPipeline,
                      controller: TextKitStreamingController, view: NSTextView,
                      replaceToken: UInt64 = 1,
                      configuration: PicoTextKitConfiguration = .default()) async {
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 11, limitedBy: text.endIndex) ?? text.endIndex
            apply(await pipeline.feed(String(text[start..<end])), controller: controller,
                  view: view, replaceToken: replaceToken, configuration: configuration)
            start = end
        }
    }

    private func apply(_ update: StreamingUpdate?, controller: TextKitStreamingController,
                       view: NSTextView, replaceToken: UInt64 = 1,
                       configuration: PicoTextKitConfiguration = .default()) {
        guard let update else { return }
        controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                          replaceToken: replaceToken, configuration: configuration)
    }

    private func settle(_ view: NSTextView) async {
        // No gesture claims are made by these in-process tests. Yield across
        // AppKit/SwiftUI layout turns so deferred compatibility switches surface.
        for _ in 0..<3 {
            if let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
            }
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func attachments(in storage: NSTextStorage) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment) }
        }
        return result
    }

    private func hostedAttachments(in storage: NSTextStorage) -> [PicoHostedAttachment] {
        attachments(in: storage).compactMap { $0 as? PicoHostedAttachment }
    }

    private func markerCount(in storage: NSTextStorage) -> Int {
        storage.string.unicodeScalars.filter { $0.value == 0xFFFC }.count
    }

    private func copySelection(from view: NSTextView) -> String {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        // Use AppKit's normal multi-type entry point, which declares formats
        // and invokes the single-type override for each requested format.
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        return pasteboard.string(forType: .string) ?? ""
    }
}

private actor HostedAttachmentImageProvider: MarkdownImageProvider {
    func image(for url: URL) async -> MarkdownImageResult? {
        let size = CGSize(width: 32, height: 18)
        return MarkdownImageResult(image: NSImage(size: size), size: size)
    }
}
#endif
