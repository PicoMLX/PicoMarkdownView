#if os(macOS)
import AppKit
import PicoMarkdownSkills
import Testing
import WebKit
@testable import PicoMarkdownViewHTML

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HTMLPreviewSkillExamplesTests {
    @Test("The shipped HTML skill examples render within narrow and wide chat columns", arguments: [280, 640])
    func examplesRender(width: Int) async throws {
        let markdown = try String(contentsOf: PicoMarkdownSkills.directoryURL
            .appendingPathComponent("html-previews/SKILL.md"), encoding: .utf8)
        let examples = try markdown.components(separatedBy: "```html-preview\n").dropFirst().map { remainder in
            let end = try #require(remainder.range(of: "\n```"), "An HTML preview example needs its closing fence")
            return String(remainder[..<end.lowerBound])
        }
        try #require(!examples.isEmpty)
        for source in examples {
            try await render(source: source, width: width)
        }
    }

    private func render(source: String, width: Int) async throws {
        _ = NSApplication.shared
        let view = HTMLPreviewContainer()
        view.configure(source: source, style: .default)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: width, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let outcome = AsyncStream.makeStream(of: Bool.self)
        view.onReady = { outcome.continuation.yield(true); outcome.continuation.finish() }
        view.onFailure = { outcome.continuation.yield(false); outcome.continuation.finish() }
        view.onHeight = { [weak window] height in
            guard let window else { return }
            window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: height))
        }
        defer {
            outcome.continuation.finish()
            view.onReady = nil
            view.onFailure = nil
            view.onHeight = nil
            view.suspend()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        window.contentView = view
        window.orderFront(nil)
        var iterator = outcome.stream.makeAsyncIterator()
        let readiness = await iterator.next()
        try #require(readiness == true, "The real preview adapter must render rather than fall back to source")
        let page = try #require(view.page)
        let result = try await page.callJavaScript("""
            return { text: document.body.textContent.trim(),
                     width: window.innerWidth,
                     contentWidth: document.documentElement.scrollWidth };
            """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        #expect((values["text"] as? String)?.isEmpty == false)
        let viewportWidth = try #require(values["width"] as? Double)
        let contentWidth = try #require(values["contentWidth"] as? Double)
        #expect(viewportWidth == Double(width))
        #expect(contentWidth <= viewportWidth + 1)
        #expect(view.measuredHeight > 1 && view.measuredHeight <= HTMLPreviewPolicy.maximumHeight)
    }
}
#endif
