#if os(macOS) && canImport(JavaScriptCore)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS hosted Mermaid integration")
@MainActor
struct MacHostedMermaidIntegrationTests {
    @Test("Real streamed SVG keeps one attachment, text offsets and source copying")
    @available(macOS 27.0, *)
    func streamedDrawingRetainsAttachmentAndSelection() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: previewTheme)
        await feed(prefix, pipeline: pipeline, controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let original = try #require(hostedAttachments(in: storage).first)
        let originalLength = storage.length
        #expect(markerCount(in: storage) == 1)
        #expect(original.image == nil, "the hosted diagram must not be a raster attachment")
        #expect(await pipeline.blocksSnapshot().contains { $0.mermaidDiagram?.svg != nil })
        view.setSelectedRange(NSRange(location: 0, length: originalLength))
        let originalSelection = view.selectedRange()

        await feed(" B --> C[Newest node]\n", pipeline: pipeline, controller: controller, view: view)
        #expect(hostedAttachments(in: storage).first === original)
        #expect(storage.length == originalLength)
        #expect(view.selectedRange() == originalSelection)
        #expect(original.markdownRepresentation().contains("Newest node"))

        let validSource = original.markdownRepresentation()
        await feed(" C --> D[\n", pipeline: pipeline, controller: controller, view: view)
        #expect(hostedAttachments(in: storage).first === original)
        #expect(storage.length == originalLength)
        #expect(view.selectedRange() == originalSelection)
        #expect(original.markdownRepresentation() != validSource)
        #expect(original.markdownRepresentation().contains(" C --> D["))

        await feed("Last node]\n```\n\nAfter paragraph stays native.\n\n",
                   pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        await settle(view)
        #expect(hostedAttachments(in: storage).first === original)
        #expect(markerCount(in: storage) == 1)
        #expect(storage.string.contains("Before paragraph with 🧭"))
        #expect(storage.string.contains("After paragraph stays native"))
        #expect(!storage.string.contains("Newest node"))
        #expect(view.textLayoutManager != nil)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let copied = copySelection(from: view)
        #expect(copied.contains("Before paragraph with 🧭"))
        #expect(copied.contains("```mermaid\nflowchart LR"))
        #expect(copied.contains("Newest node"))
        #expect(copied.contains("Last node"))
        #expect(copied.contains("After paragraph stays native"))
        #expect(copied.components(separatedBy: original.markdownRepresentation()).count == 2)
        #expect(!copied.contains("\u{FFFC}"))
    }

    @Test("The actual hosted canvas preserves zoom and parsed drawing state")
    @available(macOS 27.0, *)
    func hostedCanvasKeepsInteractionState() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: previewTheme)
        await feed(prefix, pipeline: pipeline, controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let attachment = try #require(hostedAttachments(in: storage).first)
        let host = attachment.loadHostedView()
        host.layoutSubtreeIfNeeded()
        await settle(view)
        let canvas = try #require(findCanvas(in: host))
        let model = canvas.model
        let initialParseCount = model.parseCount
        model.zoom(by: 2)
        let zoom = model.zoom

        await feed(" B --> C[More content]\n", pipeline: pipeline, controller: controller, view: view)
        await settle(view)
        #expect(hostedAttachments(in: storage).first === attachment)
        #expect(findCanvas(in: host)?.model === model)
        #expect(model.zoom == zoom)
        #expect(model.parseCount > initialParseCount)
        #expect(model.source.contains("More content"))
        let parsedAfterUpdate = model.parseCount
        view.setFrameSize(NSSize(width: 460, height: 900))
        await settle(view)
        #expect(model.zoom == zoom)
        #expect(model.parseCount == parsedAfterUpdate, "native resizing must not reparse unchanged SVG")
        #expect(attachment.context.availableWidth <= 460)
    }

    @Test("The image width cap reaches the provider and stable hosted viewport across streaming and resize")
    @available(macOS 27.0, *)
    func imageWidthCapBoundsHostedViewport() async throws {
        let (controller, view) = makeView()
        view.setFrameSize(NSSize(width: 800, height: 900))
        let defaults = previewTheme
        let theme = MarkdownRenderTheme(bodyFont: defaults.bodyFont,
                                        codeFont: defaults.codeFont,
                                        blockquoteColor: defaults.blockquoteColor,
                                        linkColor: defaults.linkColor,
                                        headingFonts: defaults.headingFonts,
                                        imageMaxWidth: 200,
                                        codeBlockTheme: defaults.codeBlockTheme,
                                        codeHighlighter: defaults.codeHighlighter,
                                        mermaidRenderingMode: defaults.mermaidRenderingMode)
        // Fixed-grid diagram types can keep an intrinsic SVG wider than the
        // requested maximum; the hosted viewport must enforce the cap too.
        let provider = WidthRecordingVectorProvider()
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer(theme: theme, mermaidProvider: provider) { await assembler.block($0) }
        _ = await renderer.updateMermaidContentWidth(800)

        func append(_ text: String) async {
            let diff = await assembler.apply(await tokenizer.feed(text))
            _ = await renderer.apply(diff)
            controller.update(textView: view, blocks: await renderer.renderedBlocks(), diffs: [diff],
                              replaceToken: 1, configuration: .default())
            await settle(view)
        }

        await append("Before.\n\n```mermaid\nflowchart LR\n A --> B\n")
        let storage = try #require(view.textStorage)
        let attachment = try #require(hostedAttachments(in: storage).first)
        let host = attachment.loadHostedView()
        host.layoutSubtreeIfNeeded()
        await settle(view)
        let canvas = try #require(findCanvas(in: host))
        let model = canvas.model
        let parsed = model.parseCount
        #expect(await provider.requestedWidths.last == 200)
        #expect(await renderer.renderedBlocks().contains { $0.mermaidDiagram?.maxWidth == 200 })
        #expect(model.intrinsicSize.width == 600)
        #expect(model.maxWidth == 200)
        #expect(abs(canvas.bounds.width - 200) < 0.5)
        #expect(model.drawingRect(in: canvas.bounds.size).width <= 200.5)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let selection = view.selectedRange()
        model.fitWidth()
        model.zoom(by: 2)
        #expect(model.drawingRect(in: canvas.bounds.size).width > 200,
                "User zoom enlarges vectors inside the capped viewport")
        #expect(abs(canvas.bounds.width - 200) < 0.5)

        await append(" B --> C[Streamed]\n```\n\n")
        #expect(hostedAttachments(in: storage).first === attachment)
        #expect(findCanvas(in: host)?.model === model)
        #expect(model.source.contains("Streamed"))
        #expect(model.zoom == 2)
        #expect(model.parseCount == parsed)
        #expect(view.selectedRange() == selection)
        #expect(model.maxWidth == 200)

        for width: CGFloat in [120, 800] {
            view.setFrameSize(NSSize(width: width, height: 900))
            let blocks = try #require(await renderer.updateMermaidContentWidth(width))
            controller.update(textView: view, blocks: blocks, diffs: [],
                              replaceToken: 1, configuration: .default())
            await settle(view)
            let expected = min(width, 200)
            #expect(await provider.requestedWidths.last == expected)
            #expect(model.maxWidth == expected)
            #expect(abs(canvas.bounds.width - min(attachment.context.availableWidth, expected)) < 0.5)
            #expect(hostedAttachments(in: storage).first === attachment)
            #expect(model.zoom == 2)
            #expect(model.parseCount == parsed, "Metadata-only cap changes do not reparse the SVG")
        }
        model.fitWidth()
        #expect(model.drawingRect(in: canvas.bounds.size).width <= 200.5)
        model.toggleExpanded()
        attachment.invalidateSize()
        await settle(view)
        #expect(abs(canvas.bounds.width - 200) < 0.5,
                "Expansion changes height without bypassing imageMaxWidth")
    }

    @Test("Pause freezes Mermaid source and replacement does not reuse its attachment")
    @available(macOS 27.0, *)
    func pauseResumeAndReplacement() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: previewTheme)
        await feed(prefix, pipeline: pipeline, controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let original = try #require(hostedAttachments(in: storage).first)
        let oldSource = original.markdownRepresentation()
        let oldText = storage.string
        var paused = PicoTextKitConfiguration()
        paused.isPaused = true
        await feed(" B --> C[Deferred until resume]\n", pipeline: pipeline,
                   controller: controller, view: view, configuration: paused)
        #expect(storage.string == oldText)
        #expect(original.markdownRepresentation() == oldSource)
        controller.update(textView: view, blocks: await pipeline.blocksSnapshot(), diffs: [],
                          replaceToken: 1, configuration: .default())
        #expect(hostedAttachments(in: storage).first === original)
        #expect(original.markdownRepresentation().contains("Deferred until resume"))

        let replacement = MarkdownStreamingPipeline(theme: previewTheme)
        await feed("Replacement document.\n\n```mermaid\nflowchart LR\n X[Fresh] --> Y[Replacement]\n```\n\n",
                   pipeline: replacement, controller: controller, view: view, replaceToken: 2)
        apply(await replacement.finish(), controller: controller, view: view, replaceToken: 2)
        await settle(view)
        let fresh = try #require(hostedAttachments(in: storage).first)
        #expect(fresh !== original)
        #expect(fresh.markdownRepresentation().contains("Fresh"))
        #expect(!fresh.markdownRepresentation().contains("Deferred until resume"))
        #expect(!storage.string.contains("Before paragraph"))
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let copied = copySelection(from: view)
        #expect(copied.contains("Replacement document"))
        #expect(!copied.contains("Deferred until resume"))
        #expect(view.textLayoutManager != nil)
    }

    @Test("Assembler retention removes a hosted Mermaid and its export from the document")
    @available(macOS 27.0, *)
    func retentionRemovesDrawing() async throws {
        let (controller, view) = makeView()
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler(config: AssemblerConfig(maxClosedBlocks: 2))
        let renderer = MarkdownRenderer(theme: previewTheme) { await assembler.block($0) }

        func append(_ text: String) async {
            let diff = await assembler.apply(await tokenizer.feed(text))
            _ = await renderer.apply(diff)
            controller.update(textView: view, blocks: await renderer.renderedBlocks(), diffs: [diff],
                              replaceToken: 1, configuration: .default())
        }

        await append("```mermaid\nflowchart LR\n A[Retired diagram] --> B[Old]\n```\n\n")
        let storage = try #require(view.textStorage)
        #expect(hostedAttachments(in: storage).count == 1)
        await append("First later paragraph.\n\n")
        await append("Second later paragraph.\n\n")
        await append("Third later paragraph.\n\n")
        let diff = await assembler.apply(await tokenizer.finish())
        _ = await renderer.apply(diff)
        controller.update(textView: view, blocks: await renderer.renderedBlocks(), diffs: [diff],
                          replaceToken: 1, configuration: .default())
        await settle(view)
        #expect(hostedAttachments(in: storage).isEmpty)
        #expect(markerCount(in: storage) == 0)
        #expect(NSMaxRange(view.selectedRange()) <= storage.length)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let copied = copySelection(from: view)
        #expect(!copied.contains("Retired diagram"))
        #expect(copied.contains("Third later paragraph"))
    }

    @Test("A diagram as a list item's first child retains its native hanging marker")
    @available(macOS 27.0, *)
    func firstChildKeepsNativeListMarker() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: previewTheme)
        let markdown = "1. ```mermaid\n   flowchart LR\n   A[Listed] --> B[Diagram]\n   ```\n\n"
        await feed(markdown, pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        await settle(view)
        let storage = try #require(view.textStorage)
        let attachment = try #require(hostedAttachments(in: storage).first)
        let marker = (storage.string as NSString).range(of: "\u{FFFC}")
        try #require(marker.location != NSNotFound)
        #expect(storage.string.contains("1. \u{FFFC}"))
        let paragraph = try #require(storage.attribute(.paragraphStyle, at: marker.location,
                                                       effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.headIndent > 0)
        #expect(paragraph.firstLineHeadIndent < paragraph.headIndent)
        let available = view.bounds.width - view.textContainerInset.width * 2 - paragraph.headIndent
        #expect(abs(attachment.context.availableWidth - available) < 0.5)
        #expect(attachment.markdownRepresentation().contains("A[Listed]"))
    }

    @Test("Quoted SVG retains native quote decoration and indented available width")
    @available(macOS 27.0, *)
    func quotedDrawingKeepsNativeDecoration() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: previewTheme)
        let markdown = "> ```mermaid\n> flowchart LR\n> A[Quoted] --> B[Diagram]\n> ```\n\n"
        await feed(markdown, pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        await settle(view)
        let storage = try #require(view.textStorage)
        let attachment = try #require(hostedAttachments(in: storage).first)
        let marker = (storage.string as NSString).range(of: "\u{FFFC}")
        try #require(marker.location != NSNotFound)
        let level = storage.attribute(.picoBlockquoteLevel, at: marker.location, effectiveRange: nil) as? Int
        #expect(level == 1)
        let paragraph = try #require(storage.attribute(.paragraphStyle, at: marker.location,
                                                       effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.headIndent > 0)
        let available = view.bounds.width - view.textContainerInset.width * 2 - paragraph.headIndent
        #expect(abs(attachment.context.availableWidth - available) < 0.5)
        #expect(paragraph.textBlocks.isEmpty)
        #expect(view.textLayoutManager != nil)
    }

    @Test("Inline and display math remain raster attachments beside the vector diagram")
    @available(macOS 27.0, *)
    func mathRenderingRemainsUnchanged() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: previewTheme)
        let markdown = "Inline math $x^{2}$.\n\n$$\nx + y\n$$\n\n```mermaid\nflowchart LR\n A --> B\n```\n\n"
        await feed(markdown, pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        await settle(view)
        let storage = try #require(view.textStorage)
        let all = attachments(in: storage)
        let hosted = all.compactMap { $0 as? PicoHostedAttachment }
        let raster = all.filter { !($0 is PicoHostedAttachment) }
        #expect(hosted.count == 1)
        #expect(hosted.allSatisfy { $0.image == nil })
        #expect(raster.count >= 2)
        #expect(raster.allSatisfy { $0.image != nil && $0.bounds.width > 0 && $0.bounds.height > 0 })
        #expect(view.textLayoutManager != nil)
    }

    private var previewTheme: MarkdownRenderTheme {
        .default().withMermaidRendering(.bestEffortDebounced(milliseconds: 0))
    }

    private var prefix: String {
        "Before paragraph with 🧭.\n\n```mermaid\nflowchart LR\n A[Start] --> B[Current]\n"
    }

    private func makeView() -> (TextKitStreamingController, NSTextView) {
        _ = NSApplication.shared
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

    private func findCanvas(in view: NSView) -> PicoHostedMermaidCanvasView? {
        if let canvas = view as? PicoHostedMermaidCanvasView { return canvas }
        for child in view.subviews {
            if let canvas = findCanvas(in: child) { return canvas }
        }
        return nil
    }

    private func copySelection(from view: NSTextView) -> String {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        return pasteboard.string(forType: .string) ?? ""
    }
}

private actor WidthRecordingVectorProvider: MermaidVectorDiagramProvider {
    private(set) var requestedWidths: [CGFloat] = []

    func renderVector(_ request: MermaidRenderRequest) async -> MermaidVectorRenderResult? {
        requestedWidths.append(request.targetWidth ?? -1)
        let svg = "<svg width=\"600\" height=\"300\"><rect width=\"600\" height=\"300\"/></svg>"
        return MermaidVectorRenderResult(svg: svg, intrinsicSize: CGSize(width: 600, height: 300))
    }

    func render(_ request: MermaidRenderRequest) async -> MermaidRenderResult? { nil }
}
#endif
