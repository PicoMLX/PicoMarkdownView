#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS hosted block images")
@MainActor
struct MacHostedImageIntegrationTests {
    @Test("Closing an image-only paragraph hosts it even when its rendered text is unchanged", arguments: ["figure", ""])
    @available(macOS 27.0, *)
    func paragraphClosurePromotesImage(alt: String) async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(imageProvider: ImageFixtureProvider())
        await feed("Before paragraph.\n\n![\(alt)](https://example.com/image.png)\n",
                   pipeline: pipeline, controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let open = try #require(await pipeline.blocksSnapshot().last { !$0.images.isEmpty })
        #expect(!open.snapshot.isClosed)
        #expect(hostedAttachments(in: storage).isEmpty)
        #expect(attachments(in: storage).count == 1)
        let imageContent = open.content
        let length = storage.length
        view.setSelectedRange(NSRange(location: 0, length: length))
        let selection = view.selectedRange()

        let closure = try #require(await pipeline.feed("\n"))
        var closedBlocks = closure.blocks
        let closedIndex = try #require(closedBlocks.firstIndex { $0.id == open.id })
        #expect(closedBlocks[closedIndex].snapshot.isClosed)
        // The renderer currently recreates an equivalent native attachment on
        // closure. Retain its prior presentation to exercise the backend's
        // metadata-only close path with the parser's actual closing diff.
        closedBlocks[closedIndex].content = imageContent
        controller.update(textView: view, blocks: closedBlocks, diffs: [closure.diff],
                          replaceToken: 1, configuration: .default())
        let original = try #require(hostedAttachments(in: storage).first)
        #expect(hostedAttachments(in: storage).count == 1)
        #expect(storage.length == length)
        #expect(view.selectedRange() == selection)

        await feed("After paragraph streams normally.\n\n", pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        #expect(hostedAttachments(in: storage).first === original)
        #expect(view.textLayoutManager != nil)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let copied = copySelection(from: view)
        let imageMarkdown = "![\(alt)](https://example.com/image.png)"
        #expect(copied.contains("Before paragraph."))
        #expect(copied.contains("After paragraph streams normally."))
        #expect(copied.components(separatedBy: imageMarkdown).count == 2)
        #expect(!copied.contains("\u{FFFC}"))
    }

    @Test("A later streamed caption keeps an initially image-only paragraph inline")
    @available(macOS 27.0, *)
    func captionDoesNotPromoteProvisionalBlock() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(imageProvider: ImageFixtureProvider())
        await feed("![figure](https://example.com/image.png)\n", pipeline: pipeline,
                   controller: controller, view: view)
        let storage = try #require(view.textStorage)
        #expect(hostedAttachments(in: storage).isEmpty)
        await feed("Caption continues this same paragraph.\n\n", pipeline: pipeline,
                   controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        #expect(hostedAttachments(in: storage).isEmpty)
        #expect(attachments(in: storage).count == 1)
        #expect(storage.string.contains("Caption continues this same paragraph."))
        #expect(attachments(in: storage).first?.image != nil)
    }

    @Test("Inline, multiple-image and heading content keep native attachments", arguments: [
        "Prefix ![figure](https://example.com/image.png) suffix\n\n",
        "![one](https://example.com/one.png) ![two](https://example.com/two.png)\n\n",
        "# ![heading](https://example.com/image.png)\n\n",
        "![figure](https://example.com/image.png) ` `\n\n",
        "![figure](https://example.com/image.png) [ ](https://example.com)\n\n"
    ])
    @available(macOS 27.0, *)
    func nonBlockImagesRemainNative(markdown: String) async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(imageProvider: ImageFixtureProvider())
        await feed(markdown, pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        let storage = try #require(view.textStorage)
        #expect(hostedAttachments(in: storage).isEmpty)
        let images = attachments(in: storage)
        #expect(!images.isEmpty)
        #expect(images.allSatisfy { $0.image != nil })
    }

    @Test("Table-cell images remain native inside their existing table host")
    @available(macOS 27.0, *)
    func tableImagesKeepExistingPath() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(imageProvider: ImageFixtureProvider())
        await feed("| Picture |\n| --- |\n| ![cell](https://example.com/image.png) |\n\n",
                   pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        let block = try #require(await pipeline.blocksSnapshot().first { $0.table != nil })
        let cell = try #require(block.table?.rows.first?.first)
        let renderedCell = NSAttributedString.picoConverted(from: cell)
        let images = attachments(in: renderedCell)
        #expect(images.count == 1)
        #expect(images.first?.image != nil)
        #expect(!(images.first is PicoHostedAttachment))
        let storage = try #require(view.textStorage)
        #expect(hostedAttachments(in: storage).count == 1, "The table is the only hosted attachment")
        #expect(hostedAttachments(in: storage).first?.markdownRepresentation().contains("![cell]") == true)
    }

    @Test("Standalone images retain quote bars and list markers", arguments: HostedImageTestContainer.allCases)
    @available(macOS 27.0, *)
    func containerMetadataSurvives(container: HostedImageTestContainer) async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(imageProvider: ImageFixtureProvider())
        await feed(container.prefix + "![figure](https://example.com/image.png)\n\nAfter.\n\n",
                   pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let hosted = try #require(hostedAttachments(in: storage).first)
        #expect(hostedAttachments(in: storage).count == 1)
        let range = try #require(attachmentRange(hosted, in: storage))
        let paragraph = try #require(storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.headIndent > 0)
        if container == .quote {
            #expect((storage.attribute(.picoBlockquoteLevel, at: range.location, effectiveRange: nil) as? Int ?? 0) > 0)
        } else {
            #expect(storage.string.contains(container == .unordered ? "• " : "1. "))
            #expect(paragraph.headIndent > paragraph.firstLineHeadIndent)
        }
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let copied = copySelection(from: view)
        #expect(copied.contains("![figure](https://example.com/image.png)"))
        #expect(copied.contains("After."))
        #expect(!copied.contains("\u{FFFC}"))
    }

    @Test("Preferred image aspect and width cap survive streaming and resize")
    @available(macOS 27.0, *)
    func hostedImageKeepsSizeAndInteractionState() async throws {
        let (controller, view) = makeView(width: 800)
        let defaults = MarkdownRenderTheme.default()
        let theme = MarkdownRenderTheme(bodyFont: defaults.bodyFont, codeFont: defaults.codeFont,
                                        blockquoteColor: defaults.blockquoteColor, linkColor: defaults.linkColor,
                                        headingFonts: defaults.headingFonts, imageMaxWidth: 200,
                                        codeBlockTheme: defaults.codeBlockTheme, codeHighlighter: defaults.codeHighlighter,
                                        mermaidRenderingMode: defaults.mermaidRenderingMode)
        // The provider's preferred aspect differs from the NSImage's aspect.
        // Hosting must retain the same sizing contract as the native image path.
        let pipeline = MarkdownStreamingPipeline(theme: theme,
            imageProvider: ImageFixtureProvider(imageSize: CGSize(width: 400, height: 400),
                                                preferredSize: CGSize(width: 800, height: 400)))
        _ = await pipeline.updateMermaidContentWidth(800)
        await feed("Before.\n\n![figure](https://example.com/image.png \"A caption\")\n\n",
                   pipeline: pipeline, controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let original = try #require(hostedAttachments(in: storage).first)
        let host = original.loadHostedView()
        await layout(view, host: host)
        let canvas = try #require(findCanvas(in: host))
        let model = canvas.model
        #expect(abs(model.intrinsicSize.width / model.intrinsicSize.height - 2) < 0.001)
        #expect(canvas.bounds.width <= 200.5)
        #expect(abs(canvas.bounds.height - canvas.bounds.width / 2) < 0.5)
        model.zoom(by: 2)
        #expect(model.zoom == 1, "Inline image zoom is disabled; apps own image navigation")
        #expect(model.markdownRepresentation().contains("\"A caption\""))

        await feed("Tail paragraph.\n\n", pipeline: pipeline, controller: controller, view: view)
        #expect(hostedAttachments(in: storage).first === original)
        #expect(findCanvas(in: host)?.model === model)
        #expect(model.zoom == 1, "Inline image zoom is disabled; apps own image navigation")

        for width: CGFloat in [120, 800] {
            view.setFrameSize(CGSize(width: width, height: 900))
            let refreshed = try #require(await pipeline.updateMermaidContentWidth(width))
            controller.update(textView: view, blocks: refreshed, diffs: [], replaceToken: 1, configuration: .default())
            await layout(view, host: host)
            #expect(hostedAttachments(in: storage).first === original)
            #expect(findCanvas(in: host)?.model === model)
            #expect(model.zoom == 1, "Inline image zoom is disabled; apps own image navigation")
            #expect(abs(canvas.bounds.width - min(original.context.availableWidth, min(width, 200))) < 0.5)
            #expect(abs(model.intrinsicSize.width / model.intrinsicSize.height - 2) < 0.001)
        }
    }

    @Test("An image becoming available refreshes its block without replacing neighboring prose")
    @available(macOS 27.0, *)
    func delayedImageRefreshIsBlockLocal() async throws {
        let (controller, view) = makeView()
        var activations: [MarkdownImageActivation] = []
        controller.installImageTapHandler(on: view) { activations.append($0) }
        let provider = ImageFixtureProvider(available: false)
        let pipeline = MarkdownStreamingPipeline(imageProvider: provider)
        await feed("Before paragraph.\n\n![pending](https://example.com/image.png)\n\nAfter paragraph.\n\n",
                   pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        let image = try #require(await pipeline.blocksSnapshot().first { !$0.images.isEmpty })
        let storage = try #require(view.textStorage)
        #expect(hostedAttachments(in: storage).isEmpty)
        #expect(storage.string.contains("pending"))
        #expect(storage.string.contains("After paragraph."), "Later prose renders while the image is unavailable")
        let before = (storage.string as NSString).range(of: "Before paragraph.")
        let after = (storage.string as NSString).range(of: "After paragraph.")
        let sentinel = NSAttributedString.Key("PicoHostedImageTest.neighbor")
        storage.addAttribute(sentinel, value: "before", range: before)
        storage.addAttribute(sentinel, value: "after", range: after)

        await provider.makeAvailable()
        apply(await pipeline.refreshBlocks([image.id]), controller: controller, view: view)
        #expect(hostedAttachments(in: storage).count == 1)
        let currentBefore = (storage.string as NSString).range(of: "Before paragraph.")
        let currentAfter = (storage.string as NSString).range(of: "After paragraph.")
        #expect(storage.attribute(sentinel, at: currentBefore.location, effectiveRange: nil) as? String == "before")
        #expect(storage.attribute(sentinel, at: currentAfter.location, effectiveRange: nil) as? String == "after")
        #expect(view.textLayoutManager != nil)
        let attachment = try #require(hostedAttachments(in: storage).first)
        let host = attachment.loadHostedView()
        await layout(view, host: host)
        let canvas = try #require(findCanvas(in: host))
        #expect(canvas.accessibilityPerformPress())
        #expect(activations.count == 1)
        #expect(activations.first?.sourceURL.absoluteString == "https://example.com/image.png")
        #expect(activations.first?.altText == "pending")
    }

    @Test("Replacing a document retires its image host and Markdown export")
    @available(macOS 27.0, *)
    func documentReplacementRetiresImage() async throws {
        let (controller, view) = makeView()
        let provider = ImageFixtureProvider()
        let originalPipeline = MarkdownStreamingPipeline(imageProvider: provider)
        await feed("![old](https://example.com/old.png)\n\n", pipeline: originalPipeline,
                   controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let old = try #require(hostedAttachments(in: storage).first)
        let replacement = MarkdownStreamingPipeline(imageProvider: provider)
        await feed("Replacement.\n\n![fresh](https://example.com/fresh.png)\n\n", pipeline: replacement,
                   controller: controller, view: view, replaceToken: 2)
        apply(await replacement.finish(), controller: controller, view: view, replaceToken: 2)
        let fresh = try #require(hostedAttachments(in: storage).first)
        #expect(fresh !== old)
        #expect(hostedAttachments(in: storage).count == 1)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let copied = copySelection(from: view)
        #expect(copied.contains("Replacement."))
        #expect(copied.contains("![fresh](https://example.com/fresh.png)"))
        #expect(!copied.contains("old.png"))
        #expect(!copied.contains("\u{FFFC}"))
    }

    private func makeView(width: CGFloat = 700) -> (TextKitStreamingController, NSTextView) {
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = CGRect(x: 0, y: 0, width: width, height: 900)
        return (controller, view)
    }

    private func feed(_ text: String, pipeline: MarkdownStreamingPipeline,
                      controller: TextKitStreamingController, view: NSTextView,
                      replaceToken: UInt64 = 1) async {
        apply(await pipeline.feed(text), controller: controller, view: view, replaceToken: replaceToken)
    }

    private func apply(_ update: StreamingUpdate?, controller: TextKitStreamingController,
                       view: NSTextView, replaceToken: UInt64 = 1) {
        guard let update else { return }
        controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                          replaceToken: replaceToken, configuration: .default())
    }

    private func layout(_ view: NSTextView, host: NSView) async {
        // Yield through deferred SwiftUI measurement turns without a wall-clock deadline.
        for _ in 0..<8 {
            if let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
            }
            view.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
    }

    private func findCanvas(in view: NSView) -> PicoHostedMediaCanvasView? {
        if let canvas = view as? PicoHostedMediaCanvasView { return canvas }
        return view.subviews.lazy.compactMap { findCanvas(in: $0) }.first
    }

    private func attachments(in attributed: NSAttributedString) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment) }
        }
        return result
    }

    private func hostedAttachments(in attributed: NSAttributedString) -> [PicoHostedAttachment] {
        attachments(in: attributed).compactMap { $0 as? PicoHostedAttachment }
    }

    private func attachmentRange(_ target: NSTextAttachment, in attributed: NSAttributedString) -> NSRange? {
        var result: NSRange?
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, stop in
            guard let attachment = value as? NSTextAttachment, attachment === target else { return }
            result = range
            stop.pointee = true
        }
        return result
    }

    private func copySelection(from view: NSTextView) -> String {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        return pasteboard.string(forType: .string) ?? ""
    }
}

enum HostedImageTestContainer: String, CaseIterable, Sendable {
    case quote, unordered, ordered
    var prefix: String {
        switch self {
        case .quote: "> "
        case .unordered: "- "
        case .ordered: "1. "
        }
    }
}

private actor ImageFixtureProvider: MarkdownImageProvider {
    private let result: MarkdownImageResult
    private var available: Bool

    init(imageSize: CGSize = CGSize(width: 640, height: 320),
         preferredSize: CGSize? = nil, available: Bool = true) {
        result = MarkdownImageResult(image: NSImage(size: imageSize), size: preferredSize ?? imageSize)
        self.available = available
    }

    func image(for url: URL) async -> MarkdownImageResult? { available ? result : nil }
    func makeAvailable() { available = true }
}
#endif
