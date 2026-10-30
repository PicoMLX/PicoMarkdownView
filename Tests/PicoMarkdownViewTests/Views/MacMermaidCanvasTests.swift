#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS vector Mermaid canvas")
@MainActor
struct MacMermaidCanvasTests {
    private let svg = """
    <svg width="200" height="100" viewBox="0 0 200 100" xmlns="http://www.w3.org/2000/svg">
      <rect x="80" y="30" width="40" height="40" fill="#ff0000"/>
    </svg>
    """

    @Test("Fit width upscales vectors and zoom stays inside a fixed viewport")
    func fitAndZoomGeometry() {
        let model = makeModel()
        let viewport = CGSize(width: 600, height: 300)
        model.updateViewport(viewport)
        #expect(model.drawingRect(in: viewport) == CGRect(x: 0, y: 0, width: 600, height: 300))
        #expect(!model.capturesScroll)
        let height = model.viewportHeight(availableWidth: 600)
        model.zoom(by: 2)
        #expect(model.drawingRect(in: viewport) == CGRect(x: -300, y: -150, width: 1200, height: 600))
        #expect(model.viewportHeight(availableWidth: 600) == height)
        #expect(model.capturesScroll)
        #expect(model.pan(by: CGPoint(x: 100_000, y: -100_000)))
        #expect(model.pan == CGPoint(x: 300, y: -150))
        #expect(!model.pan(by: CGPoint(x: 10, y: -10)))
        model.fitDiagram()
        #expect(model.pan == .zero)
        #expect(!model.capturesScroll)
    }

    @Test("Fit width, viewport changes and expansion keep finite bounded geometry")
    func tallDiagramAndResizing() {
        let model = PicoHostedMermaidModel(svg: "<svg width=\"100\" height=\"400\"><rect width=\"100\" height=\"400\"/></svg>",
                                           source: "flowchart TD\nA-->B", language: "mermaid", isClosed: true)
        model.updateViewport(CGSize(width: 500, height: 300))
        model.fitWidth()
        #expect(model.drawingRect(in: CGSize(width: 500, height: 300)).width == 500)
        #expect(model.capturesScroll)
        model.pan(by: CGPoint(x: 10_000, y: 10_000))
        #expect(model.pan.x == 0)
        #expect(model.pan.y == 850)
        model.updateViewport(CGSize(width: 200, height: 300))
        #expect(model.pan.y == 250)
        #expect(model.viewportHeight(availableWidth: 500) == 360)
        model.toggleExpanded()
        #expect(model.viewportHeight(availableWidth: 500) == 600)
        model.zoom(by: .infinity)
        model.zoom(by: .nan)
        #expect(model.zoom.isFinite)
        #expect(!model.pan(by: CGPoint(x: CGFloat.infinity, y: 0)))
    }

    @Test("Streaming source, zoom and resize reuse the parsed vector document")
    func updatesPreserveState() {
        let model = makeModel()
        model.updateViewport(CGSize(width: 600, height: 300))
        model.zoom(by: 2)
        model.pan(by: CGPoint(x: 40, y: 20))
        model.update(svg: svg, source: "flowchart LR\nA-->B\nB-->C", language: "mermaid", isClosed: false)
        #expect(model.parseCount == 1)
        #expect(model.zoom == 2)
        #expect(model.pan == CGPoint(x: 40, y: 20))
        #expect(!model.isClosed)
        #expect(model.markdownRepresentation().contains("B-->C"))
        model.update(svg: svg.replacingOccurrences(of: "#ff0000", with: "#0000ff"),
                     source: model.source, language: "mermaid", isClosed: true)
        #expect(model.parseCount == 2)
        #expect(model.zoom == 2)
        #expect(model.pan == CGPoint(x: 40, y: 20))
        #expect(model.isClosed)
    }

    @Test("Source export chooses safe fences and is independent of zoom")
    func exportsSource() {
        let source = "flowchart LR\nA[\"````\"] --> B\n"
        let model = PicoHostedMermaidModel(svg: svg, source: source, language: "mermaid title=Demo", isClosed: false)
        let markdown = model.markdownRepresentation()
        #expect(markdown == "`````mermaid title=Demo\n" + source + "`````")
        model.zoom(by: 4)
        model.toggleExpanded()
        #expect(model.markdownRepresentation() == markdown)
        #expect(model.source == source)
        let tilde = PicoHostedMermaidModel(svg: svg, source: "A[~~~]", language: "mermaid title=`Demo`", isClosed: true)
        #expect(tilde.markdownRepresentation().hasPrefix("~~~~mermaid title=`Demo`\n"))
    }

