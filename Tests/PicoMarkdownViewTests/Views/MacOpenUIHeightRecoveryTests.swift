#if os(macOS)
import AppKit
import SwiftUI
import Testing
@preconcurrency import WebKit
@testable import PicoMarkdownView

@Suite("Hosted OpenUI height fallback recovery", .serialized)
@MainActor
struct MacOpenUIHeightRecoveryTests {
    @Test("Widening a height fallback restores the same browser and entered field state", .timeLimit(.minutes(2)))
    func availableWidthRecoversDetachedBrowser() async throws {
        let text = String(repeating: "word ", count: 8_000)
        let source = "root = Stack([Input(\"notes\", \"Keep state\", \"text\"), TextContent(\"" + text + "\")])"
        #expect(source.utf8.count < 100_000)
        let fixture = OpenUIHeightRecoveryFixture(source: source, width: 760)
        defer { fixture.close() }
        try await fixture.waitUntil("The wide child renders within its supported height") {
            fixture.model.isReady && fixture.model.sizeMessageCount > 0 && fixture.model.error == nil
                && fixture.model.webView?.window === fixture.window
        }
        _ = try await fixture.evaluate("await document.fonts.ready; return true;")
        _ = try await fixture.waitForGeometry("The initial wide DOM has its measured native height") { geometry in
            guard let cssHeight = geometry["height"] as? Double else { return false }
            let points = max(80, ceil(CGFloat(cssHeight) * fixture.model.textScale))
            return points < PicoHostedOpenUIModel.maximumHeight
                && abs(fixture.model.measuredHeight - points) <= 2
                && geometry["hasInput"] as? Bool == true
        }
        let browser = try #require(fixture.model.webView)
        let sourceID = fixture.model.sourceID
        let renderCount = fixture.model.renderCount
        let entered = "Keep 🧭 state through fallback"
        _ = try await fixture.evaluate("""
            const input = document.querySelector('input[name="notes"]');
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, value);
            input.dispatchEvent(new Event('input', {bubbles:true}));
            input.dispatchEvent(new Event('change', {bubbles:true}));
            input.dispatchEvent(new FocusEvent('blur', {bubbles:true}));
            return input.value;
            """, arguments: ["value": entered])
        #expect(fixture.model.webViewCreationCount == 1)

        fixture.resize(to: 180)
        try await fixture.waitUntil("Narrow wrapping enters the height fallback and detaches its browser") {
            fixture.model.error?.contains("too tall") == true
                && browser.window == nil && !browser.isDescendant(of: fixture.host)
        }
        let narrow = try await fixture.geometry()
        let narrowHeight = try #require(narrow["height"] as? Double)
        #expect(narrowHeight * Double(fixture.model.textScale) > Double(PicoHostedOpenUIModel.maximumHeight))
        #expect(abs((narrow["width"] as? Double ?? 0) - 180 / Double(fixture.model.textScale)) <= 2,
                "The retained, detached browser still exposes its actual narrow CSS viewport")
        #expect(narrow["value"] as? String == entered)
        #expect(fixture.model.webView === browser)
        #expect(fixture.model.renderCount == renderCount)

        // The fallback has no NSViewRepresentable browser to resize. Only the
        // context width change can reach and reflow the retained offscreen WK.
        fixture.resize(to: 760)
        try await fixture.waitUntil("Wider available width recovers and remounts the original child") {
            fixture.model.error == nil && browser.window === fixture.window
                && browser.isDescendant(of: fixture.host)
                && fixture.model.measuredHeight <= PicoHostedOpenUIModel.maximumHeight
        }
        let recovered = try await fixture.waitForGeometry("The recovered wide DOM and native height agree") { geometry in
            guard let cssHeight = geometry["height"] as? Double,
                  let width = geometry["width"] as? Double else { return false }
            let points = max(80, ceil(CGFloat(cssHeight) * fixture.model.textScale))
            return points <= PicoHostedOpenUIModel.maximumHeight
                && abs(fixture.model.measuredHeight - points) <= 2
                && abs(width - 760 / Double(fixture.model.textScale)) <= 2
        }
        #expect(recovered["value"] as? String == entered)
        #expect(fixture.model.webView === browser)
        #expect(fixture.model.source == source && fixture.model.sourceID == sourceID)
        #expect(fixture.model.webViewCreationCount == 1)
        #expect(fixture.model.renderCount == renderCount,
                "Width recovery must reflow the existing document without another OpenUI source delivery")
    }
}

@MainActor
private final class OpenUIHeightRecoveryFixture {
    let model: PicoHostedOpenUIModel
    let context = PicoHostedAttachmentContext()
    let host: NSHostingView<PicoHostedOpenUIView>
    let scroll: NSScrollView
    let window: NSWindow

    init(source: String, width: CGFloat) {
        _ = NSApplication.shared
        model = PicoHostedOpenUIModel(source: source, language: "openui")
        context.update(availableWidth: width, isSelected: false)
        host = NSHostingView(rootView: PicoHostedOpenUIView(model: model, context: context))
        host.sizingOptions = [.intrinsicContentSize]
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width + 20, height: 700))
        scroll.hasVerticalScroller = true
        scroll.documentView = host
        window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        layout()
    }

    func resize(to width: CGFloat) {
        context.update(availableWidth: width, isSelected: false)
        window.setContentSize(NSSize(width: width + 20, height: 700))
        host.setFrameSize(NSSize(width: width, height: host.frame.height))
        layout()
    }

    func layout() {
        scroll.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        if height.isFinite && height > 0 {
            host.setFrameSize(NSSize(width: context.availableWidth, height: max(1, height)))
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func evaluate(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        let browser = try #require(model.webView)
        return try await browser.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
    }

    func geometry() async throws -> [String: Any] {
        try #require(try await evaluate("""
            const root = document.getElementById('root');
            const input = document.querySelector('input[name="notes"]');
            return {height:Math.ceil(root.getBoundingClientRect().bottom + window.scrollY),
                    width:window.innerWidth, hasInput:!!input, value:input?.value};
            """) as? [String: Any])
    }

    func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition() {
            layout()
            guard ContinuousClock.now < deadline else { throw await timeout(description) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitForGeometry(_ description: String, condition: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while true {
            layout()
            let value = try await geometry()
            if condition(value) { return value }
            guard ContinuousClock.now < deadline else { throw await timeout(description) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func timeout(_ description: String) async -> HeightRecoveryTimeout {
        let value = try? await geometry()
        Issue.record("Timed out: \(description); DOM=\(String(describing: value)), modelHeight=\(model.measuredHeight), error=\(String(describing: model.error)), browserFrame=\(String(describing: model.webView?.frame))")
        return HeightRecoveryTimeout()
    }

    func close() { model.dispose(); window.close() }
    private struct HeightRecoveryTimeout: Error {}
}
#endif
