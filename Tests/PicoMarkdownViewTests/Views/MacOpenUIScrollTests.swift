#if os(macOS)
import AppKit
import Testing
@preconcurrency import WebKit
@testable import PicoMarkdownView

@Suite("macOS OpenUI transcript scroll routing", .serialized)
@MainActor
struct MacOpenUIScrollTests {
    @Test("A vertical gesture forwards zero-delta endings and momentum to the transcript")
    func verticalTerminalPhases() {
        let fixture = OpenUIScrollFixture()
        defer { fixture.close() }
        fixture.browser.scrollWheel(with: fixture.event(y: -12, phase: .began))
        fixture.browser.scrollWheel(with: fixture.event(y: -8, phase: .changed))
        fixture.browser.scrollWheel(with: fixture.event(phase: .ended))
        fixture.browser.scrollWheel(with: fixture.event(momentum: .began))
        fixture.browser.scrollWheel(with: fixture.event(y: -5, momentum: .changed))
        fixture.browser.scrollWheel(with: fixture.event(momentum: .ended))
        #expect(fixture.scroll.phases == [.began, .changed, .ended, [], [], []])
        #expect(fixture.scroll.momenta == [[], [], [], .began, .changed, .ended])
        fixture.browser.scrollWheel(with: fixture.event(y: -6, phase: .began))
        fixture.browser.scrollWheel(with: fixture.event(phase: .cancelled))
        #expect(fixture.scroll.phases.suffix(2) == [.began, .cancelled])
    }

    @Test("Horizontal and shift-wheel gestures remain with web content")
    func horizontalIsPreserved() {
        let fixture = OpenUIScrollFixture()
        defer { fixture.close() }
        #expect(!fixture.browser.forwardVerticalWheel(fixture.event(x: -12, phase: .began)))
        #expect(!fixture.browser.forwardVerticalWheel(fixture.event(x: -8, phase: .changed)))
        #expect(!fixture.browser.forwardVerticalWheel(fixture.event(phase: .ended)))
        #expect(!fixture.browser.forwardVerticalWheel(fixture.event(momentum: .began)))
        #expect(!fixture.browser.forwardVerticalWheel(fixture.event(x: -4, momentum: .changed)))
        #expect(!fixture.browser.forwardVerticalWheel(fixture.event(momentum: .ended)))
        #expect(!fixture.browser.forwardVerticalWheel(fixture.event(y: -10, phase: .began, modifiers: .shift)))
        #expect(!fixture.browser.forwardVerticalWheel(fixture.event(phase: .ended, modifiers: .shift)))
        #expect(fixture.scroll.phases.isEmpty)
        fixture.browser.scrollWheel(with: fixture.event(y: -9, phase: .began))
        fixture.browser.scrollWheel(with: fixture.event(phase: .ended))
        #expect(fixture.scroll.phases == [.began, .ended], "The next vertical gesture chooses its own axis")
    }

    @Test("Disposal stops forwarding and unregisters the visible browser")
    func stoppedBrowserUnregisters() {
        let initialCount = PicoHostedOpenUIWebView.registeredScrollHostCount
        let fixture = OpenUIScrollFixture()
        defer { fixture.close() }
        #expect(PicoHostedOpenUIWebView.registeredScrollHostCount == initialCount + 1)
        fixture.browser.scrollWheel(with: fixture.event(y: -10, phase: .began))
        fixture.browser.stopForwardingScroll()
        #expect(PicoHostedOpenUIWebView.registeredScrollHostCount == initialCount)
        #expect(!fixture.browser.forwardVerticalWheel(fixture.event(phase: .ended)))
        #expect(!fixture.browser.forwardVerticalWheel(fixture.event(y: -10, phase: .began)))
        fixture.browser.stopForwardingScroll()
        #expect(PicoHostedOpenUIWebView.registeredScrollHostCount == initialCount)
        #expect(fixture.scroll.phases == [.began])
    }
}

@MainActor
private final class OpenUIScrollFixture {
    let window: NSWindow
    let scroll = OpenUIRecordingScrollView()
    let browser: PicoHostedOpenUIWebView

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 560, height: 400),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 560, height: 1_000))
        scroll.documentView = document
        window.contentView = scroll
        browser = PicoHostedOpenUIWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 300),
                                         configuration: WKWebViewConfiguration())
        document.addSubview(browser)
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func event(x: CGFloat = 0, y: CGFloat = 0, phase: NSEvent.Phase = [],
               momentum: NSEvent.Phase = [], modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        OpenUIScrollTestEvent(window: window, point: browser.convert(CGPoint(x: 100, y: 100), to: nil),
                             x: x, y: y, phase: phase, momentum: momentum, modifiers: modifiers)
    }

    func close() {
        browser.stopForwardingScroll()
        browser.stopLoading()
        browser.removeFromSuperview()
        window.close()
    }
}

@MainActor
private final class OpenUIRecordingScrollView: NSScrollView {
    var phases: [NSEvent.Phase] = []
    var momenta: [NSEvent.Phase] = []
    override func scrollWheel(with event: NSEvent) {
        phases.append(event.phase)
        momenta.append(event.momentumPhase)
    }
}

private final class OpenUIScrollTestEvent: NSEvent {
    private let targetWindow: NSWindow
    private let point: NSPoint
    private let x: CGFloat
    private let y: CGFloat
    private let gesturePhase: NSEvent.Phase
    private let momentum: NSEvent.Phase
    private let modifiers: NSEvent.ModifierFlags

    init(window: NSWindow, point: NSPoint, x: CGFloat, y: CGFloat,
         phase: NSEvent.Phase, momentum: NSEvent.Phase, modifiers: NSEvent.ModifierFlags) {
        targetWindow = window
        self.point = point
        self.x = x
        self.y = y
        gesturePhase = phase
        self.momentum = momentum
        self.modifiers = modifiers
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("Tests supply their own scroll event") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { targetWindow }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaX: CGFloat { x }
    override var scrollingDeltaY: CGFloat { y }
    override var phase: NSEvent.Phase { gesturePhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var modifierFlags: NSEvent.ModifierFlags { modifiers }
}
#endif
