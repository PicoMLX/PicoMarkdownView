#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("Offscreen hosted vector geometry")
@MainActor
struct MacHostedVectorGeometryTests {
    @Test("An offscreen chart reserves its viewport before TextKit creates its view")
    func offscreenChartReservesHeight() async throws {
        _ = NSApplication.shared
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        let prefix = String(repeating: "Native paragraph before the offscreen chart.\n\n", count: 30)
        let source = #"{"data":{"values":[{"x":1,"y":2},{"x":2,"y":4}]},"mark":"line","encoding":{"x":{"field":"x","type":"quantitative"},"y":{"field":"y","type":"quantitative"}}}"#
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.updateMermaidContentWidth(400)
        let update = try #require(await pipeline.feed(prefix + "```vega-lite\n" + source + "\n```\n\n"))
        controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                          replaceToken: 1, configuration: .default())
        let storage = try #require(view.textStorage)
        var chart: PicoHostedAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { chart = attachment }
        }
        let attachment = try #require(chart)
        #expect(attachment.hostingView == nil, "the offscreen view must remain lazy")
        #expect(attachment.bounds.height >= 140, "a one-point placeholder collapses the chart until scrolling loads its view")
        let estimated = attachment.bounds.height
        attachment.update(availableWidth: 400, isSelected: false)
        #expect(attachment.bounds.height == estimated)
        #expect(attachment.markdownRepresentation().contains(source))
        #expect(view.textLayoutManager != nil)
    }

    @Test("Chart labels, source actions, and data descriptions use the chart identity")
    func chartAccessibilityIdentity() throws {
        let svg = "<svg width=\"100\" height=\"100\"><g role=\"graphics-symbol\" aria-label=\"North: 28 units\"><rect width=\"20\" height=\"28\"/></g></svg>"
        let model = PicoHostedVectorModel(svg: svg, source: "{}", language: "vega-lite", isClosed: true, kind: .vegaLite)
        let canvas = PicoHostedVectorCanvasView(model: model)
        #expect(canvas.accessibilityLabel() == "Vega-Lite chart")
        #expect((canvas.accessibilityValue() as? String)?.contains("North: 28 units") == true)
        #expect(canvas.accessibilityCustomActions()?.map(\.name).contains("Copy Vega-Lite") == true)
        let chartActions = canvas.accessibilityCustomActions()?.map(\.name) ?? []
        #expect(!chartActions.contains("Copy Mermaid"))
        model.update(svg: svg, source: "flowchart LR\nA-->B", language: "mermaid", isClosed: true, kind: .mermaid)
        #expect(canvas.accessibilityLabel() == "Mermaid diagram")
        #expect(canvas.accessibilityCustomActions()?.map(\.name).contains("Copy Mermaid") == true)
        #expect((canvas.accessibilityValue() as? String)?.contains("North: 28 units") == false)
    }
}
#endif
