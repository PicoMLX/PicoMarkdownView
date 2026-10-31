#if os(macOS) && canImport(JavaScriptCore)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS hosted Vega-Lite integration")
@MainActor
struct MacHostedVegaLiteIntegrationTests {
    @Test("A split closing fence replaces native source with one selectable vector chart")
    @available(macOS 27.0, *)
    func closurePreservesNativeProseAndExactSourceCopy() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline()
        let source = VegaLiteRenderingFixture.source
        await feed("Before paragraph with 🧭.\n\n```vega-lite\n" + source,
                   pipeline: pipeline, controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let open = try #require(await pipeline.blocksSnapshot().first { $0.codeBlock != nil })
        #expect(open.snapshot.isClosed == false)
        #expect(open.vegaLiteChart == nil)
        #expect(hostedAttachments(in: storage).isEmpty)
        #expect(storage.string.contains(source))

        apply(await pipeline.feed("``"), controller: controller, view: view)
        #expect(hostedAttachments(in: storage).isEmpty)
        apply(await pipeline.feed("`\n\nAfter paragraph stays native.\n\n"), controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        await settle(view)

        let attachment = try #require(hostedAttachments(in: storage).first)
        let chart = try #require(await pipeline.blocksSnapshot().compactMap(\.vegaLiteChart).first)
        #expect(hostedAttachments(in: storage).count == 1)
        #expect(chart.source == source)
        #expect(attachment.image == nil)
        #expect(storage.string.contains("Before paragraph with 🧭."))
        #expect(storage.string.contains("After paragraph stays native."))
        #expect(storage.string.contains(source) == false)
        #expect(view.textLayoutManager != nil)

        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let copied = copySelection(from: view)
        let fencedSource = "```vega-lite\n" + source + "```"
        #expect(copied.contains("Before paragraph with 🧭."))
        #expect(copied.contains("After paragraph stays native."))
        #expect(copied.components(separatedBy: fencedSource).count == 2)
        #expect(copied.contains("\u{FFFC}") == false)
        #expect(attachment.markdownRepresentation() == fencedSource)

        let host = attachment.loadHostedView()
        await settle(view)
        let canvas = try #require(findCanvas(in: host))
        #expect(canvas.model.kind == .vegaLite)
        #expect(canvas.model.isRenderable)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(canvas.model.copySource(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == source)
    }

    @Test("JSON, Vega and longer info strings remain native code", arguments: [
        "json", "vega", "vega-lite-extra", "vega-lite title"
    ])
    @available(macOS 27.0, *)
    func otherFenceLanguagesStayCode(_ language: String) async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline()
        await feed(VegaLiteRenderingFixture.markdown(language: language),
                   pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let block = try #require(await pipeline.blocksSnapshot().first)
        #expect(block.vegaLiteChart == nil)
        #expect(block.codeBlock?.code == VegaLiteRenderingFixture.source)
        #expect(storage.string.contains(VegaLiteRenderingFixture.source))
        #expect(hostedAttachments(in: storage).isEmpty)
        #expect(view.textLayoutManager != nil)
    }

    @Test("Disabled chart rendering keeps the original source as code")
    @available(macOS 27.0, *)
    func disabledThemeKeepsNativeCode() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: .default().withVegaLiteRendering(false))
        await feed(VegaLiteRenderingFixture.markdown(), pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        let storage = try #require(view.textStorage)
        #expect(await pipeline.blocksSnapshot().allSatisfy { $0.vegaLiteChart == nil })
        #expect(storage.string.contains(VegaLiteRenderingFixture.source))
        #expect(hostedAttachments(in: storage).isEmpty)
    }

    @Test("Malformed and unsupported closed specs fall back to their original native code", arguments: [
        "{\n  \"mark\": \"bar\",\n  broken JSON\n}\n",
        "{\"mark\": \"not-a-vega-lite-mark\", \"data\": {\"values\": []}}\n"
    ])
    @available(macOS 27.0, *)
    func invalidSpecsKeepSource(_ source: String) async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline()
        await feed(VegaLiteRenderingFixture.markdown(source: source),
                   pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let block = try #require(await pipeline.blocksSnapshot().first)
        #expect(block.snapshot.isClosed)
        #expect(block.vegaLiteChart == nil)
        #expect(block.codeBlock?.code == source)
        #expect(storage.string.contains(source))
        #expect(hostedAttachments(in: storage).isEmpty)
    }

