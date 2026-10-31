#if os(macOS) && canImport(JavaScriptCore)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS mixed SVG and chart loading")
@MainActor
struct MacHostedMixedLoadingIntegrationTests {
    @Test("SVG and Vega share stream activity while retaining separate loading and drawing identities")
    func consecutiveSVGAndChartKeepTheirNativeHosts() async throws {
        _ = NSApplication.shared
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 900)
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering())
        let svgSource = "<svg width=\"160\" height=\"80\"><rect width=\"160\" height=\"80\" fill=\"#4f46e5\"/></svg>\n"
        let chartSource = VegaLiteRenderingFixture.source
        controller.setHostedStreamActive(true)
        defer { controller.setHostedStreamActive(false) }

        func apply(_ update: StreamingUpdate?, configuration: PicoTextKitConfiguration = .default()) {
            guard let update else { return }
            controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                              replaceToken: 1, configuration: configuration, documentIdentity: 1)
        }
        func refresh(configuration: PicoTextKitConfiguration) async {
            controller.update(textView: view, blocks: await pipeline.blocksSnapshot(), diffs: [],
                              replaceToken: 1, configuration: configuration, documentIdentity: 1)
        }

        apply(await pipeline.feed("Before native prose.\n\n```svg\n" + svgSource))
        let svgBlock = try #require(await pipeline.blocksSnapshot().first { $0.svgGraphic != nil })
        let svgAttachment = try #require(controller.hostedAttachment(for: svgBlock.id))
        let svgHost = svgAttachment.loadHostedView()
        await settle(view)
        let svgCanvas = try #require(canvas(in: svgHost))
        let svgModel = svgCanvas.model
        await svgModel.waitForLoadingDelay()
        #expect(svgModel.kind == .svg)
        #expect(svgModel.showsLoadingPlaceholder)
        #expect(svgModel.loadingActivity == .receiving)
        #expect(svgModel.parseCount == 0)
        #expect(svgAttachment.measuredSize.height == 48)
        #expect(view.string.contains("<svg") == false)
        controller.setHostedStreamActive(false)
        #expect(svgModel.loadingActivity == .stopped)
        controller.setHostedStreamActive(true)
        #expect(svgModel.loadingActivity == .receiving)

        var paused = PicoTextKitConfiguration.default()
        paused.isPaused = true
        await refresh(configuration: paused)
        #expect(svgModel.loadingActivity == .paused)
        let pausedText = view.string
        // The deferred update crosses the boundary between the two media kinds.
        apply(await pipeline.feed("```\n\n```vega-lite\n" + chartSource), configuration: paused)
        #expect(view.string == pausedText)
        #expect(svgModel.isClosed == false)
        #expect(svgModel.parseCount == 0)

        await refresh(configuration: .default())
        await settle(view)
        #expect(controller.hostedAttachment(for: svgBlock.id) === svgAttachment)
        #expect(svgAttachment.hostingView === svgHost)
        #expect(canvas(in: svgHost) === svgCanvas)
        #expect(svgModel.isClosed && svgModel.isRenderable)
        #expect(svgModel.showsLoadingPlaceholder == false)
        #expect(svgModel.parseCount == 1)

        let chartBlock = try #require(await pipeline.blocksSnapshot().first { $0.vegaLiteChart != nil })
        let chartAttachment = try #require(controller.hostedAttachment(for: chartBlock.id))
        let chartHost = chartAttachment.loadHostedView()
        await settle(view)
        let chartCanvas = try #require(canvas(in: chartHost))
        let chartModel = chartCanvas.model
        #expect(chartCanvas !== svgCanvas)
        #expect(chartModel.kind == .vegaLite)
        #expect(chartModel.source == chartSource)
        #expect(chartModel.parseCount == 0)
        #expect(chartAttachment.measuredSize.height == 48)
        #expect(view.string.contains("<svg") == false)
        #expect(view.string.contains("\"mark\"") == false)
        await chartModel.waitForLoadingDelay()
        #expect(chartModel.showsLoadingPlaceholder)
        #expect(chartModel.loadingActivity == .receiving)
        await refresh(configuration: paused)
        #expect(chartModel.loadingActivity == .paused)
        await refresh(configuration: .default())
        #expect(chartModel.loadingActivity == .receiving)

        apply(await pipeline.feed("```\n\nAfter native prose.\n\n"))
        apply(await pipeline.finish())
        await settle(view)
        #expect(controller.hostedAttachment(for: chartBlock.id) === chartAttachment)
        #expect(chartAttachment.hostingView === chartHost)
        #expect(canvas(in: chartHost) === chartCanvas)
        #expect(chartModel.isClosed && chartModel.isRenderable)
        #expect(chartModel.showsLoadingPlaceholder == false)
        #expect(chartModel.parseCount == 1)
        #expect(controller.hostedAttachment(for: svgBlock.id) === svgAttachment)
        #expect(canvas(in: svgHost) === svgCanvas)
        #expect(svgModel.source == svgSource)
        #expect(svgModel.parseCount == 1)
        #expect(view.string.contains("Before native prose."))
        #expect(view.string.contains("After native prose."))
        #expect(view.string.contains("<svg") == false)
        #expect(view.string.contains("\"mark\"") == false)
        #expect(view.textLayoutManager != nil)

        let storage = try #require(view.textStorage)
        #expect(storage.string.filter { $0 == "\u{FFFC}" }.count == 2)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.components(separatedBy: "```svg\n" + svgSource + "```").count == 2)
        #expect(copied.components(separatedBy: "```vega-lite\n" + chartSource + "```").count == 2)
        #expect(copied.contains("Before native prose."))
        #expect(copied.contains("After native prose."))
        #expect(copied.contains("\u{FFFC}") == false)
    }

    private func canvas(in view: NSView) -> PicoHostedMediaCanvasView? {
        if let canvas = view as? PicoHostedMediaCanvasView { return canvas }
        for child in view.subviews {
            if let found = canvas(in: child) { return found }
        }
        return nil
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
}
#endif
