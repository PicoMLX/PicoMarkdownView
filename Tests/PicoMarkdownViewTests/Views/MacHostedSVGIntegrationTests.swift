#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS hosted SVG integration")
@MainActor
struct MacHostedSVGIntegrationTests {
    @Test("Closed SVG renders between native paragraphs and continuous copying preserves its source")
    @available(macOS 27.0, *)
    func nativeParagraphsAndSourceCopy() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering())
        await feed("Before 🧭.\n\n```svg\n" + source + "\n```\n\nAfter paragraph.\n\n",
                   pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let attachment = try #require(attachments(in: storage).first)
        #expect(attachments(in: storage).count == 1)
        #expect(storage.string == "Before 🧭.\n\u{FFFC}\nAfter paragraph.\n")
        #expect(view.textLayoutManager != nil)
        #expect(attachment.image?.size == NSSize(width: 1, height: 1))
        #expect(attachment.markdownRepresentation() == "```svg\n" + source + "\n```")
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.contains("Before 🧭."))
        #expect(copied.contains(attachment.markdownRepresentation()))
        #expect(copied.contains("After paragraph."))
        #expect(!copied.contains("\u{FFFC}"))
        #expect(attachment.context.isSelected)
    }

    @Test("Open SVG keeps one source-copyable loading attachment through closure")
    @available(macOS 27.0, *)
    func closingChangesOnlyFence() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering())
        await feed("Before.\n\n```svg\n" + source + "\n", pipeline: pipeline, controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let loading = try #require(attachments(in: storage).first)
        #expect(attachments(in: storage).count == 1)
        #expect(!storage.string.contains("<svg"))
        #expect(loading.measuredSize.height == 48)
        #expect(loading.markdownRepresentation() == "```svg\n" + source + "\n```")
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.contains("Before."))
        #expect(copied.contains(loading.markdownRepresentation()))
        #expect(!copied.contains("\u{FFFC}"))
        #expect(loading.context.isSelected)
        let before = (storage.string as NSString).range(of: "Before.")
        view.setSelectedRange(before)
        await feed("```\n\nAfter.\n\n", pipeline: pipeline, controller: controller, view: view)
        #expect(attachments(in: storage).count == 1)
        #expect(attachments(in: storage).first === loading)
        #expect(loading.markdownRepresentation() == "```svg\n" + source + "\n```")
        #expect(loading.measuredSize.height >= 140)
        #expect(view.selectedRange() == before)
        #expect(storage.string.contains("Before."))
        #expect(storage.string.contains("After."))
        #expect(!storage.string.contains("<svg"))
    }

    @Test("Disabled and invalid SVG preserve native code fallback", arguments: [false, true])
    @available(macOS 27.0, *)
    func sourceFallback(enabled: Bool) async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering(enabled))
        let code = enabled ? "<svg><rect" : source
        await feed("```svg\n" + code + "\n```\n\n", pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        let storage = try #require(view.textStorage)
        #expect(attachments(in: storage).isEmpty)
        #expect(storage.string.contains(code))
        #expect(view.textLayoutManager != nil)
    }

    @Test("A full apply closes an existing loading attachment when source content is unchanged")
    @available(macOS 27.0, *)
    func fullApplyConvertsUnchangedCodeContent() async throws {
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering()
            .withCodeHighlighting(codeBlockTheme: nil, codeHighlighter: nil))
        _ = await pipeline.feed("```svg\n" + source + "\n```\n\n")
        _ = await pipeline.finish()
        let closed = try #require(await pipeline.blocksSnapshot().first { $0.svgGraphic != nil })
        var open = closed
        open.svgGraphic?.isClosed = false
        open.snapshot.isClosed = false
        // Closure can change only presentation metadata: the complete code
        // source and its native attributes already arrived in earlier chunks.
        #expect(open.content == closed.content)
        let backend = TextKitStreamingBackend()
        let selection = NSRange(location: 0, length: 0)
        _ = backend.apply(blocks: [open], selection: selection)
        #expect(backend.snapshotAttributedString().string == "\u{FFFC}\n")
        let loading = try #require(backend.hostedAttachment(for: closed.id))
        #expect(loading.measuredSize.height == 48)
        #expect(loading.markdownRepresentation().contains(source))

        _ = backend.apply(blocks: [closed], selection: selection)
        let stored = backend.snapshotAttributedString()
        #expect(stored.string == "\u{FFFC}\n")
        let attachment = try #require(stored.attribute(.attachment, at: 0, effectiveRange: nil) as? PicoHostedAttachment)
        #expect(backend.hostedAttachment(for: closed.id) === attachment)
        #expect(attachment === loading)
        #expect(attachment.measuredSize.height >= 140)
        #expect(attachment.markdownRepresentation().contains(source))
        #expect(!backend.needsFullApply(for: [closed]))
    }

    @Test("An invalid SVG closes its loading attachment into native code fallback")
    @available(macOS 27.0, *)
    func invalidLoadingSourceFallsBackOnClosure() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering())
        let raw = "<svg><rect"
        await feed("Before.\n\n```svg\n" + raw + "\n", pipeline: pipeline, controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let loading = try #require(attachments(in: storage).first)
        #expect(loading.measuredSize.height == 48)
        #expect(!storage.string.contains(raw))
        #expect(loading.markdownRepresentation().contains(raw))
        let before = (storage.string as NSString).range(of: "Before.")
        view.setSelectedRange(before)
        await feed("```\n\nAfter.\n\n", pipeline: pipeline, controller: controller, view: view)
        #expect(attachments(in: storage).isEmpty)
        #expect(storage.string.contains(raw))
        #expect(storage.string.contains("After."))
        #expect(view.selectedRange() == before)
    }

    @Test("Offscreen loading SVG remains compact and transparent across width changes")
    @available(macOS 27.0, *)
    func lazyLoadingGeometry() async throws {
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering())
        _ = await pipeline.feed("```svg\n" + source + "\n")
        let open = try #require(await pipeline.blocksSnapshot().first { $0.svgGraphic != nil })
        let backend = TextKitStreamingBackend()
        let selection = NSRange(location: 0, length: 0)
        _ = backend.apply(blocks: [open], selection: selection)
        let attachment = try #require(backend.hostedAttachment(for: open.id))
        #expect(attachment.hostingView == nil)
        #expect(attachment.attachmentCell == nil)
        #expect(attachment.image?.size == NSSize(width: 1, height: 1))
        for width: CGFloat in [640, 180, 700] {
            backend.updateHostedAttachments(width: width, selection: [])
            #expect(attachment.hostingView == nil)
            #expect(attachment.measuredSize.width == width)
            #expect(attachment.measuredSize.height == 48)
        }
        _ = await pipeline.feed("```\n\n")
        let closed = try #require(await pipeline.blocksSnapshot().first { $0.svgGraphic != nil })
        _ = backend.apply(blocks: [closed], selection: selection)
        backend.updateHostedAttachments(width: 640, selection: [])
        #expect(backend.hostedAttachment(for: open.id) === attachment)
        #expect(attachment.hostingView == nil)
        #expect(attachment.measuredSize.height == 320)
        _ = await pipeline.finish()
    }

    @Test("Pause, invalid updates and document replacement retire SVG payloads correctly")
    @available(macOS 27.0, *)
    func payloadLifecycle() async throws {
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering())
        _ = await pipeline.feed("```svg\n" + source + "\n```\n\n")
        _ = await pipeline.finish()
        let original = try #require(await pipeline.blocksSnapshot().first { $0.svgGraphic != nil })
        let backend = TextKitStreamingBackend()
        let selection = NSRange(location: 0, length: 0)
        _ = backend.apply(blocks: [original], selection: selection)
        let first = try #require(backend.hostedAttachment(for: original.id))
        #expect(backend.snapshotAttributedString().string == "\u{FFFC}\n")

        var invalid = original
        invalid.content = AttributedString("<svg><rect\n")
        invalid.codeBlock?.code = "<svg><rect\n"
        invalid.snapshot.codeText = invalid.codeBlock?.code
        invalid.svgGraphic?.source = "<svg><rect\n"
        backend.setPaused(true)
        _ = backend.apply(blocks: [invalid], selection: selection)
        #expect(backend.hostedAttachment(for: original.id) === first)
        #expect(backend.snapshotAttributedString().string == "\u{FFFC}\n")
        backend.setPaused(false)
        _ = backend.apply(blocks: [invalid], selection: selection)
        #expect(backend.hostedAttachment(for: original.id) == nil)
        #expect(backend.snapshotAttributedString().string == "<svg><rect\n")

        _ = backend.apply(blocks: [original], selection: selection)
        let restored = try #require(backend.hostedAttachment(for: original.id))
        #expect(restored !== first)
        backend.resetDocumentOnNextApply()
        _ = backend.apply(blocks: [original], selection: selection)
        let replaced = try #require(backend.hostedAttachment(for: original.id))
        #expect(replaced !== restored)
        _ = backend.apply(blocks: [], selection: selection)
        #expect(backend.hostedAttachment(for: original.id) == nil)
        #expect(backend.snapshotAttributedString().length == 0)
    }

    @Test("Offscreen SVG reserves its vector geometry across resize without creating hosting views")
    @available(macOS 27.0, *)
    func lazyHostRetainsKnownGeometry() async throws {
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering())
        _ = await pipeline.feed("```svg\n" + source + "\n```\n\n")
        _ = await pipeline.finish()
        let block = try #require(await pipeline.blocksSnapshot().first { $0.svgGraphic != nil })
        let backend = TextKitStreamingBackend()
        _ = backend.apply(blocks: [block], selection: NSRange(location: 0, length: 0))
        let attachment = try #require(backend.hostedAttachment(for: block.id))
        #expect(attachment.hostingView == nil)
        #expect(attachment.attachmentCell == nil, "A pending hosted SVG must not flash AppKit's generic file icon")
        let legacyFallback = try #require(attachment.image(forBounds: attachment.bounds, textContainer: nil, characterIndex: 0))
        let content = NSTextContentStorage()
        let nativeFallback = try #require(attachment.image(for: attachment.bounds, attributes: [:],
            location: content.documentRange.location, textContainer: nil))
        for image in [legacyFallback, nativeFallback] {
            #expect(image.size == NSSize(width: 1, height: 1))
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: 4, height: 4), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            #expect((0..<4).allSatisfy { x in (0..<4).allSatisfy { y in bitmap.colorAt(x: x, y: y)?.alphaComponent == 0 } })
        }
        #expect(attachment.measuredSize.height >= 140)
        for width: CGFloat in [640, 180, 700] {
            backend.updateHostedAttachments(width: width, selection: [])
            #expect(attachment.hostingView == nil, "Known vector dimensions must not eagerly create offscreen views")
            #expect(attachment.measuredSize.width == width)
            #expect(attachment.measuredSize.height == ceil(min(360, max(140, width / 2))))
        }
        var capped = block
        capped.svgGraphic?.maxWidth = 240
        _ = backend.apply(blocks: [capped], selection: NSRange(location: 0, length: 0))
        backend.updateHostedAttachments(width: 700, selection: [])
        #expect(backend.hostedAttachment(for: block.id) === attachment)
        #expect(attachment.hostingView == nil)
        #expect(attachment.measuredSize.height == 140)
    }

    @Test("SVG navigation and resize retain its attachment and parsed vector state")
    @available(macOS 27.0, *)
    func resizeRetainsVectorState() async throws {
        let defaults = MarkdownRenderTheme.default()
        let theme = MarkdownRenderTheme(bodyFont: defaults.bodyFont, codeFont: defaults.codeFont,
            blockquoteColor: defaults.blockquoteColor, linkColor: defaults.linkColor,
            headingFonts: defaults.headingFonts, imageMaxWidth: 240, svgRenderingEnabled: true)
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: theme)
        await feed("```svg\n" + source + "\n```\n\n", pipeline: pipeline, controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let attachment = try #require(attachments(in: storage).first)
        attachment.update(availableWidth: 600, isSelected: false)
        let host = attachment.loadHostedView()
        host.layoutSubtreeIfNeeded()
        let canvas = try #require(findCanvas(in: host))
        let model = canvas.model
        #expect(model.isRenderable)
        #expect(model.maxWidth == 240)
        #expect(model.viewportWidth(availableWidth: 600) == 240)
        let parseCount = model.parseCount
        model.zoom(by: 2)
        #expect(model.zoom == 2)
        for width: CGFloat in [180, 700] {
            view.setFrameSize(NSSize(width: width, height: 900))
            view.layoutSubtreeIfNeeded()
            attachment.update(availableWidth: width, isSelected: false)
            host.layoutSubtreeIfNeeded()
            #expect(attachments(in: storage).first === attachment)
            #expect(findCanvas(in: host)?.model === model)
            #expect(model.parseCount == parseCount)
            #expect(model.zoom == 2)
            #expect(model.viewportWidth(availableWidth: width) == min(width, 240))
        }
        await feed("Later streamed paragraph.\n\n", pipeline: pipeline, controller: controller, view: view)
        #expect(attachments(in: storage).first === attachment)
        #expect(model.parseCount == parseCount)
        #expect(model.zoom == 2)
    }

    @Test("A quoted SVG keeps its quote bars and native indentation")
    @available(macOS 27.0, *)
    func nativeQuoteDecoration() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering())
        await feed("> ```svg\n> " + source + "\n", pipeline: pipeline, controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let loading = try #require(attachments(in: storage).first)
        #expect(loading.measuredSize.height == 48)
        let loadingMarker = (storage.string as NSString).range(of: "\u{FFFC}")
        try #require(loadingMarker.location != NSNotFound)
        #expect(storage.attribute(.picoBlockquoteLevel, at: loadingMarker.location, effectiveRange: nil) as? Int == 1)
        await feed("> ```\n\n", pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        #expect(attachments(in: storage).count == 1)
        #expect(attachments(in: storage).first === loading)
        let marker = (storage.string as NSString).range(of: "\u{FFFC}")
        try #require(marker.location != NSNotFound)
        #expect(storage.attribute(.picoBlockquoteLevel, at: marker.location, effectiveRange: nil) as? Int == 1)
        let paragraph = try #require(storage.attribute(.paragraphStyle, at: marker.location,
                                                      effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.headIndent > 0)
        #expect(paragraph.textBlocks.isEmpty)
        #expect(storage.attribute(.backgroundColor, at: marker.location, effectiveRange: nil) == nil)
    }

    @Test("A first-child SVG keeps its ordered list marker beside the attachment")
    @available(macOS 27.0, *)
    func firstChildListMarker() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering())
        await feed("1. ```svg\n   " + source + "\n", pipeline: pipeline, controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let loading = try #require(attachments(in: storage).first)
        #expect(loading.measuredSize.height == 48)
        #expect(storage.string.contains("1. \u{FFFC}"))
        await feed("   ```\n\n", pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        #expect(attachments(in: storage).count == 1)
        #expect(attachments(in: storage).first === loading)
        #expect(storage.string.contains("1. \u{FFFC}"))
        let marker = (storage.string as NSString).range(of: "\u{FFFC}")
        let paragraph = try #require(storage.attribute(.paragraphStyle, at: marker.location,
                                                      effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.firstLineHeadIndent < paragraph.headIndent)
    }

    private let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"320\" height=\"160\"><rect width=\"320\" height=\"160\" fill=\"#3973d5\"/></svg>"

    private func makeView() -> (TextKitStreamingController, NSTextView) {
        _ = NSApplication.shared
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        return (controller, view)
    }

    private func feed(_ text: String, pipeline: MarkdownStreamingPipeline,
                      controller: TextKitStreamingController, view: NSTextView) async {
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 11, limitedBy: text.endIndex) ?? text.endIndex
            apply(await pipeline.feed(String(text[start..<end])), controller: controller, view: view)
            start = end
        }
    }

    private func apply(_ update: StreamingUpdate?, controller: TextKitStreamingController, view: NSTextView) {
        guard let update else { return }
        controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                          replaceToken: 1, configuration: .default())
    }

    private func attachments(in storage: NSTextStorage) -> [PicoHostedAttachment] {
        var result: [PicoHostedAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { result.append(attachment) }
        }
        return result
    }

    private func findCanvas(in view: NSView) -> PicoHostedVectorCanvasView? {
        if let canvas = view as? PicoHostedVectorCanvasView { return canvas }
        return view.subviews.lazy.compactMap { findCanvas(in: $0) }.first
    }
}
#endif
