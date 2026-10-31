#if os(macOS)
import AppKit
import Testing
@preconcurrency import WebKit
@testable import PicoMarkdownView

@Suite("Hosted OpenUI popup and math presentation", .serialized)
@MainActor
struct MacOpenUIPresentationTests {
    @Test("DatePicker portal expands its native attachment and lower dates remain clickable", .timeLimit(.minutes(1)))
    func datePickerPortalFitsAttachment() async throws {
        let fixture = try await OpenUIPresentationFixture(source:
            #"root = Stack([TextContent("Choose a date"), DatePicker("appointment", "single")])"#)
        defer { fixture.close() }
        let closedHeight = fixture.model.measuredHeight
        let renders = fixture.model.renderCount
        let webView = fixture.webView
        _ = try await fixture.evaluate("document.querySelector('.openui-date-picker-renderer-floating-input-container').click(); return true;")
        let geometry = try await fixture.waitForGeometry("Calendar becomes fully visible", script: """
            const popup = document.querySelector('.openui-date-picker-renderer-floating-content');
            if (!popup) return null;
            const rect = popup.getBoundingClientRect();
            const days = [...popup.querySelectorAll('.openui-calendar-single-day-button:not(:disabled)')];
            const last = days.at(-1);
            if (!last) return null;
            const day = last.getBoundingClientRect();
            const target = document.elementFromPoint(day.x + day.width / 2, day.y + day.height / 2);
            return {top:rect.top, bottom:rect.bottom, viewport:window.innerHeight,
                    fits:rect.top >= -1 && rect.bottom <= window.innerHeight + 1,
                    lowerDateClickable:target === last || last.contains(target)};
            """) { ($0["fits"] as? Bool) == true && ($0["lowerDateClickable"] as? Bool) == true }
        #expect(geometry["fits"] as? Bool == true)
        try await fixture.waitUntil("Native attachment reserves the expanded calendar height") {
            abs(fixture.attachment.measuredSize.height - fixture.model.measuredHeight) <= 2
        }
        fixture.layout()
        let nativeHit = try await fixture.evaluate("""
            const days = [...document.querySelectorAll('.openui-calendar-single-day-button:not(:disabled)')];
            const rect = days.at(-1).getBoundingClientRect();
            return {x:rect.x + rect.width / 2, y:rect.y + rect.height / 2};
            """) as? [String: Double]
        let lowerDate = try #require(nativeHit)
        let point = NSPoint(x: try #require(lowerDate["x"]) * fixture.model.textScale,
                            y: try #require(lowerDate["y"]) * fixture.model.textScale)
        let hit = fixture.textView.hitTest(fixture.webView.convert(point, to: fixture.textView.superview))
        #expect(hit === fixture.webView || hit?.isDescendant(of: fixture.webView) == true,
                "The lower date must also receive native pointer input through the TextKit attachment")
        #expect(fixture.model.measuredHeight > closedHeight)
        #expect(fixture.model.webView === webView && fixture.model.renderCount == renders)
        try await fixture.saveSnapshot("openui-calendar.png")
        let oldDate = try await fixture.evaluate("return document.querySelector('.openui-date-picker-renderer-floating-input-container-text').textContent;") as? String
        _ = try await fixture.evaluate("""
            const days = [...document.querySelectorAll('.openui-calendar-single-day-button:not(:disabled)')];
            days.at(-1).click(); return true;
            """)
        let newDate = try await fixture.evaluate("return document.querySelector('.openui-date-picker-renderer-floating-input-container-text').textContent;") as? String
        #expect(newDate != oldDate)
        _ = try await fixture.evaluate("""
            if (document.querySelector('.openui-date-picker-renderer-floating-content')) {
              document.querySelector('.openui-date-picker-renderer-floating-input-container').click();
            }
            return true;
            """)
        try await fixture.waitUntil("Closing the calendar restores the native block height") {
            abs(fixture.model.measuredHeight - closedHeight) <= 2
        }
        #expect(fixture.model.webView === webView && fixture.model.renderCount == renders)
        #expect(fixture.model.webViewCreationCount == 1)
        #expect(fixture.textView.textLayoutManager != nil)
    }

    @Test("OpenUI TextContent math has local KaTeX styling, one visible rendering tree and loaded fonts", .timeLimit(.minutes(1)))
    func textContentMathIsStyled() async throws {
        let fixture = try await OpenUIPresentationFixture(source:
            #"root = TextContent("Inline $$x^2$$ and display:\n\n$$\n\\frac{1}{2}\n$$")"#)
        defer { fixture.close() }
        _ = try await fixture.waitForGeometry("KaTeX rendering finishes", script:
            "return {count:document.querySelectorAll('.katex').length};") { ($0["count"] as? Int) == 2 }
        let presentation = try await fixture.evaluate("""
            await document.fonts.ready;
            const math = document.querySelector('.katex');
            const accessible = math?.querySelector('.katex-mathml');
            const visual = math?.querySelector('.katex-html');
            const loaded = await document.fonts.load('16px KaTeX_Main', '1');
            return {count:document.querySelectorAll('.katex').length,
                    displayCount:document.querySelectorAll('.katex-display').length,
                    accessiblePosition:accessible && getComputedStyle(accessible).position,
                    accessibleWidth:accessible?.getBoundingClientRect().width,
                    visualDisplay:visual && getComputedStyle(visual).display,
                    family:math && getComputedStyle(math).fontFamily,
                    loadedFonts:loaded.length};
            """) as? [String: Any]
        let result = try #require(presentation)
        #expect(result["count"] as? Int == 2)
        #expect(result["displayCount"] as? Int == 1)
        #expect(result["accessiblePosition"] as? String == "absolute")
        #expect((result["accessibleWidth"] as? Double ?? 100) <= 2)
        #expect(result["visualDisplay"] as? String != "none")
        #expect((result["family"] as? String)?.contains("KaTeX_Main") == true)
        #expect((result["loadedFonts"] as? Int ?? 0) > 0)
        #expect(fixture.model.error == nil)
        try await fixture.saveSnapshot("openui-math.png")
    }
}

@MainActor
private final class OpenUIPresentationFixture {
    let backend = TextKitStreamingBackend()
    let textView: StreamingTextKit2View
    let scroll: NSScrollView
    let window: NSWindow
    let model: PicoHostedOpenUIModel
    let attachment: PicoHostedAttachment
    var webView: WKWebView { model.webView! }

    init(source: String) async throws {
        _ = NSApplication.shared
        textView = StreamingTextKit2View(backend: backend)
        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 700))
        scroll.hasVerticalScroller = true
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 1400)
        scroll.documentView = textView
        window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let pipeline = MarkdownStreamingPipeline(theme: .default().withOpenUIRendering())
        _ = await pipeline.feed("Before.\n\n```openui\n" + source + "\n```\n\nAfter.\n\n")
        _ = await pipeline.finish()
        let blocks = await pipeline.blocksSnapshot()
        let id = try #require(blocks.first { $0.openUI != nil }?.id)
        _ = backend.apply(blocks: blocks, selection: .init(location: 0, length: 0))
        model = try #require(backend.hostedOpenUIModel(for: id))
        attachment = try #require(backend.hostedAttachment(for: id))
        backend.updateHostedAttachments(width: 580, selection: [])
        window.orderFront(nil)
        do {
            try await waitUntil("Visible hosted OpenUI is ready") {
                self.model.webView?.window === self.window && self.model.isReady && self.model.sizeMessageCount > 0
            }
        } catch { close(); throw error }
    }

    func layout() {
        scroll.layoutSubtreeIfNeeded()
        if let manager = textView.textLayoutManager, let content = manager.textContentManager {
            manager.ensureLayout(for: content.documentRange)
            manager.textViewportLayoutController.layoutViewport()
        }
        textView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func evaluate(_ script: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            layout()
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out: \(description)")
                throw PresentationTimeout()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitForGeometry(_ description: String, script: String,
                         condition: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var last: [String: Any] = [:]
        while true {
            layout()
            if let result = try await evaluate(script) as? [String: Any] {
                last = result
                if condition(result) { return result }
            }
            guard ContinuousClock.now < deadline else {
                Issue.record("\(description): \(last), native height=\(model.measuredHeight)")
                throw PresentationTimeout()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func saveSnapshot(_ name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["PICO_OPENUI_SNAPSHOT_DIRECTORY"] else { return }
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let image = try await webView.takeSnapshot(configuration: nil)
        if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: url.appendingPathComponent(name))
        }
    }

    func close() { model.dispose(); window.close() }
    private struct PresentationTimeout: Error {}
}
#endif
