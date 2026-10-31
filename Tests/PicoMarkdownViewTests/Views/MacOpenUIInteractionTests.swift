#if os(macOS)
import AppKit
import Testing
@preconcurrency import WebKit
@testable import PicoMarkdownView

@Suite("OpenUI internal scrolling and link actions", .serialized)
@MainActor
struct MacOpenUIInteractionTests {
    @Test("TextContent links reach the app once without navigating the child", .timeLimit(.minutes(1)))
    func textContentLinksAreActions() async throws {
        let fixture = try await OpenUIInteractionFixture(source:
            #"root = TextContent("[Read documentation](https://example.com/docs?q=1&lang=en)")"#)
        defer { fixture.close() }
        var actions: [PicoOpenUIActionEvent] = []
        fixture.model.onAction = { actions.append($0) }
        let originalURL = fixture.browser.url
        let renders = fixture.model.renderCount
        _ = try await fixture.waitFor("TextContent link is present", script: "return {ready:!!document.querySelector('a[href]')};") {
            ($0["ready"] as? Bool) == true
        }
        _ = try await fixture.evaluate("document.querySelector('a[href]').click(); return true;")
        try await fixture.waitUntil("The host receives the link action") { actions.count == 1 }
        let action = try #require(actions.first)
        #expect(action.type == "open_url")
        #expect(action.params["url"] == .string("https://example.com/docs?q=1&lang=en"))
        #expect(action.humanFriendlyMessage == "Read documentation")
        #expect(fixture.browser.url == originalURL)
        #expect(fixture.model.renderCount == renders && fixture.model.webViewCreationCount == 1)
        #expect(fixture.model.error == nil)
    }

    @Test("Stock modal scrolling stays in WebKit until its directional edge", .timeLimit(.minutes(1)))
    func modalScrollRegionsReachNativeRouting() async throws {
        let paragraphs = (1...35).map { "Detail row \($0) with information for the form." }.joined(separator: "\n\n")
        let encoded = try String(decoding: JSONEncoder().encode(paragraphs), as: UTF8.self)
        let source = "root = Stack([TextContent(\"Scroll example\"), Modal(\"Scrollable details\", true, [TextContent(\(encoded))], \"sm\")])"
        let fixture = try await OpenUIInteractionFixture(source: source)
        defer { fixture.close() }
        let renders = fixture.model.renderCount
        let geometry = try await fixture.waitFor("Stock modal body overflows", script: """
            const body = document.querySelector('.openui-modal-body');
            if (!body) return null;
            const r = body.getBoundingClientRect();
            return {x:r.x, y:r.y, width:r.width, height:r.height,
                    scrollHeight:body.scrollHeight, clientHeight:body.clientHeight};
            """) { ($0["scrollHeight"] as? Double ?? 0) > ($0["clientHeight"] as? Double ?? 0) }
        let x = try #require(geometry["x"] as? Double)
        let y = try #require(geometry["y"] as? Double)
        let width = try #require(geometry["width"] as? Double)
        let height = try #require(geometry["height"] as? Double)
        let cssPoint = CGPoint(x: x + width / 2, y: y + height / 2)
        try await fixture.waitUntil("Scrollable body geometry reaches native code") {
            fixture.model.scrollRegions.contains { $0.rect.contains(cssPoint) && $0.canScrollDown }
        }
        #expect(!fixture.browser.forwardVerticalWheel(fixture.event(cssPoint: cssPoint, y: -12, phase: .began)),
                "A downward wheel over the modal must remain with WebKit")
        #expect(!fixture.browser.forwardVerticalWheel(fixture.event(cssPoint: cssPoint, phase: .ended)))
        #expect(fixture.scroll.received == 0)
        _ = try await fixture.evaluate("""
            const body = document.querySelector('.openui-modal-body');
            body.scrollTop = body.scrollHeight;
            return body.scrollTop;
            """)
        try await fixture.waitUntil("The native map reflects the modal's bottom edge") {
            fixture.model.scrollRegions.contains { $0.rect.contains(cssPoint) && $0.canScrollUp && !$0.canScrollDown }
        }
        #expect(fixture.browser.forwardVerticalWheel(fixture.event(cssPoint: cssPoint, y: -12, phase: .began)),
                "A new downward gesture at the bottom edge belongs to the transcript")
        #expect(fixture.browser.forwardVerticalWheel(fixture.event(cssPoint: cssPoint, phase: .ended)))
        #expect(fixture.scroll.received == 2)
        #expect(!fixture.browser.forwardVerticalWheel(fixture.event(cssPoint: cssPoint, y: 12, phase: .began)),
                "An upward gesture can still scroll back through the modal")
        #expect(!fixture.browser.forwardVerticalWheel(fixture.event(cssPoint: cssPoint, phase: .ended)))
        #expect(fixture.model.renderCount == renders && fixture.model.webViewCreationCount == 1)
        #expect(fixture.model.error == nil)
    }
}

@MainActor
private final class OpenUIInteractionFixture {
    let model: PicoHostedOpenUIModel
    let browser: PicoHostedOpenUIWebView
    let scroll = OpenUIInteractionScrollView()
    let window: NSWindow

    init(source: String) async throws {
        _ = NSApplication.shared
        model = PicoHostedOpenUIModel(source: source, language: "openui")
        browser = try #require(model.makeWebView() as? PicoHostedOpenUIWebView)
        let document = OpenUIInteractionDocument(frame: CGRect(x: 0, y: 0, width: 620, height: 1400))
        scroll.frame = CGRect(x: 0, y: 0, width: 620, height: 600)
        scroll.documentView = document
        browser.frame = CGRect(x: 0, y: 0, width: 600, height: 350)
        document.addSubview(browser)
        window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        do {
            try await waitUntil("The web runtime starts") { self.model.isReady && self.model.sizeMessageCount > 0 }
        } catch { close(); throw error }
    }

    func evaluate(_ script: String) async throws -> Any? {
        try await browser.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            window.contentView?.layoutSubtreeIfNeeded()
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out: \(description)")
                throw InteractionTimeout()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitFor(_ description: String, script: String,
                 condition: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            if let result = try await evaluate(script) as? [String: Any], condition(result) { return result }
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out: \(description)")
                throw InteractionTimeout()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func event(cssPoint: CGPoint, y: CGFloat = 0, phase: NSEvent.Phase) -> NSEvent {
        let point = CGPoint(x: cssPoint.x * model.textScale, y: cssPoint.y * model.textScale)
        return OpenUIInteractionEvent(window: window, point: browser.convert(point, to: nil), y: y, phase: phase)
    }

    func close() { model.dispose(); window.close() }
    private struct InteractionTimeout: Error {}
}

@MainActor
private final class OpenUIInteractionDocument: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class OpenUIInteractionScrollView: NSScrollView {
    var received = 0
    override func scrollWheel(with event: NSEvent) { received += 1 }
}

private final class OpenUIInteractionEvent: NSEvent {
    private let targetWindow: NSWindow
    private let point: NSPoint
    private let y: CGFloat
    private let gesturePhase: NSEvent.Phase
    init(window: NSWindow, point: NSPoint, y: CGFloat, phase: NSEvent.Phase) {
        targetWindow = window
        self.point = point
        self.y = y
        gesturePhase = phase
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Tests supply their own wheel event") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { targetWindow }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { y }
    override var phase: NSEvent.Phase { gesturePhase }
    override var momentumPhase: NSEvent.Phase { [] }
}
#endif
