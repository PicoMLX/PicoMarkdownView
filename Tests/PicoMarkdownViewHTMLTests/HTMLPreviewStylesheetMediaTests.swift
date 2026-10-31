#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import PicoMarkdownViewHTML

@Suite("HTML stylesheet media policy")
struct HTMLPreviewStylesheetMediaPolicyTests {
    @Test("Head and body styles preserve media while escaping their separate HTML contexts", arguments: [false, true])
    func preparedStylesKeepMedia(inHead: Bool) throws {
        let sheet = #"<style media="screen and (width > 200px)" id="author-style" onload="alert(1)" nonce="author-nonce">p::before { content: "<safe>&"; }</style>"#
        let source = mediaDocument(styles: sheet, inHead: inHead)
        let content = try HTMLPreviewPolicy.prepare(source: source)
        let document = content.document()
        #expect(document.html.contains(#"<style media="screen and (width &gt; 200px)">"#))
        #expect(document.html.contains(#"content: "\3C safe>&";"#), "CSS raw text uses CSS escaping rather than HTML entities")
        #expect(!document.html.contains("author-style"))
        #expect(!document.html.contains("onload="))
        #expect(!document.html.contains("author-nonce"))
        #expect(content.plainText == "Report")
    }
}

@MainActor
@Suite("HTML stylesheet media rendering", .serialized, .timeLimit(.minutes(1)))
struct HTMLPreviewStylesheetMediaTests {
    @Test("Print-only styles leave the screen report visible", arguments: [false, true])
    func printStylesDoNotHideScreenContent(inHead: Bool) async throws {
        let fixture = MediaPreviewFixture(source: mediaDocument(styles: "<style media='print'>p { display: none; }</style>", inHead: inHead))
        defer { fixture.close() }
        let page = try await fixture.readyPage()
        let values = try await reportState(page)
        #expect(values["text"] as? String == "Report")
        #expect(values["display"] as? String != "none")
        let height = try #require(values["height"] as? Double)
        #expect(height > 0)
        #expect(values["printMatches"] as? Bool == false)
    }

    @Test("A responsive stylesheet changes at its media breakpoint without a page reload")
    func responsiveStyleTracksViewportWithoutReloading() async throws {
        let source = mediaDocument(styles: """
        <style>p { margin: 0; height: 24px; color: rgb(1, 2, 3); }</style>
        <style media="screen and (min-width: 480px)">p { height: 96px; color: rgb(12, 34, 56); }</style>
        """, inHead: true)
        let fixture = MediaPreviewFixture(source: source, width: 320)
        defer { fixture.close() }
        let page = try await fixture.readyPage()
        let narrow = try await reportState(page)
        #expect(narrow["color"] as? String == "rgb(1, 2, 3)")
        #expect(narrow["height"] as? Double == 24)
        #expect(narrow["wideMatches"] as? Bool == false)

        fixture.resize(width: 640)
        try await fixture.waitForHeight(96)
        let wide = try await reportState(page)
        #expect(wide["color"] as? String == "rgb(12, 34, 56)")
        #expect(wide["height"] as? Double == 96)
        #expect(wide["wideMatches"] as? Bool == true)
        #expect(fixture.view.page === page)
        #expect(fixture.view.loadCount == 1)
    }

    @Test("Quoted invalid media stays inactive and cannot introduce author style attributes")
    func mediaQuotesStayInsideTheAttribute() async throws {
        let query = #"print" onload="alert(1)"#
        let sheet = "<style media='\(query)' id='author-style' onload='alert(2)' nonce='author-nonce'>/* author-media-marker */ p { display: none; }</style>"
        let fixture = MediaPreviewFixture(source: mediaDocument(styles: sheet, inHead: true))
        defer { fixture.close() }
        let page = try await fixture.readyPage()
        let result = try await page.callJavaScript("""
            const sheet = Array.from(document.querySelectorAll('style')).find(node => node.textContent.includes('author-media-marker'));
            const report = document.querySelector('p');
            return { media: sheet.getAttribute('media'), attributes: sheet.getAttributeNames(),
                     display: getComputedStyle(report).display, height: report.getBoundingClientRect().height };
            """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        #expect(values["media"] as? String == query)
        #expect(values["attributes"] as? [String] == ["media"])
        #expect(values["display"] as? String != "none")
        let height = try #require(values["height"] as? Double)
        #expect(height > 0)
    }

    @Test("Missing and empty media continue to apply unconditionally", arguments: [false, true])
    func unconditionalStylesStillApply(emptyMedia: Bool) async throws {
        let attribute = emptyMedia ? " media=''" : ""
        let fixture = MediaPreviewFixture(source: mediaDocument(styles: "<style\(attribute)>p { color: rgb(12, 34, 56); }</style>", inHead: true))
        defer { fixture.close() }
        let values = try await reportState(try await fixture.readyPage())
        #expect(values["color"] as? String == "rgb(12, 34, 56)")
        let height = try #require(values["height"] as? Double)
        #expect(height > 0)
    }

    private func reportState(_ page: WebPage) async throws -> [String: Any] {
        let result = try await page.callJavaScript("""
            const report = document.querySelector('p');
            const style = getComputedStyle(report);
            return { text: report.textContent, display: style.display, color: style.color,
                     height: report.getBoundingClientRect().height,
                     printMatches: matchMedia('print').matches,
                     wideMatches: matchMedia('screen and (min-width: 480px)').matches };
            """, contentWorld: .defaultClient) as? [String: Any]
        return try #require(result)
    }
}

private func mediaDocument(styles: String, inHead: Bool) -> String {
    "<html><head>\(inHead ? styles : "")</head><body><p>Report</p>\(inHead ? "" : styles)</body></html>"
}

/// Await the production readiness/failure and measurement callbacks. No delay
/// or duration assertion determines whether a stylesheet is behaving correctly.
@MainActor
private final class MediaPreviewFixture {
    let view: HTMLPreviewContainer
    private let window: NSWindow
    private let outcome = AsyncStream.makeStream(of: Bool.self)
    private let heights = AsyncStream.makeStream(of: CGFloat.self)

    init(source: String, width: CGFloat = 400) {
        _ = NSApplication.shared
        view = HTMLPreviewContainer()
        window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: width, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let outcome = outcome.continuation
        let heights = heights.continuation
        view.onReady = { outcome.yield(true); outcome.finish() }
        view.onFailure = { outcome.yield(false); outcome.finish(); heights.finish() }
        view.onHeight = { [weak window] height in
            window?.setContentSize(NSSize(width: window?.contentLayoutRect.width ?? width, height: height))
            heights.yield(height)
        }
        view.configure(source: source, style: .default)
        window.contentView = view
        window.orderFront(nil)
    }

    func readyPage() async throws -> WebPage {
        var events = outcome.stream.makeAsyncIterator()
        let becameReady = await events.next()
        try #require(becameReady == true && view.isReady && !view.hasFailed)
        return try #require(view.page)
    }

    func waitForHeight(_ expected: CGFloat) async throws {
        if view.measuredHeight == expected { return }
        for await height in heights.stream {
            if height == expected { return }
        }
        Issue.record("The preview failed before reporting the expected responsive height")
        try #require(!view.hasFailed)
    }

    func resize(width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: max(1, view.measuredHeight)))
    }

    func close() {
        view.onReady = nil
        view.onFailure = nil
        view.onHeight = nil
        outcome.continuation.finish()
        heights.continuation.finish()
        view.suspend()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}
#endif
