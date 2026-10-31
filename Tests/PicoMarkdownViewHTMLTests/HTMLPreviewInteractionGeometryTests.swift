#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import PicoMarkdownViewHTML

@MainActor
@Suite("HTML interaction geometry", .serialized, .timeLimit(.minutes(1)))
struct HTMLPreviewInteractionGeometryTests {
    @Test("State changes remeasure translated content and restore its original height", arguments: [
        "pointerover", "pointerout", "pointerdown", "pointerup", "pointercancel", "focusin", "focusout", "keydown", "keyup", "window:focus", "window:blur"
    ])
    func interactionRemeasuresWithoutReload(event: String) async throws {
        let fixture = GeometryPreviewFixture(declaration: "transform:translateY(200px)")
        defer { fixture.close() }
        let page = try await fixture.readyPage()
        let initialHeight = fixture.view.measuredHeight
        try #require(initialHeight == 20)
        try await fixture.activate(true, event: event, page: page)
        #expect(fixture.view.measuredHeight == 220)
        #expect(fixture.view.page === page && fixture.view.loadCount == 1)
        #expect(fixture.view.isReady && !fixture.view.hasFailed)
        let result = try await page.callJavaScript("""
            await new Promise(resolve => setTimeout(resolve, 0));
            const probe = document.getElementById('probe');
            const rect = probe.getBoundingClientRect();
            return { top:rect.top, bottom:rect.bottom, viewport:innerHeight,
                     painted:document.elementFromPoint(rect.left + 10, rect.top + 10) === probe };
            """, contentWorld: .defaultClient) as? [String: Any]
        let geometry = try #require(result)
        #expect(geometry["top"] as? Double == 200)
        #expect(geometry["bottom"] as? Double == 220)
        #expect((geometry["viewport"] as? Double ?? 0) >= 220)
        #expect(geometry["painted"] as? Bool == true)
        try await fixture.activate(false, event: event, page: page)
        #expect(fixture.view.measuredHeight == initialHeight)
        #expect(fixture.view.page === page && fixture.view.loadCount == 1)
    }

    @Test("State changes with inaccessible geometry use source fallback", arguments: [
        "transform:translateY(-40px)", "transform:translateX(500px)", "position:fixed;top:0", "transform:translateY(5000px)"
    ])
    func interactionRetainsUnsupportedLayoutFallback(declaration: String) async throws {
        let fixture = GeometryPreviewFixture(declaration: declaration)
        defer { fixture.close() }
        let page = try await fixture.readyPage()
        do {
            try await fixture.activate(true, event: "pointerover", page: page)
        } catch {
            // Source fallback tears down the page while its evaluation may
            // still be completing. The native terminal state is the contract.
            #expect(fixture.view.hasFailed)
        }
        await fixture.view.pendingFailureNotification?.value
        #expect(fixture.view.hasFailed && !fixture.view.isReady)
        #expect(fixture.failures == 1)
        #expect(fixture.view.page == nil && fixture.view.loadCount == 1)
    }
}

@MainActor
private final class GeometryPreviewFixture {
    let view = HTMLPreviewContainer()
    let window: NSWindow
    private(set) var failures = 0
    private let outcome = AsyncStream.makeStream(of: Bool.self)

    init(declaration: String) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 400, height: 80),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        view.onReady = { [outcome] in outcome.continuation.yield(true); outcome.continuation.finish() }
        view.onFailure = { [weak self, outcome] in
            self?.failures += 1
            outcome.continuation.yield(false)
            outcome.continuation.finish()
        }
        view.onHeight = { [weak window] height in window?.setContentSize(NSSize(width: 400, height: height)) }
        view.configure(source: """
            <style>
              #probe { height:20px;line-height:20px; }
              body:hover #probe, body.pico-test-state #probe { \(declaration); }
            </style><div id='probe'>Report</div>
            """, style: .default)
        window.contentView = view
        window.orderFront(nil)
    }

    func readyPage() async throws -> WebPage {
        var events = outcome.stream.makeAsyncIterator()
        try #require(await events.next() == true)
        return try #require(view.page)
    }

    func activate(_ enabled: Bool, event: String, page: WebPage) async throws {
        // Inactive CLI windows cannot reliably establish native :hover. The
        // paired class activates the same declaration, then its actual DOM
        // interaction route schedules measurement after the style change.
        _ = try await page.callJavaScript("""
            document.body.classList.toggle('pico-test-state', enabled);
            const target = eventName.startsWith('window:') ? window : document.body;
            target.dispatchEvent(new Event(eventName.replace('window:', ''), { bubbles:true }));
            await new Promise(resolve => setTimeout(() => setTimeout(resolve, 0), 0));
            return true;
            """, arguments: ["enabled": enabled, "eventName": event], contentWorld: .defaultClient)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func close() {
        view.onReady = nil
        view.onFailure = nil
        view.onHeight = nil
        outcome.continuation.finish()
        view.suspend()
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }
}
#endif
