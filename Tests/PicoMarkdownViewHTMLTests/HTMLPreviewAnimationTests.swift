#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import PicoMarkdownViewHTML

@MainActor
@Suite("Static HTML motion policy", .serialized, .timeLimit(.minutes(1)))
struct HTMLPreviewAnimationTests {
    @Test("Post-readiness activation of hover rules stays static", arguments: ["hover", "inline", "pseudo", "nested", "prefixed"])
    func postReadinessActivationStaysStatic(scenario: String) async throws {
        let fixture = MotionPreviewFixture(source: source(for: scenario))
        defer { fixture.close() }
        let page = try await fixture.readyPage()
        let measuredHeight = fixture.view.measuredHeight
        let loadCount = fixture.view.loadCount
        let pseudo = scenario == "pseudo"

        if scenario == "nested" {
            // This media rule was inactive when document-end sanitization ran.
            fixture.resize(width: 620)
            try await fixture.waitForWidth(620, page: page)
        }
        // CLI test windows are inactive, so native pointer events cannot
        // reliably establish :hover. The paired selector activates the exact
        // same CSSStyleDeclaration after readiness without changing its rules.
        _ = try await page.callJavaScript("document.getElementById('probe').classList.add('pico-test-hover'); return true", contentWorld: .defaultClient)
        try await assertStatic(page: page, pseudo: pseudo)
        #expect(fixture.view.measuredHeight == measuredHeight)
        #expect(fixture.view.page === page && fixture.view.loadCount == loadCount)

        fixture.resize(width: 680)
        try await fixture.waitForWidth(680, page: page)
        _ = try await page.callJavaScript("await document.fonts.ready; return true", contentWorld: .defaultClient)
        try await assertStatic(page: page, pseudo: pseudo)
        #expect(fixture.view.measuredHeight == measuredHeight)
        #expect(fixture.view.page === page && fixture.view.loadCount == loadCount)
        #expect(fixture.view.isReady && !fixture.view.hasFailed)
    }

    private func source(for scenario: String) -> String {
        let motion = "animation:pulse 1s infinite!important;transition:color 1s!important;"
        let sentinel = "color:rgb(12,34,56)!important;"
        let selector = "#probe:hover, #probe.pico-test-hover"
        var rules = "\(selector) { \(sentinel) \(motion) }"
        var inline = ""
        if scenario == "inline" {
            inline = " style='\(motion)'"
            rules = "\(selector) { \(sentinel) }"
        } else if scenario == "pseudo" {
            rules = "#probe::after { content:' Status'; } \(selector) { \(sentinel) } #probe:hover::after, #probe.pico-test-hover::after { \(motion) }"
        } else if scenario == "nested" {
            rules = "@media (min-width:480px) { @supports (display:block) { @layer author-motion { \(selector) { \(sentinel) \(motion) } } } }"
        } else if scenario == "prefixed" {
            rules = "\(selector) { \(sentinel) -webkit-animation:pulse 1s infinite!important;-webkit-transition:color 1s!important; }"
        }
        return """
        <style>
          @keyframes pulse { from { opacity:1; } to { opacity:0.25; } }
          #probe { margin:0;height:40px;line-height:40px;color:rgb(1,2,3); }
          \(rules)
        </style>
        <p id='probe'\(inline)>Static report</p>
        """
    }

    private func assertStatic(page: WebPage, pseudo: Bool) async throws {
        let result = try await page.callJavaScript("""
            const probe = document.getElementById('probe');
            const style = getComputedStyle(probe, \(pseudo ? "'::after'" : "null"));
            let hoverRules = 0, motionDeclarations = 0;
            const countMotion = declaration => {
              for (const name of Array.from(declaration)) {
                if (name.startsWith('animation') || name.startsWith('transition')
                  || name.startsWith('-webkit-animation') || name.startsWith('-webkit-transition')) motionDeclarations++;
              }
            };
            const inspect = rules => {
              for (const rule of Array.from(rules)) {
                if (rule.selectorText?.includes(':hover')) hoverRules++;
                if (rule.style) countMotion(rule.style);
                if (rule.cssRules) inspect(rule.cssRules);
              }
            };
            for (const sheet of Array.from(document.styleSheets)) {
              if (!sheet.ownerNode?.hasAttribute('data-pico-static-motion')) inspect(sheet.cssRules);
            }
            for (const element of document.querySelectorAll('[style]')) countMotion(element.style);
            return { activated:probe.matches('.pico-test-hover'), color:getComputedStyle(probe).color,
                     hoverRules, motionDeclarations, animations:document.getAnimations().length,
                     name:style.animationName, duration:style.animationDuration, transition:style.transitionDuration };
            """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        #expect(values["activated"] as? Bool == true)
        #expect(values["color"] as? String == "rgb(12, 34, 56)", "Harmless styling in the original hover rule must remain functional")
        #expect((values["hoverRules"] as? Int ?? 0) > 0, "The actual :hover selectors must remain present")
        #expect(values["motionDeclarations"] as? Int == 0, "The real hover rules, inactive groups and inline styles must all be static")
        #expect(values["animations"] as? Int == 0)
        #expect(values["name"] as? String == "none")
        #expect(values["duration"] as? String == "0s")
        #expect(values["transition"] as? String == "0s")
    }
}

@MainActor
private final class MotionPreviewFixture {
    let view = HTMLPreviewContainer()
    let window: NSWindow
    private let outcome = AsyncStream.makeStream(of: Bool.self)

    init(source: String) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 320, height: 80),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.onReady = { [outcome] in outcome.continuation.yield(true); outcome.continuation.finish() }
        view.onFailure = { [outcome] in outcome.continuation.yield(false); outcome.continuation.finish() }
        view.onHeight = { [weak window] height in
            guard let window else { return }
            window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: height))
        }
        view.configure(source: source, style: .default)
        window.contentView = view
        window.orderFront(nil)
    }

    func readyPage() async throws -> WebPage {
        var iterator = outcome.stream.makeAsyncIterator()
        try #require(await iterator.next() == true, "The source must reach a visible static preview")
        return try #require(view.page)
    }

    func resize(width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: max(1, view.measuredHeight)))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func waitForWidth(_ width: Int, page: WebPage) async throws {
        while try await page.callJavaScript("return innerWidth", contentWorld: .defaultClient) as? Int != width {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
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
