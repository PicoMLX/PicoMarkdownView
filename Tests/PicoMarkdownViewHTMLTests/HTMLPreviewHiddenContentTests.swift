#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import PicoMarkdownViewHTML

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HTMLPreviewHiddenContentTests {
    @Test("Hidden subtrees are omitted from previews and cached readable text", arguments: ["", "=''", "='false'", "='until-found'"])
    func omitsHiddenSubtree(attributeValue: String) throws {
        let source = "<div hidden\(attributeValue)><p>Draft: $1000</p><img alt='Draft chart'></div><p>Final: $100</p>"
        let prepared = try HTMLPreviewPolicy.prepare(source: source)
        let document = prepared.document()
        #expect(prepared.plainText == "Final: $100")
        #expect(document.plainText == "Final: $100")
        #expect(!document.html.contains("Draft:"))
        #expect(!document.html.contains("Draft chart"))
        #expect(document.html.contains("Final: $100"))
    }

    @Test("A wholly hidden report uses the existing empty-content source fallback", arguments: [
        "<div hidden>Draft: $1000</div>",
        "<html><body hidden>Draft: $1000</body></html>",
        "<html hidden><body>Draft: $1000</body></html>"
    ])
    func whollyHiddenReportIsEmpty(source: String) {
        #expect(throws: HTMLPreviewPolicyError.emptyContent) {
            try HTMLPreviewPolicy.prepare(source: source)
        }
    }

    @Test("Hidden visual content does not disable styles that apply to the visible report", arguments: [false, true])
    func visibleReportKeepsStyles(styleInsideHiddenContainer: Bool) async throws {
        _ = NSApplication.shared
        let stylesheet = "<style hidden>#final { color: rgb(12, 34, 56); }</style>"
        let headStyles = styleInsideHiddenContainer ? "" : stylesheet
        let nestedStyles = styleInsideHiddenContainer ? stylesheet : ""
        let source = """
        <html><head>\(headStyles)</head><body>
        <div hidden id="draft">\(nestedStyles)<p>Draft: $1000</p></div>
        <p id="final">Final: $100</p></body></html>
        """
        let preparation = HTMLPreviewPreparation(source: source)
        let view = HTMLPreviewContainer(preparation: preparation)
        let outcome = AsyncStream.makeStream(of: Bool.self)
        view.onReady = { outcome.continuation.yield(true); outcome.continuation.finish() }
        view.onFailure = { outcome.continuation.yield(false); outcome.continuation.finish() }
        view.configure(source: source, style: .default)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer {
            view.onReady = nil
            view.onFailure = nil
            outcome.continuation.finish()
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        var iterator = outcome.stream.makeAsyncIterator()
        try #require(await iterator.next() == true, "The visible final report must reach a rendered preview")
        let page = try #require(view.page)
        let result = try await page.callJavaScript("""
          const final = document.getElementById('final');
          return {
            visibleText: document.body.innerText.trim(),
            draftCount: document.querySelectorAll('#draft').length,
            finalColor: getComputedStyle(final).color,
            finalHeight: final.getBoundingClientRect().height
          }
        """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        #expect(values["visibleText"] as? String == "Final: $100")
        #expect(values["draftCount"] as? Int == 0)
        #expect(values["finalColor"] as? String == "rgb(12, 34, 56)")
        let finalHeight = try #require(values["finalHeight"] as? Double)
        #expect(finalHeight > 0)
        #expect(preparation.preparedContent?.plainText == "Final: $100",
                "Viewport eviction must not expose the omitted draft through its semantic placeholder")
        #expect(preparation.source == source, "The source owner keeps the original HTML for core-owned copying")
        #expect(view.isReady && view.loadCount == 1)
    }
}
#endif
