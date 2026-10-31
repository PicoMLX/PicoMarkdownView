#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import PicoMarkdownViewHTML

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HTMLPreviewViewTests {
    @Test func staticPreviewFitsAndReflowsWithoutReloading() async throws {
        let source = "<div style='padding:8px'><h2>Preview</h2><p>" + String(repeating: "Responsive text should wrap within the transcript. ", count: 18) + "</p></div>"
        let (view, window) = makePreview(source: source, width: 560)
        defer { tearDown(view, window) }
        try await waitUntilReady(view)
        let page = try #require(view.page)
        let wideHeight = view.measuredHeight
        #expect(wideHeight > 40)
        #expect(view.loadCount == 1)

        window.setContentSize(NSSize(width: 220, height: max(1, wideHeight)))
        try await waitForWidth(220, page: page)
        while view.measuredHeight <= wideHeight { try await Task.sleep(for: .milliseconds(20)) }
        let narrowHeight = view.measuredHeight
        #expect(narrowHeight > wideHeight)
        #expect(view.page === page)
        #expect(view.loadCount == 1)

        window.setContentSize(NSSize(width: 560, height: narrowHeight))
        try await waitForWidth(560, page: page)
        while view.measuredHeight >= narrowHeight { try await Task.sleep(for: .milliseconds(20)) }
        #expect(view.measuredHeight == wideHeight)
        #expect(view.page === page)
        #expect(view.loadCount == 1)
        let background = try await page.callJavaScript("return getComputedStyle(document.body).backgroundColor", contentWorld: .defaultClient) as? String
        #expect(background == "rgba(0, 0, 0, 0)")
    }

    @Test func browserReceivesOnlyStaticOfflineContent() async throws {
        let source = """
        <style>@import url('https://example.invalid/remote.css'); @keyframes spin { to { transform: rotate(360deg); } } p { animation: spin 1s infinite; transition: color 1s; color: rgb(12, 34, 56); background-image: url('file:///tmp/private.png'); }</style>
        <script>document.body.dataset.authorScript = 'executed';</script>
        <p onclick="document.body.dataset.clicked='yes'">Visible 日本語 🚀</p>
        <form action="https://example.invalid"><input value="secret"><button>Send</button></form>
        <iframe src="https://example.invalid"></iframe><a href="https://example.invalid">Static label</a>
        """
        let (view, window) = makePreview(source: source, width: 400)
        defer { tearDown(view, window) }
        try await waitUntilReady(view)
        let page = try #require(view.page)
        let result = try await page.callJavaScript("""
          return {
            text: document.body.textContent,
            active: document.querySelectorAll('script, iframe, form, input, button, [onclick], [href], [src]').length,
            authorScript: document.body.dataset.authorScript || '',
            color: getComputedStyle(document.querySelector('p')).color,
            animation: getComputedStyle(document.querySelector('p')).animationName,
            transition: getComputedStyle(document.querySelector('p')).transitionDuration,
            csp: document.head.firstElementChild.getAttribute('http-equiv'),
            resources: performance.getEntriesByType('resource').filter(e => !e.name.startsWith('about:')).length
          }
        """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        #expect((values["text"] as? String)?.contains("Visible 日本語 🚀") == true)
        #expect((values["text"] as? String)?.contains("Static label") == true)
        #expect(values["active"] as? Int == 0)
        #expect(values["authorScript"] as? String == "")
        #expect(values["color"] as? String == "rgb(12, 34, 56)")
        #expect(values["animation"] as? String == "none")
        #expect(values["transition"] as? String == "0s")
        #expect(values["csp"] as? String == "Content-Security-Policy")
        #expect(values["resources"] as? Int == 0)
    }

    @Test func detachReleasesPageAndReattachRestoresPreview() async throws {
        let counter = PreparationCounter()
        let (view, window) = makePreview(source: "<p>A stable source-backed preview.</p>", width: 400,
                                         prepare: counter.prepare)
        defer { tearDown(view, window) }
        try await waitUntilReady(view)
        weak var firstPage = view.page
        let height = view.measuredHeight
        window.contentView = nil
        #expect(view.page == nil)
        #expect(view.measuredHeight == height)
        // A cancelled navigation sequence can release its local page on its
        // next executor turn rather than during removal from the window.
        while firstPage != nil { try await Task.sleep(for: .milliseconds(20)) }
        window.contentView = view
        try await waitUntilReady(view)
        #expect(view.loadCount == 2)
        #expect(view.measuredHeight == height)
        #expect(!view.hasFailed)
        #expect(await counter.count == 1)
    }

    @Test func appearanceFollowsTheMarkdownViewAndReloadsOnlyThePreview() async throws {
        let counter = PreparationCounter()
        let (view, window) = makePreview(source: "<p>A themed preview.</p>", width: 400,
                                         prepare: counter.prepare)
        defer { tearDown(view, window) }
        try await waitUntilReady(view)
        let lightPage = try #require(view.page)
        let light = try await lightPage.callJavaScript("return matchMedia('(prefers-color-scheme: dark)').matches", contentWorld: .defaultClient) as? Bool
        #expect(light == false)
        var style = HTMLPreviewStyle.default
        style.isDark = true
        view.configure(source: "<p>A themed preview.</p>", style: style)
        try await waitUntilReady(view)
        let darkPage = try #require(view.page)
        #expect(darkPage !== lightPage)
        #expect(view.loadCount == 2)
        let dark = try await darkPage.callJavaScript("return matchMedia('(prefers-color-scheme: dark)').matches", contentWorld: .defaultClient) as? Bool
        #expect(dark == true)
        let scheme = try await darkPage.callJavaScript("return getComputedStyle(document.documentElement).colorScheme", contentWorld: .defaultClient) as? String
        #expect(scheme == "dark")
        #expect(await counter.count == 1)
    }

    @Test(arguments: [
        "<div style='height:5000px'>Too tall for a bounded preview</div>",
        "<p>Flowing report</p><div style='position:fixed;top:1000px;height:100px'>Outside the flow</div>"
    ])
    func unsupportedLayoutUsesSourceFallbackInsteadOfClipping(source: String) async throws {
        let (view, window) = makePreview(source: source, width: 400)
        defer { tearDown(view, window) }
        while !view.hasFailed && !view.isReady { try await Task.sleep(for: .milliseconds(20)) }
        #expect(view.hasFailed)
        #expect(view.page == nil)
        #expect(!view.isReady)
        #expect(view.measuredHeight == 1)
    }

    private func makePreview(source: String, width: CGFloat,
                             prepare: @escaping HTMLPreviewPreparation.Prepare = { source in
                                 try await HTMLPreviewPolicy.prepareOffMainActor(source: source)
                             }) -> (HTMLPreviewContainer, NSWindow) {
        _ = NSApplication.shared
        let view = HTMLPreviewContainer(prepare: prepare)
        view.configure(source: source, style: .default)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: width, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.onHeight = { [weak window] height in
            guard let window else { return }
            window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: height))
        }
        window.orderFront(nil)
        return (view, window)
    }

    private func waitUntilReady(_ view: HTMLPreviewContainer) async throws {
        while !view.isReady && !view.hasFailed { try await Task.sleep(for: .milliseconds(20)) }
        try #require(view.isReady)
    }

    private func waitForWidth(_ width: Int, page: WebPage) async throws {
        while try await page.callJavaScript("return window.innerWidth", contentWorld: .defaultClient) as? Int != width {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func tearDown(_ view: HTMLPreviewContainer, _ window: NSWindow) {
        view.suspend()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private actor PreparationCounter {
        var count = 0
        func prepare(source: String) async throws -> HTMLPreparedContent {
            count += 1
            return try await HTMLPreviewPolicy.prepareOffMainActor(source: source)
        }
    }

}
#endif
