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
        let model = PicoHostedVectorModel(svg: "<svg width=\"100\" height=\"400\"><rect width=\"100\" height=\"400\"/></svg>",
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
        let model = PicoHostedVectorModel(svg: svg, source: source, language: "mermaid title=Demo", isClosed: false)
        let markdown = model.markdownRepresentation()
        #expect(markdown == "`````mermaid title=Demo\n" + source + "`````")
        model.zoom(by: 4)
        model.toggleExpanded()
        #expect(model.markdownRepresentation() == markdown)
        #expect(model.source == source)
        let tilde = PicoHostedVectorModel(svg: svg, source: "A[~~~]", language: "mermaid title=`Demo`", isClosed: true)
        #expect(tilde.markdownRepresentation().hasPrefix("~~~~mermaid title=`Demo`\n"))
    }

    @Test("Native vector canvas redraws geometry at the requested zoom")
    @available(macOS 27.0, *)
    func redrawsVectorsAtZoom() throws {
        _ = NSApplication.shared
        let model = makeModel()
        let view = PicoHostedVectorCanvasView(model: model)
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
        let model = PicoHostedVectorModel(svg: "<svg width=\"200\" height=\"100\"><rect width=\"200\" height=\"100\" fill=\"#ff0000\"/></svg>",
                                           source: "flowchart LR\nA-->B", language: "mermaid", isClosed: true)
        let view = PicoHostedVectorCanvasView(model: model)
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
            PicoHostedVectorView(model: model, context: context)
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
        let canvas = try #require(descendants(of: hosting).compactMap { $0 as? PicoHostedVectorCanvasView }.first)
        canvas.layoutSubtreeIfNeeded()
        let (zoom, copy) = try diagramControls(in: canvas)
        for control in [zoom, copy] as [NSView] {
            let frame = control.convert(control.bounds, to: canvas)
            #expect(frame.width > 0 && frame.height > 0)
            #expect(canvas.bounds.contains(frame), "Controls fit after the attachment receives its actual width")
        }
        try activateZoomSegment(1, in: zoom)
        #expect(model.zoom > 1, "Controls still act on the same model after startup sizing")
        #expect(canvas.model === model)
        #expect(model.parseCount == 1)
        #expect(attachment.markdownRepresentation() == model.markdownRepresentation())
    }

    @Test("Narrow diagrams keep zoom connected and wrap Copy only when needed", arguments: [CGFloat(80), CGFloat(120), CGFloat(200)])
    @available(macOS 27.0, *)
    func controlsWrapAtNarrowWidths(width: CGFloat) throws {
        _ = NSApplication.shared
        let model = makeModel()
        let view = PicoHostedVectorCanvasView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: width, height: 140)
        view.layoutSubtreeIfNeeded()
        let (zoom, copy) = try diagramControls(in: view)
        let controls = [zoom, copy] as [NSView]
        let frames = controls.map { control in
            let alignment = control.alignmentRect(forFrame: control.frame)
            return control.superview?.convert(alignment, to: view) ?? .zero
        }
        for control in controls {
            #expect(view.bounds.contains(control.convert(control.bounds, to: view)),
                    "The complete native control remains inside a narrow diagram")
        }
        for frame in frames {
            #expect(view.bounds.contains(frame), "Every action remains inside a narrow diagram")
            #expect(frame.width >= 32 && frame.height >= 32)
        }
        #expect(frames[0].width == 64, "Zoom out and in remain one connected control")
        #expect(frames[1].width == 32)
        #expect(Set(frames.map(\.minY)).count == (width == 80 ? 2 : 1))
        if width >= 120 {
            #expect(frames[1].minX - frames[0].maxX == 8, "Copy remains a separate control")
        }
        #expect(controls.allSatisfy { !isControlVisible($0, in: view) })
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
                                                       modifierFlags: [], timestamp: 0,
                                                       windowNumber: 0, context: nil,
                                                       eventNumber: 0, trackingNumber: 0, userData: nil))
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
                                                      modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil,
                                                      eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseEntered(with: enter)
        #expect(controls.allSatisfy { isControlVisible($0, in: view) })
        try activateZoomSegment(1, in: zoom)
        #expect(model.zoom > 1)
        #expect(isControlVisible(zoom, in: view))
        try activateZoomSegment(0, in: zoom)
        #expect(model.zoom == 1)
        view.mouseExited(with: exit)
        #expect(controls.allSatisfy { !isControlVisible($0, in: view) })
        for control in controls {
            #expect(control.hitTest(CGPoint(x: control.frame.midX, y: control.frame.midY)) == nil,
                    "Hidden controls do not intercept pointer selection")
        }
    }

    @Test("Zoom segments respect their limits and keyboard reset remains available")
    @available(macOS 27.0, *)
    func zoomLimitsAndKeyboardReset() throws {
        _ = NSApplication.shared
        let model = makeModel()
        let view = PicoHostedVectorCanvasView(model: model)
        let (zoom, _) = try diagramControls(in: view)
        model.zoom(by: 100)
        #expect(model.zoom == 8)
        #expect(zoom.isEnabled(forSegment: 0))
        #expect(!zoom.isEnabled(forSegment: 1))
        try activateZoomSegment(0, in: zoom)
        #expect(model.zoom < 8)
        #expect(zoom.isEnabled(forSegment: 1))
        model.zoom(by: 0.001)
        #expect(model.zoom == 0.25)
        #expect(!zoom.isEnabled(forSegment: 0))
        #expect(zoom.isEnabled(forSegment: 1))
        try activateZoomSegment(1, in: zoom)
        #expect(model.zoom > 0.25)
        #expect(zoom.isEnabled(forSegment: 0))
        let zero = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "0", charactersIgnoringModifiers: "0",
                                                isARepeat: false, keyCode: 29))
        view.keyDown(with: zero)
        #expect(model.zoom == 1)
        try activateZoomSegment(1, in: zoom)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: 0, context: nil,
                                                  characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                  isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        #expect(model.zoom == 1)
    }

    @Test("Wheel scroll passes to the transcript until zoomed, and chains at a pan boundary")
    @available(macOS 27.0, *)
    func wheelRouting() throws {
        _ = NSApplication.shared
        let model = makeModel()
        let view = PicoHostedVectorCanvasView(model: model)
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

    @Test("Diagram controls expose labels, detailed tooltips and accessible actions without hover")
    @available(macOS 27.0, *)
    func accessibilityActions() throws {
        _ = NSApplication.shared
        let view = PicoHostedVectorCanvasView(model: makeModel())
        let actions = view.accessibilityCustomActions()?.map(\.name) ?? []
        #expect(Set(actions) == Set(["Zoom in", "Zoom out", "Copy Mermaid", "Copy source"]),
                "Fit, fit-width and expand actions are no longer exposed")
        #expect(view.accessibilityLabel() == "Mermaid diagram")
        let (zoom, copy) = try diagramControls(in: view)
        #expect(zoom.segmentCount == 2)
        #expect(zoom.trackingMode == .momentary)
        #expect(zoom.image(forSegment: 0)?.accessibilityDescription == "Zoom out")
        #expect(zoom.image(forSegment: 1)?.accessibilityDescription == "Zoom in")
        #expect(zoom.toolTip(forSegment: 0)?.contains("Zoom out") == true)
        #expect(zoom.toolTip(forSegment: 1)?.contains("Zoom in") == true)
        for segment in 0..<2 {
            #expect(zoom.toolTip(forSegment: segment)?.contains("Escape") == true)
        }
        #expect(zoom.accessibilityLabel() == "Diagram zoom")
        #expect(zoom.accessibilityHelp()?.contains("diagram frame") == true)
        #expect(copy.accessibilityLabel() == "Copy Mermaid")
        #expect(copy.image?.accessibilityDescription == "Copy Mermaid")
        #expect(copy.toolTip?.contains("code fences") == true)
        #expect(copy.accessibilityHelp()?.contains("code fences") == true)
        #expect(copy.bezelStyle == .glass)
        #expect(zoom.cell?.isBordered == true)
        #expect(zoom.segmentStyle == .rounded)
        #expect(zoom.borderShape == .capsule)
    }

    @Test("Pointer navigation does not keep controls visible after hover ends")
    @available(macOS 27.0, *)
    func pointerFocusDoesNotLatchControls() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let model = makeModel()
        let view = PicoHostedVectorCanvasView(model: model)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let (zoom, copy) = try diagramControls(in: view)
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
                                                       modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       eventNumber: 0, trackingNumber: 0, userData: nil))
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
                                                      modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseEntered(with: enter)
        #expect(isControlVisible(zoom, in: view))
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 100, y: 100),
                                                   modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 0))
        view.mouseDown(with: click)
        view.mouseExited(with: exit)
        #expect(window.firstResponder === view, "Panning may retain the responder for keyboard navigation")
        #expect(!isControlVisible(zoom, in: view), "Pointer focus must not latch the toolbar open")
        #expect(zoom.hitTest(CGPoint(x: zoom.frame.midX, y: zoom.frame.midY)) == nil, "Hidden controls do not intercept pointer selection")

        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: "+", charactersIgnoringModifiers: "+",
                                               isARepeat: false, keyCode: 24))
        view.keyDown(with: key)
        #expect(isControlVisible(zoom, in: view), "Keyboard navigation reveals its controls")
        #expect(model.zoom > 1)
        #expect(window.makeFirstResponder(nil))
        #expect(!isControlVisible(zoom, in: view))
        #expect(window.makeFirstResponder(zoom), "Keyboard focus can reach the connected zoom control")
        #expect(isControlVisible(zoom, in: view) && isControlVisible(copy, in: view))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                  characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                  isARepeat: false, keyCode: 53))
        zoom.keyDown(with: escape)
        #expect(model.zoom == 1, "Escape resets zoom even while a zoom segment has keyboard focus")
        #expect(!isControlVisible(zoom, in: view) && !isControlVisible(copy, in: view))
        #expect(view.accessibilityCustomActions()?.contains { $0.name == "Copy source" } == true)
    }

    @Test("Detaching a hovered diagram clears stale toolbar visibility")
    @available(macOS 27.0, *)
    func detachingClearsHover() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = PicoHostedVectorCanvasView(model: makeModel())
        window.contentView = view
        let (zoom, copy) = try diagramControls(in: view)
        let controls = [zoom, copy] as [NSView]
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
                                                       modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseEntered(with: enter)
        #expect(controls.allSatisfy { isControlVisible($0, in: view) })
        window.contentView = nil
        for control in controls {
            #expect(!isControlVisible(control, in: view))
            #expect(control.hitTest(CGPoint(x: control.frame.midX, y: control.frame.midY)) == nil)
        }
    }

    private func diagramControls(in view: NSView) throws -> (NSSegmentedControl, NSButton) {
        let views = descendants(of: view)
        let zoom = views.compactMap { $0 as? NSSegmentedControl }
        let copy = views.compactMap { $0 as? NSButton }
        #expect(zoom.count == 1)
        #expect(copy.count == 1, "Only Copy remains a standalone button")
        return try (#require(zoom.first), #require(copy.first))
    }

    private func activateZoomSegment(_ segment: Int, in control: NSSegmentedControl) throws {
        let action = try #require(control.action)
        let target = try #require(control.target)
        try #require(control.isEnabled(forSegment: segment))
        // Native AX press stops AppKit's tracking run loop and can exit Swift's async-main test host.
        // Exercise the real target/action without it: https://github.com/swiftlang/swift/issues/91716
        let trackingMode = control.trackingMode
        control.trackingMode = .selectOne
        defer {
            control.selectedSegment = -1
            control.trackingMode = trackingMode
        }
        control.selectedSegment = segment
        #expect(control.sendAction(action, to: target))
    }

    private func isControlVisible(_ control: NSView, in canvas: NSView) -> Bool {
        var current: NSView? = control
        while let view = current, view !== canvas {
            if view.isHidden || view.alphaValue == 0 { return false }
            current = view.superview
        }
        return current === canvas
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func makeModel() -> PicoHostedVectorModel {
        PicoHostedVectorModel(svg: svg, source: "flowchart LR\nA-->B\n", language: "mermaid", isClosed: true)
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
