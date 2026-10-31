#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("Mermaid zoom easing")
@MainActor
struct MacMermaidZoomAnimationTests {
    @Test("Cubic ease-out starts fast, tapers and reaches exact vector coordinates", arguments: [1.25, 0.8])
    func easingCoordinates(scale: CGFloat) {
        let from = CGRect(x: 0, y: 0, width: 400, height: 200)
        let to = CGRect(x: 200 - 200 * scale, y: 100 - 100 * scale,
                        width: 400 * scale, height: 200 * scale)
        let transition = PicoVectorZoomAnimation(from: from, to: to)
        #expect(transition.rect(at: 0) == from)
        #expect(transition.rect(at: 1) == to)
        #expect(transition.rect(at: -1) == from)
        #expect(transition.rect(at: 2) == to)
        let midpoint = transition.rect(at: 0.5)
        #expect(midpoint.width == from.width + (to.width - from.width) * 0.875)
        let earlyMovement = abs(transition.rect(at: 0.25).width - from.width)
        let lateMovement = abs(to.width - transition.rect(at: 0.75).width)
        #expect(earlyMovement > lateMovement * 10)
        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let rect = transition.rect(at: progress)
            #expect(rect.width >= min(from.width, to.width) && rect.width <= max(from.width, to.width))
            #expect(rect.width / rect.height == 2)
            #expect(rect.midX == 200 && rect.midY == 100)
        }
        #expect(PicoVectorZoomAnimation.duration == 0.18)
    }

    @Test("Buttons and keyboard update the target immediately and finish vector zoom", .timeLimit(.minutes(1)), arguments: [false, true])
    func immediateTargetAndEventualCompletion(button: Bool) async throws {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        let start = fixture.model.drawingRect(in: fixture.view.bounds.size)
        let revision = fixture.model.presentationRevision
        let parseCount = fixture.model.parseCount
        try zoomIn(fixture.view, button: button)
        #expect(fixture.model.zoom == 1.25)
        #expect(fixture.view.presentedDrawingRect == start, "Animation begins at the current drawing, without a jump")
        let target = fixture.model.drawingRect(in: fixture.view.bounds.size)
        #expect(target != start)
        await fixture.view.waitForZoomAnimation()
        #expect(fixture.view.presentedDrawingRect == nil)
        #expect(fixture.model.drawingRect(in: fixture.view.bounds.size) == target)
        #expect(fixture.model.presentationRevision == revision + 1,
                "Animation frames must not republish Markdown or model state")
        #expect(fixture.model.parseCount == parseCount, "Every frame redraws the same parsed vector document")
    }

    @Test("Rapid repeated zoom keeps its current presentation and compounds the target")
    func repeatedZoomStartsFromCurrentDrawing() throws {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        try zoomIn(fixture.view, button: false)
        let presented = try #require(fixture.view.presentedDrawingRect)
        try zoomIn(fixture.view, button: true)
        #expect(fixture.model.zoom == 1.5625)
        #expect(fixture.view.presentedDrawingRect == presented,
                "Replacing a pending animation must begin at its currently presented rectangle")
    }

    enum Interruption: CaseIterable { case resize, detach, source, drawing, drag, pan, gesture, reset }

    @Test("Geometry and interaction changes interrupt zoom without changing streaming", arguments: Interruption.allCases)
    func interruptions(_ interruption: Interruption) throws {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        try zoomIn(fixture.view, button: false)
        try #require(fixture.view.presentedDrawingRect != nil)
        switch interruption {
        case .resize:
            fixture.view.frame.size.width = 500
            fixture.view.layout()
        case .detach:
            fixture.window.contentView = nil
        case .source:
            fixture.model.update(svg: Self.svg, source: "flowchart LR\n A --> B\n B --> C\n",
                                 language: "mermaid", isClosed: false)
        case .drawing:
            fixture.model.update(svg: Self.svg.replacingOccurrences(of: "#ff0000", with: "#0000ff"),
                                 source: fixture.model.source, language: "mermaid", isClosed: true)
        case .drag:
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 50, y: 50),
                                                      modifierFlags: [], timestamp: 0,
                                                      windowNumber: fixture.window.windowNumber, context: nil,
                                                      eventNumber: 0, clickCount: 1, pressure: 0))
            fixture.view.mouseDown(with: event)
        case .pan:
            #expect(fixture.model.pan(by: CGPoint(x: 10, y: 5)))
        case .gesture:
            fixture.model.zoom(by: 1.1)
        case .reset:
            fixture.view.keyDown(with: try key("0", window: fixture.window))
            #expect(fixture.model.zoom == 1)
        }
        #expect(fixture.view.presentedDrawingRect == nil)
    }

    @Test("Reduce Motion and detached canvases apply the zoom immediately", arguments: [false, true])
    func immediateWithoutMotion(detached: Bool) throws {
        let fixture = makeFixture(reducesMotion: { !detached })
        defer { fixture.window.close() }
        if detached { fixture.window.contentView = nil }
        try zoomIn(fixture.view, button: false)
        #expect(fixture.model.zoom == 1.25)
        #expect(fixture.view.presentedDrawingRect == nil)
    }

    @Test("Enabling Reduce Motion interrupts a running zoom", .timeLimit(.minutes(1)))
    func motionPreferenceChange() async throws {
        var reduceMotion = false
        let fixture = makeFixture(reducesMotion: { reduceMotion })
        defer { fixture.window.close() }
        try zoomIn(fixture.view, button: false)
        try #require(fixture.view.presentedDrawingRect != nil)
        reduceMotion = true
        await fixture.view.waitForZoomAnimation()
        #expect(fixture.view.presentedDrawingRect == nil)
        #expect(fixture.model.zoom == 1.25)
    }

    private static let svg = "<svg width=\"400\" height=\"200\"><rect width=\"400\" height=\"200\" fill=\"#ff0000\"/></svg>"

    private func makeFixture(reducesMotion: @escaping @MainActor () -> Bool = { false })
        -> (window: NSWindow, view: PicoHostedVectorCanvasView, model: PicoHostedVectorModel) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let model = PicoHostedVectorModel(svg: Self.svg, source: "flowchart LR\n A --> B\n",
                                          language: "mermaid", isClosed: true)
        let view = PicoHostedVectorCanvasView(model: model, reducesMotion: reducesMotion)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (window, view, model)
    }

    private func zoomIn(_ view: PicoHostedVectorCanvasView, button: Bool) throws {
        if button {
            let control = try #require(descendants(of: view).compactMap { $0 as? NSSegmentedControl }.first)
            let mode = control.trackingMode
            defer { control.selectedSegment = -1; control.trackingMode = mode }
            // Native event tracking can stop Swift's async-main run loop.
            // Dispatch the real action with the segment selected instead.
            control.trackingMode = .selectOne
            control.selectedSegment = 1
            #expect(control.sendAction(control.action, to: control.target))
        } else {
            view.keyDown(with: try key("+", window: view.window))
        }
    }

    private func key(_ character: String, window: NSWindow?) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window?.windowNumber ?? 0, context: nil,
                                     characters: character, charactersIgnoringModifiers: character,
                                     isARepeat: false, keyCode: 24))
    }

    private func descendants(of view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants(of: $0) } }
}
#endif