    @Test("A chart as a list item's first child carries the native hanging marker")
    @available(macOS 27.0, *)
    func firstChildKeepsListMarkerAndWidth() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline()
        let indented = VegaLiteRenderingFixture.source.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast().map { "   " + $0 }.joined(separator: "\n")
        await feed("1. ```vega-lite\n" + indented + "\n   ```\n\n",
                   pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        await settle(view)
        let storage = try #require(view.textStorage)
        let attachment = try #require(hostedAttachments(in: storage).first)
        let marker = try markerRange(in: storage)
        let paragraph = try #require(storage.attribute(.paragraphStyle, at: marker.location,
                                                       effectiveRange: nil) as? NSParagraphStyle)
        #expect(storage.string.contains("1. \u{FFFC}"))
        #expect(paragraph.headIndent > 0)
        #expect(paragraph.firstLineHeadIndent < paragraph.headIndent)
        #expect(paragraph.textBlocks.isEmpty)
        let expected = view.bounds.width - view.textContainerInset.width * 2 - paragraph.headIndent
        #expect(abs(attachment.context.availableWidth - expected) < 0.5)
        #expect(attachment.markdownRepresentation() == "```vega-lite\n" + VegaLiteRenderingFixture.source + "```")
    }

    @Test("Quoted charts retain native quote decoration and the indented available width")
    @available(macOS 27.0, *)
    func quotedChartKeepsNativeDecoration() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline()
        let quoted = VegaLiteRenderingFixture.markdown().split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }.joined(separator: "\n")
        await feed(quoted, pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        await settle(view)
        let storage = try #require(view.textStorage)
        let attachment = try #require(hostedAttachments(in: storage).first)
        let marker = try markerRange(in: storage)
        #expect(storage.attribute(.picoBlockquoteLevel, at: marker.location, effectiveRange: nil) as? Int == 1)
        let paragraph = try #require(storage.attribute(.paragraphStyle, at: marker.location,
                                                       effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.headIndent > 0)
        #expect(paragraph.textBlocks.isEmpty)
        let expected = view.bounds.width - view.textContainerInset.width * 2 - paragraph.headIndent
        #expect(abs(attachment.context.availableWidth - expected) < 0.5)
        #expect(view.textLayoutManager != nil)
    }

    @Test("Native resize and renderer width changes retain attachment, model, zoom and width cap")
    @available(macOS 27.0, *)
    func resizingKeepsVectorStateAndImageWidthCap() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: VegaLiteRenderingFixture.theme(maxWidth: 220))
        _ = await pipeline.updateMermaidContentWidth(700)
        await feed(VegaLiteRenderingFixture.markdown(), pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let attachment = try #require(hostedAttachments(in: storage).first)
        let host = attachment.loadHostedView()
        await settle(view)
        let canvas = try #require(findCanvas(in: host))
        let model = canvas.model
        #expect(model.maxWidth == 220)
        #expect(model.kind == .vegaLite)
        #expect(model.isRenderable)
        #expect(abs(canvas.bounds.width - 220) < 0.5)
        model.zoom(by: 2)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let selection = view.selectedRange()
        let originalLength = storage.length
        let parsed = model.parseCount

        view.setFrameSize(NSSize(width: 140, height: 900))
        await settle(view)
        #expect(model.parseCount == parsed, "Native layout must reuse the parsed drawing")
        #expect(model.zoom == 2)
        #expect(canvas.bounds.width <= 140.5)

        for width: CGFloat in [140, 700] {
            view.setFrameSize(NSSize(width: width, height: 900))
            let blocks = try #require(await pipeline.updateMermaidContentWidth(width))
            controller.update(textView: view, blocks: blocks, diffs: [], replaceToken: 1, configuration: .default())
            await settle(view)
            #expect(hostedAttachments(in: storage).first === attachment)
            #expect(findCanvas(in: host)?.model === model)
            #expect(model.maxWidth == min(width, 220))
            #expect(model.zoom == 2)
            #expect(canvas.bounds.width <= min(width, 220) + 0.5)
            #expect(storage.length == originalLength)
            #expect(view.selectedRange() == selection)
            #expect(blocks.compactMap(\.vegaLiteChart).first?.maxWidth == min(width, 220))
        }
    }

    @Test("Replacing a source retires its attachment and removes stale chart export")
    @available(macOS 27.0, *)
    func replacementRetiresOldAttachmentAndSource() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline()
        await feed(VegaLiteRenderingFixture.markdown(), pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let original = try #require(hostedAttachments(in: storage).first)

        let source = VegaLiteRenderingFixture.source.replacingOccurrences(of: "Keep  spaces", with: "Replacement source")
        let replacement = MarkdownStreamingPipeline()
        await feed("Replacement paragraph.\n\n" + VegaLiteRenderingFixture.markdown(source: source),
                   pipeline: replacement, controller: controller, view: view, replaceToken: 2)
        apply(await replacement.finish(), controller: controller, view: view, replaceToken: 2)
        let fresh = try #require(hostedAttachments(in: storage).first)
        #expect(fresh !== original)
        #expect(hostedAttachments(in: storage).count == 1)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let copied = copySelection(from: view)
        #expect(copied.contains(source))
        #expect(copied.contains(VegaLiteRenderingFixture.source) == false)

        let plain = MarkdownStreamingPipeline()
        await feed("Only the final native paragraph remains.\n\n", pipeline: plain,
                   controller: controller, view: view, replaceToken: 3)
        apply(await plain.finish(), controller: controller, view: view, replaceToken: 3)
        #expect(hostedAttachments(in: storage).isEmpty)
        #expect(NSMaxRange(view.selectedRange()) <= storage.length)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        #expect(copySelection(from: view).contains("vega-lite") == false)
        #expect(view.textLayoutManager != nil)
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
                      replaceToken: UInt64 = 1) async {
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 17, limitedBy: text.endIndex) ?? text.endIndex
            apply(await pipeline.feed(String(text[start..<end])), controller: controller,
                  view: view, replaceToken: replaceToken)
            start = end
        }
    }

    private func apply(_ update: StreamingUpdate?, controller: TextKitStreamingController,
                       view: NSTextView, replaceToken: UInt64 = 1) {
        guard let update else { return }
        controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                          replaceToken: replaceToken, configuration: .default())
    }

    private func settle(_ view: NSTextView) async {
        for _ in 0..<6 {
            if let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
            }
            view.layoutSubtreeIfNeeded()
            await Task.yield()
        }
    }

    private func hostedAttachments(in storage: NSTextStorage) -> [PicoHostedAttachment] {
        var result: [PicoHostedAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { result.append(attachment) }
        }
        return result
    }

    private func markerRange(in storage: NSTextStorage) throws -> NSRange {
        let marker = (storage.string as NSString).range(of: "\u{FFFC}")
        try #require(marker.location != NSNotFound)
        return marker
    }

    private func findCanvas(in view: NSView) -> PicoHostedVectorCanvasView? {
        if let canvas = view as? PicoHostedVectorCanvasView { return canvas }
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
#endif
