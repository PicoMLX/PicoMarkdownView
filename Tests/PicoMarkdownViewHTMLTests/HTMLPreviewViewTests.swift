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

    @Test("Full-document body spacing and offsets remain inside the measured preview", arguments: [false, true])
    func bodySpacingIsIncludedInMeasuredExtent(withBorderAndOffset: Bool) async throws {
        let border: Double = withBorderAndOffset ? 6 : 0
        let offset: Double = withBorderAndOffset ? 12 : 0
        let source = "<html><body style='padding:40px;border:\(border)px solid black;position:relative;top:\(offset)px'><div style='height:20px'>Report</div></body></html>"
        let (view, window) = makePreview(source: source, width: 400)
        defer { tearDown(view, window) }
        let ready = AsyncStream.makeStream(of: Void.self)
        view.onReady = { ready.continuation.yield(()) }
        defer { view.onReady = nil; ready.continuation.finish() }
        if !view.isReady {
            var iterator = ready.stream.makeAsyncIterator()
            try #require(await iterator.next() != nil)
        }
        let page = try #require(view.page)
        let result = try await page.callJavaScript("""
            const report = document.querySelector('body > div');
            const rect = report.getBoundingClientRect();
            const body = document.body.getBoundingClientRect();
            const style = getComputedStyle(document.body);
            return { text: report.textContent, top: rect.top, bottom: rect.bottom,
                     bodyBottom: body.bottom, viewportHeight: innerHeight,
                     padding: parseFloat(style.paddingTop), border: parseFloat(style.borderBottomWidth) };
            """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        #expect(values["text"] as? String == "Report")
        #expect(values["padding"] as? Double == 40)
        #expect(values["border"] as? Double == border)
        let top = try #require(values["top"] as? Double)
        let bottom = try #require(values["bottom"] as? Double)
        let bodyBottom = try #require(values["bodyBottom"] as? Double)
        let viewportHeight = try #require(values["viewportHeight"] as? Double)
        #expect(abs(top - (40 + border + offset)) <= 1)
        #expect(view.measuredHeight >= 100 + 2 * border + offset)
        #expect(view.measuredHeight >= ceil(bodyBottom))
        #expect(view.bounds.height >= ceil(bodyBottom))
        #expect(top >= 0 && bottom <= viewportHeight, "The actual report must be inside the rendered browser viewport")
    }

    @Test("Positioned or transformed generated content uses source fallback", arguments: [
        ("div::after", "position:absolute;top:200px", "<div>Intro</div>"),
        ("body::before", "position:absolute;top:200px", "<div>Intro</div>"),
        ("html::after", "position:absolute;top:200px", "<div>Intro</div>"),
        ("html::after", "display:block;height:40px", "<div>Intro</div>"),
        ("html::before", "display:block;height:40px", "<div>Intro</div>"),
        ("div::after", "position:absolute;top:200px", "<div></div><p>Intro</p>"),
        ("div::after", "position:absolute;top:200px;content:'';width:100px;height:40px;background:red", "<div>Intro</div>"),
        ("div::before", "display:inline-block;transform:translateY(200px)", "<div>Intro</div>"),
        ("div::after", "display:inline-block;translate:0 200px", "<div>Intro</div>")
    ])
    func unsupportedGeneratedContentUsesSource(entry: (String, String, String)) async throws {
        let (selector, rule, markup) = entry
        let source = "<style>\(selector) { content:'Report'; \(rule); }</style>" + markup
        let (view, window) = makePreview(source: source, width: 400)
        defer { tearDown(view, window) }
        let outcome = AsyncStream.makeStream(of: Bool.self)
        view.onReady = { outcome.continuation.yield(true); outcome.continuation.finish() }
        view.onFailure = { outcome.continuation.yield(false); outcome.continuation.finish() }
        defer { view.onReady = nil; view.onFailure = nil; outcome.continuation.finish() }
        var iterator = outcome.stream.makeAsyncIterator()
        let becameReady = try #require(await iterator.next())
        #expect(!becameReady, "Generated boxes that escape ordinary flow cannot be measured through element bounds")
        #expect(view.hasFailed && !view.isReady)
        #expect(view.page == nil)
        #expect(view.measuredHeight == 1)
    }

    @Test("Ordinary in-flow generated content remains in the measured preview", arguments: [
        "div::before", "div::after", "body::before", "body::after"
    ])
    func inFlowGeneratedContentRemainsVisible(selector: String) async throws {
        let source = "<style>\(selector) { content:'Report'; display:block; height:40px; }</style><div>Intro</div>"
        let (view, window) = makePreview(source: source, width: 400)
        defer { tearDown(view, window) }
        try await waitUntilReady(view)
        let page = try #require(view.page)
        let parts = selector.components(separatedBy: "::")
        let result = try await page.callJavaScript("""
            const origin = document.querySelector('\(parts[0])');
            const pseudo = getComputedStyle(origin, '::\(parts[1])');
            return { content: pseudo.content, display: pseudo.display, position: pseudo.position,
                     bottom: document.documentElement.getBoundingClientRect().bottom,
                     text: document.body.textContent, viewportHeight: innerHeight };
            """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        #expect((values["content"] as? String)?.contains("Report") == true)
        #expect(values["display"] as? String == "block")
        #expect(values["position"] as? String == "static")
        #expect((values["text"] as? String)?.contains("Intro") == true)
        #expect(view.measuredHeight >= 40)
        let bottom = try #require(values["bottom"] as? Double)
        let viewportHeight = try #require(values["viewportHeight"] as? Double)
        #expect(bottom <= viewportHeight)
    }

    @Test("Standards-mode body scrolling height excludes the large native viewport minimum")
    func bodyScrollHeightIsIntrinsicInStandardsMode() async throws {
        let (view, window) = makePreview(source: "<div style='height:20px'>Report</div>", width: 400)
        defer { tearDown(view, window) }
        view.onHeight = nil
        window.setContentSize(NSSize(width: 400, height: 1000))
        try await waitUntilReady(view)
        let page = try #require(view.page)
        let result = try await page.callJavaScript("""
            return { mode: document.compatMode, bodyHeight: document.body.getBoundingClientRect().height,
                     bodyScrollHeight: document.body.scrollHeight, rootScrollHeight: document.documentElement.scrollHeight,
                     viewportHeight: innerHeight };
            """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        #expect(values["mode"] as? String == "CSS1Compat")
        #expect(values["bodyHeight"] as? Double == 20)
        #expect(values["bodyScrollHeight"] as? Double == 20)
        #expect(values["viewportHeight"] as? Double == 1000)
        #expect(values["rootScrollHeight"] as? Double == 1000)
        #expect(view.measuredHeight == 20)
    }

    @Test("Body overflow height shrinks after width grows inside an unchanged large viewport")
    func intrinsicBodyHeightShrinksInLargeViewport() async throws {
        let source = "<p>" + String(repeating: "Responsive report content wraps with available width. ", count: 12) + "</p>"
        let (view, window) = makePreview(source: source, width: 560)
        defer { tearDown(view, window) }
        let heights = AsyncStream.makeStream(of: CGFloat.self)
        view.onHeight = { heights.continuation.yield($0) }
        defer { view.onHeight = nil; heights.continuation.finish() }
        window.setContentSize(NSSize(width: 560, height: 1000))
        try await waitUntilReady(view)
        let page = try #require(view.page)
        let wideHeight = view.measuredHeight
        try #require(wideHeight < 1000)
        var iterator = heights.stream.makeAsyncIterator()
        window.setContentSize(NSSize(width: 220, height: 1000))
        while let height = await iterator.next() { if height > wideHeight { break } }
        let narrowHeight = view.measuredHeight
        try #require(narrowHeight > wideHeight)
        window.setContentSize(NSSize(width: 560, height: 1000))
        while let height = await iterator.next() { if height < narrowHeight { break } }
        #expect(view.measuredHeight == wideHeight)
        #expect(view.page === page)
        #expect(view.loadCount == 1)
        let result = try await page.callJavaScript("return { height:document.body.scrollHeight, viewport:innerHeight }", contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        let scrollHeight = try #require(values["height"] as? Double)
        #expect(abs(scrollHeight - wideHeight) <= 1)
        #expect(values["viewport"] as? Double == 1000)
    }

    @Test("In-flow generated content overflowing a fixed-height origin is fully painted")
    func generatedVerticalOverflowIsMeasured() async throws {
        let source = "<style>div::after { content:'Report';display:block;padding-top:200px;line-height:20px; }</style><div style='height:20px;line-height:20px'>Intro</div>"
        let (view, window) = makePreview(source: source, width: 400)
        defer { tearDown(view, window) }
        try await waitUntilReady(view)
        let page = try #require(view.page)
        let result = try await page.callJavaScript("""
            const origin = document.querySelector('body > div');
            const rect = origin.getBoundingClientRect();
            const pseudo = getComputedStyle(origin, '::after');
            const reportY = rect.top + parseFloat(getComputedStyle(origin).lineHeight)
              + parseFloat(pseudo.paddingTop) + parseFloat(pseudo.lineHeight) / 2;
            const hit = document.elementFromPoint(rect.left + 20, reportY);
            return { content:pseudo.content, bodyHeight:document.body.getBoundingClientRect().height,
                     bodyScrollHeight:document.body.scrollHeight, originHeight:rect.height,
                     reportY, viewportHeight:innerHeight, painted:hit === origin };
            """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        #expect((values["content"] as? String)?.contains("Report") == true)
        #expect(values["bodyHeight"] as? Double == 20)
        #expect(values["originHeight"] as? Double == 20)
        let scrollHeight = try #require(values["bodyScrollHeight"] as? Double)
        let reportY = try #require(values["reportY"] as? Double)
        let viewportHeight = try #require(values["viewportHeight"] as? Double)
        #expect(view.measuredHeight >= scrollHeight)
        #expect(reportY < viewportHeight)
        #expect(values["painted"] as? Bool == true, "The generated Report must be painted beyond its short originating element")
    }

    @Test("A transformed body's extra overflow uses source fallback instead of unscaled height", arguments: ["transform:scaleY(2)", "scale:1 2"])
    func transformedBodyOverflowUsesSource(bodyTransform: String) async throws {
        let source = "<html><head><style>div::after { content:'Report';display:block;padding-top:200px;line-height:20px; }</style></head><body style='height:20px;line-height:20px;\(bodyTransform);transform-origin:top left'><div style='height:20px'>Intro</div></body></html>"
        let (view, window) = makePreview(source: source, width: 400)
        defer { tearDown(view, window) }
        let outcome = AsyncStream.makeStream(of: Bool.self)
        view.onReady = { outcome.continuation.yield(true); outcome.continuation.finish() }
        view.onFailure = { outcome.continuation.yield(false); outcome.continuation.finish() }
        defer { view.onReady = nil; view.onFailure = nil; outcome.continuation.finish() }
        var iterator = outcome.stream.makeAsyncIterator()
        let becameReady = try #require(await iterator.next())
        #expect(!becameReady)
        #expect(view.hasFailed && !view.isReady)
        #expect(view.page == nil)
    }

    @Test("Static generated overflow falls back when narrow and paints when its box fits", arguments: [false, true])
    func staticGeneratedWidthMustFitViewport(wide: Bool) async throws {
        let source = "<style>div::after { content:'Report';display:block;width:600px;height:40px;text-align:right;background:red; }</style><div>Intro</div>"
        let (view, window) = makePreview(source: source, width: wide ? 660 : 300)
        defer { tearDown(view, window) }
        let outcome = AsyncStream.makeStream(of: Bool.self)
        view.onReady = { outcome.continuation.yield(true); outcome.continuation.finish() }
        view.onFailure = { outcome.continuation.yield(false); outcome.continuation.finish() }
        defer { view.onReady = nil; view.onFailure = nil; outcome.continuation.finish() }
        var iterator = outcome.stream.makeAsyncIterator()
        let becameReady = try #require(await iterator.next())
        #expect(becameReady == wide)
        if !wide {
            #expect(view.hasFailed && !view.isReady)
            #expect(view.page == nil)
            return
        }
        let page = try #require(view.page)
        let result = try await page.callJavaScript("""
            const origin = document.querySelector('body > div');
            const pseudo = getComputedStyle(origin, '::after');
            const rect = origin.getBoundingClientRect();
            const hit = document.elementFromPoint(rect.left + 590, rect.bottom - 30);
            return { content: pseudo.content, width: parseFloat(pseudo.width), position: pseudo.position,
                     painted: hit === origin, scrollWidth: document.body.scrollWidth, viewportWidth: innerWidth };
            """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        #expect((values["content"] as? String)?.contains("Report") == true)
        #expect(values["width"] as? Double == 600)
        #expect(values["position"] as? String == "static")
        #expect(values["painted"] as? Bool == true)
        let scrollWidth = try #require(values["scrollWidth"] as? Double)
        let viewportWidth = try #require(values["viewportWidth"] as? Double)
        #expect(scrollWidth <= viewportWidth + 1)
    }

    @Test("Inactive generated content does not reject a visible report", arguments: [
        "<style>div::after { content:'Report';position:absolute;top:200px;display:none; }</style><div>Intro</div>",
        "<style>div::after { content:'Report';position:absolute;top:200px;visibility:hidden; }</style><div>Intro</div>",
        "<style>div::after { content:none;position:absolute;top:200px; }</style><div>Intro</div>",
        "<style>div::after { content:'Report';position:absolute;top:200px; }</style><section style='display:none'><div>Inactive</div></section><p>Intro</p>"
    ])
    func inactiveGeneratedContentKeepsPreview(source: String) async throws {
        let (view, window) = makePreview(source: source, width: 400)
        defer { tearDown(view, window) }
        try await waitUntilReady(view)
        #expect(view.isReady && !view.hasFailed)
        let page = try #require(view.page)
        let text = try await page.callJavaScript("return document.body.textContent", contentWorld: .defaultClient) as? String
        #expect(text?.contains("Intro") == true)
    }

    @Test("Horizontal report overflow falls back at narrow widths and paints fully when it fits", arguments: [false, true], ["ltr", "rtl"])
    func horizontalExtentMustFitViewport(wide: Bool, direction: String) async throws {
        let source = "<html dir='\(direction)'><body><div style='display:flex;min-width:600px;justify-content:space-between'><span>Start</span><span>Report</span></div></body></html>"
        let width: CGFloat = wide ? 660 : 300
        let (view, window) = makePreview(source: source, width: width)
        defer { tearDown(view, window) }
        let outcome = AsyncStream.makeStream(of: Bool.self)
        view.onReady = { outcome.continuation.yield(true); outcome.continuation.finish() }
        view.onFailure = { outcome.continuation.yield(false); outcome.continuation.finish() }
        defer { view.onReady = nil; view.onFailure = nil; outcome.continuation.finish() }
        var iterator = outcome.stream.makeAsyncIterator()
        let becameReady = try #require(await iterator.next())
        #expect(becameReady == wide)
        if !wide {
            #expect(view.hasFailed && !view.isReady)
            #expect(view.page == nil)
            #expect(view.measuredHeight == 1)
            return
        }
        #expect(view.isReady && !view.hasFailed)
        let page = try #require(view.page)
        let result = try await page.callJavaScript("""
            const labels = document.querySelectorAll('body > div > span');
            const report = labels[1];
            const range = document.createRange();
            range.selectNodeContents(report);
            const rect = range.getBoundingClientRect();
            const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
            return { first: labels[0].textContent, report: report.textContent,
                     left: rect.left, right: rect.right, width: innerWidth,
                     painted: hit === report || report.contains(hit) };
            """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        #expect(values["first"] as? String == "Start")
        #expect(values["report"] as? String == "Report")
        #expect(values["painted"] as? Bool == true)
        let left = try #require(values["left"] as? Double)
        let right = try #require(values["right"] as? Double)
        let viewportWidth = try #require(values["width"] as? Double)
        #expect(left >= 0 && right <= viewportWidth)
    }

    @Test("Shrinking past an unchanged fixed-width body switches its ready preview to source fallback")
    func viewportResizeRechecksFixedBodyWidth() async throws {
        let source = "<html><body style='width:300px;height:40px'><div style='display:flex;justify-content:space-between'><span>Start</span><span>Report</span></div></body></html>"
        let counter = PreparationCounter()
        let (view, window) = makePreview(source: source, width: 400, prepare: counter.prepare)
        defer { tearDown(view, window) }
        let ready = AsyncStream.makeStream(of: Void.self)
        view.onReady = { ready.continuation.yield(()) }
        defer { view.onReady = nil; ready.continuation.finish() }
        if !view.isReady {
            var iterator = ready.stream.makeAsyncIterator()
            try #require(await iterator.next() != nil)
        }
        let page = try #require(view.page)
        let bodyWidth = try await page.callJavaScript("return document.body.getBoundingClientRect().width", contentWorld: .defaultClient) as? Double
        #expect(bodyWidth == 300)
        #expect(view.loadCount == 1)
        #expect(await counter.count == 1)

        let failed = AsyncStream.makeStream(of: Void.self)
        view.onFailure = { failed.continuation.yield(()); failed.continuation.finish() }
        defer { view.onFailure = nil; failed.continuation.finish() }
        window.setContentSize(NSSize(width: 200, height: view.measuredHeight))
        var failedIterator = failed.stream.makeAsyncIterator()
        try #require(await failedIterator.next() != nil)
        #expect(view.hasFailed && !view.isReady)
        #expect(view.page == nil)
        #expect(view.loadCount == 1, "Viewport shrink must recheck the same page rather than load another document")
        #expect(await counter.count == 1, "Viewport validation must reuse the original preparation")
    }

    @Test("An authored short body keeps its visible overflowing report inside the bounded preview")
    func shortBodyDoesNotClipVisibleOverflow() async throws {
        let source = "<html><body style='height:20px'><div style='padding-top:100px'>Report</div></body></html>"
        let (view, window) = makePreview(source: source, width: 400)
        defer { tearDown(view, window) }
        let ready = AsyncStream.makeStream(of: Void.self)
        view.onReady = { ready.continuation.yield(()) }
        defer { view.onReady = nil; ready.continuation.finish() }
        if !view.isReady {
            var iterator = ready.stream.makeAsyncIterator()
            try #require(await iterator.next() != nil)
        }
        let page = try #require(view.page)
        let result = try await page.callJavaScript("""
            const report = document.querySelector('body > div');
            const textRange = document.createRange();
            textRange.selectNodeContents(report);
            const textRect = textRange.getBoundingClientRect();
            const reportRect = report.getBoundingClientRect();
            const hit = document.elementFromPoint(textRect.left + textRect.width / 2, textRect.top + textRect.height / 2);
            return { text: report.textContent, textTop: textRect.top, textBottom: textRect.bottom,
                     reportBottom: reportRect.bottom, bodyHeight: document.body.getBoundingClientRect().height,
                     viewportHeight: innerHeight, painted: hit === report || report.contains(hit) };
            """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        #expect(values["text"] as? String == "Report")
        #expect(values["bodyHeight"] as? Double == 20, "The author's body height is preserved")
        let textTop = try #require(values["textTop"] as? Double)
        let textBottom = try #require(values["textBottom"] as? Double)
        let reportBottom = try #require(values["reportBottom"] as? Double)
        let viewportHeight = try #require(values["viewportHeight"] as? Double)
        #expect(textTop >= 100)
        #expect(textBottom <= viewportHeight)
        #expect(view.measuredHeight >= ceil(reportBottom))
        #expect(values["painted"] as? Bool == true, "The Report text must be painted, not merely measured beyond a clipping body")
    }

    @Test("Body flex/grid layout and direct-child selectors retain their original structure", arguments: ["flex", "grid"])
    func bodyLayoutPreservesDirectChildren(display: String) async throws {
        let layout = display == "grid" ? "display:grid;grid-template-columns:120px 120px" : "display:flex;flex-direction:row"
        let source = """
            <html><head><style>
              body > .card { width:120px; height:50px; background:rgb(12,34,56); }
            </style></head><body id="report-body" class="report" style="\(layout);gap:20px;padding:10px">
              <div class="card">First report</div><div class="card">Second report</div>
            </body></html>
            """
        let (view, window) = makePreview(source: source, width: 400)
        defer { tearDown(view, window) }
        let ready = AsyncStream.makeStream(of: Void.self)
        view.onReady = { ready.continuation.yield(()) }
        defer { view.onReady = nil; ready.continuation.finish() }
        if !view.isReady {
            var iterator = ready.stream.makeAsyncIterator()
            try #require(await iterator.next() != nil)
        }
        let page = try #require(view.page)
        let result = try await page.callJavaScript("""
            const cards = document.querySelectorAll('.card');
            const first = cards[0].getBoundingClientRect();
            const second = cards[1].getBoundingClientRect();
            return { directChildren: document.querySelectorAll('body > .card').length,
                     bodyID: document.body.id, bodyClass: document.body.className,
                     display: getComputedStyle(document.body).display,
                     firstX: first.x, firstY: first.y, secondX: second.x, secondY: second.y,
                     width: first.width, height: first.height, bottom: second.bottom,
                     color: getComputedStyle(cards[0]).backgroundColor, viewportHeight: innerHeight };
            """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        #expect(values["directChildren"] as? Int == 2)
        #expect(values["bodyID"] as? String == "report-body")
        #expect(values["bodyClass"] as? String == "report")
        #expect(values["display"] as? String == display)
        #expect(values["color"] as? String == "rgb(12, 34, 56)")
        let firstX = try #require(values["firstX"] as? Double)
        let secondX = try #require(values["secondX"] as? Double)
        let firstY = try #require(values["firstY"] as? Double)
        let secondY = try #require(values["secondY"] as? Double)
        #expect(abs(secondX - firstX - 140) <= 1)
        #expect(abs(secondY - firstY) <= 1)
        #expect(values["width"] as? Double == 120)
        #expect(values["height"] as? Double == 50)
        #expect(view.measuredHeight >= 70)
        let bottom = try #require(values["bottom"] as? Double)
        let viewportHeight = try #require(values["viewportHeight"] as? Double)
        #expect(bottom <= viewportHeight)
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

    @Test("Absolute-only content in a zero-height body falls back instead of reporting clipped content as ready")
    func absoluteOnlyBodyUsesSourceFallback() async throws {
        let source = "<html><body style='position:relative'><div style='position:absolute;top:8px;height:40px;width:100px'>Report</div></body></html>"
        let (view, window) = makePreview(source: source, width: 400)
        defer { tearDown(view, window) }
        let outcome = AsyncStream.makeStream(of: Bool.self)
        view.onReady = { outcome.continuation.yield(true); outcome.continuation.finish() }
        view.onFailure = { outcome.continuation.yield(false); outcome.continuation.finish() }
        defer { view.onReady = nil; view.onFailure = nil; outcome.continuation.finish() }
        var iterator = outcome.stream.makeAsyncIterator()
        let becameReady = try #require(await iterator.next())
        // Absolute-only content has no body-flow height. Keep the source
        // fallback for this unsupported layout instead of declaring it ready.
        #expect(!becameReady)
        #expect(view.hasFailed && !view.isReady)
        #expect(view.page == nil)
        #expect(view.measuredHeight == 1)
    }

    @Test("Negative document extents use source fallback instead of clipping the report above the viewport", arguments: [
        "<html><body style='position:absolute;bottom:0;height:300px;width:100%'><div style='height:300px'>Report</div></body></html>",
        "<html><body><div style='position:relative;top:-8px;height:40px;width:100px'>Report</div></body></html>"
    ])
    func negativeDocumentExtentUsesSourceFallback(source: String) async throws {
        let (view, window) = makePreview(source: source, width: 400)
        defer { tearDown(view, window) }
        window.setContentSize(NSSize(width: 400, height: 120))
        let outcome = AsyncStream.makeStream(of: Bool.self)
        view.onReady = { outcome.continuation.yield(true); outcome.continuation.finish() }
        view.onFailure = { outcome.continuation.yield(false); outcome.continuation.finish() }
        defer { view.onReady = nil; view.onFailure = nil; outcome.continuation.finish() }
        var iterator = outcome.stream.makeAsyncIterator()
        let becameReady = try #require(await iterator.next())
        #expect(!becameReady, "A bounded bottom edge must not hide content extending above the document origin")
        #expect(view.hasFailed && !view.isReady)
        #expect(view.page == nil)
        #expect(view.measuredHeight == 1)
    }

    @Test("A viewport-fixed document body uses source fallback instead of clipping content above the preview")
    func fixedBodyUsesSourceFallback() async throws {
        let source = "<html><body style='position:fixed;bottom:0;height:300px;width:100%'><div style='height:300px'>Report</div></body></html>"
        let (view, window) = makePreview(source: source, width: 400)
        defer { tearDown(view, window) }
        let outcome = AsyncStream.makeStream(of: Bool.self)
        view.onReady = { outcome.continuation.yield(true); outcome.continuation.finish() }
        view.onFailure = { outcome.continuation.yield(false); outcome.continuation.finish() }
        defer { view.onReady = nil; view.onFailure = nil; outcome.continuation.finish() }
        var iterator = outcome.stream.makeAsyncIterator()
        let becameReady = try #require(await iterator.next())
        #expect(!becameReady, "A fixed body is unsupported even when its document-space bottom is inside the initial viewport")
        #expect(view.hasFailed)
        #expect(!view.isReady)
        #expect(view.page == nil)
        #expect(view.measuredHeight == 1)
    }

    @Test(arguments: [
        "<div style='height:5000px'>Too tall for a bounded preview</div>",
        "<html><body style='padding:40px'><div style='height:4050px'>Body spacing exceeds the bounded preview</div></body></html>",
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