    @Test("Native vector canvas redraws geometry at the requested zoom")
    @available(macOS 27.0, *)
    func redrawsVectorsAtZoom() throws {
        _ = NSApplication.shared
        let model = makeModel()
        let view = PicoHostedMermaidCanvasView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 238)
        view.layoutSubtreeIfNeeded()
        let before = try redPixelCount(in: view)
        model.zoom(by: 2)
        let after = try redPixelCount(in: view)
        #expect(before > 1_000)
        #expect(after > before * 3)
        #expect(model.parseCount == 1)
        #expect(view.frame.height == 238)
    }

    @Test("Floating controls reserve no strip above the vector drawing")
    @available(macOS 27.0, *)
    func controlsOverlayDrawing() throws {
        _ = NSApplication.shared
        let model = PicoHostedMermaidModel(svg: "<svg width=\"200\" height=\"100\"><rect width=\"200\" height=\"100\" fill=\"#ff0000\"/></svg>",
                                           source: "flowchart LR\nA-->B", language: "mermaid", isClosed: true)
        let view = PicoHostedMermaidCanvasView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(center.alphaComponent > 0.99 && center.redComponent > center.greenComponent + 0.5,
                "The vector drawing paints the center of the viewport")
        for y in [2, bitmap.pixelsHigh - 3] {
            let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.sRGB))
            #expect(color == center, "Both edges match the rendered center, with no empty toolbar strip")
        }
        #expect(model.drawingRect(in: view.bounds.size) == view.bounds)
    }

    @Test("Hosted canvas survives initial and narrow measurement before controls become usable")
    @available(macOS 27.0, *)
    func initialAndNarrowHostedMeasurement() async throws {
        _ = NSApplication.shared
        let model = makeModel()
        let attachment = PicoHostedAttachment(interaction: .selectableBlock,
                                               markdown: { model.markdownRepresentation() }) { context in
            PicoHostedMermaidView(model: model, context: context)
        }
        let hosting = attachment.loadHostedView()
        for width: CGFloat in [0, 1, 40, 420] {
            attachment.update(availableWidth: width, isSelected: false)
            hosting.frame = CGRect(x: 0, y: 0, width: width, height: 1)
            for _ in 0..<3 {
                hosting.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            let size = hosting.fittingSize
            #expect(size.width.isFinite && size.width > 0)
            #expect(size.height.isFinite && size.height > 0)
        }
        let canvas = try #require(descendants(of: hosting).compactMap { $0 as? PicoHostedMermaidCanvasView }.first)
        canvas.layoutSubtreeIfNeeded()
        let buttons = descendants(of: canvas).compactMap { $0 as? NSButton }
        #expect(buttons.count == 6)
        for button in buttons {
            let frame = button.convert(button.bounds, to: canvas)
            #expect(frame.width > 0 && frame.height > 0)
            #expect(canvas.bounds.contains(frame), "Controls fit after the attachment receives its actual width")
        }
        let zoomIn = try #require(buttons.first { $0.accessibilityLabel() == "Zoom in" })
        zoomIn.performClick(nil)
        #expect(model.zoom > 1, "Controls still act on the same model after startup sizing")
        #expect(canvas.model === model)
        #expect(model.parseCount == 1)
        #expect(attachment.markdownRepresentation() == model.markdownRepresentation())
    }

    @Test("Wheel scroll passes to the transcript until zoomed, and chains at a pan boundary")
    @available(macOS 27.0, *)
    func wheelRouting() throws {
        _ = NSApplication.shared
        let model = makeModel()
        let view = PicoHostedMermaidCanvasView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 238)
        view.layoutSubtreeIfNeeded()
        let transcript = MermaidScrollResponder()
        view.nextResponder = transcript
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: 10, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        view.scrollWheel(with: event)
        #expect(transcript.scrollEvents == 1)
        model.zoom(by: 2)
        view.scrollWheel(with: event)
        #expect(transcript.scrollEvents == 1)
        #expect(model.pan.y != 0)
        model.pan(by: CGPoint(x: 100_000, y: event.scrollingDeltaY >= 0 ? 100_000 : -100_000))
        view.scrollWheel(with: event)
        #expect(transcript.scrollEvents == 2)
        view.cancelOperation(nil)
        #expect(!model.capturesScroll)
        #expect(model.zoom == 1)
    }

    @Test("Diagram actions are discoverable without pointer hover")
    @available(macOS 27.0, *)
    func accessibilityActions() {
        _ = NSApplication.shared
        let view = PicoHostedMermaidCanvasView(model: makeModel())
        let actions = view.accessibilityCustomActions()?.map(\.name) ?? []
        #expect(actions.contains("Zoom in"))
        #expect(actions.contains("Zoom out"))
        #expect(actions.contains("Fit width"))
        #expect(actions.contains("Copy source"))
        #expect(view.accessibilityLabel() == "Mermaid diagram")
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func makeModel() -> PicoHostedMermaidModel {
        PicoHostedMermaidModel(svg: svg, source: "flowchart LR\nA-->B\n", language: "mermaid", isClosed: true)
    }

    private func redPixelCount(in view: NSView) throws -> Int {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.8, color.greenComponent < 0.2, color.blueComponent < 0.2 {
                    count += 1
                }
            }
        }
        return count
    }
}

@MainActor
private final class MermaidScrollResponder: NSResponder {
    var scrollEvents = 0
    override func scrollWheel(with event: NSEvent) { scrollEvents += 1 }
}
#endif
