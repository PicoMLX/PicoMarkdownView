#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import PicoMarkdownViewHTML

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HTMLPreviewDirectionTests {
    @Test("Document direction orders table columns, while an explicit body direction overrides it", arguments: [false, true])
    func documentDirectionReachesTable(bodyOverridesDirection: Bool) async throws {
        _ = NSApplication.shared
        let bodyDirection = bodyOverridesDirection ? " dir='ltr'" : ""
        let source = """
        <html dir="rtl"><body\(bodyDirection)><table style="width:280px;table-layout:fixed">
        <tr><td id="first">First</td><td id="second">Second</td></tr>
        </table></body></html>
        """
        let view = HTMLPreviewContainer()
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
        try #require(await iterator.next() == true, "The static table must reach a rendered preview")
        let page = try #require(view.page)
        let result = try await page.callJavaScript("""
          return {
            documentDirection: document.documentElement.getAttribute('dir'),
            bodyDirection: getComputedStyle(document.body).direction,
            tableDirection: getComputedStyle(document.querySelector('table')).direction,
            firstX: document.getElementById('first').getBoundingClientRect().x,
            secondX: document.getElementById('second').getBoundingClientRect().x
          }
        """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        let firstX = try #require(values["firstX"] as? Double)
        let secondX = try #require(values["secondX"] as? Double)
        #expect(values["documentDirection"] as? String == "rtl")
        let expected = bodyOverridesDirection ? "ltr" : "rtl"
        #expect(values["bodyDirection"] as? String == expected)
        #expect(values["tableDirection"] as? String == expected)
        if bodyOverridesDirection {
            #expect(firstX < secondX, "The body's explicit LTR direction overrides its RTL document")
        } else {
            #expect(firstX > secondX, "The first RTL table column must be to the right of the second")
        }
        #expect(view.isReady && view.loadCount == 1)
    }
}
#endif
