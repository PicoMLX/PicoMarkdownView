#if os(macOS)
import AppKit
import SwiftUI
import Testing
import WebKit
@testable import PicoMarkdownView
@testable import PicoMarkdownViewHTML

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HTMLFactoryViewportIntegrationTests {
    @Test("A cached factory view restores its measured height in a new native hosting graph")
    func cachedFactoryViewRemountRetainsHeight() async throws {
        let context = PicoEmbeddedBlockContext(source: Self.styledSource, kind: .fencedCode(language: "html-preview"), bodyFontSize: 15)
        context.update(availableWidth: 336, isSelected: false)
        // Retain the exact factory result: recreating the factory would also
        // recreate its preparation and miss stale SwiftUI State initial values.
        let content = try #require(PicoEmbeddedBlockRenderer.htmlPreview.makeView(context))
        let first = FactoryWindow(content: content)
        defer { first.tearDown() }
        let firstContainer = try await first.waitForContainer()
        try await first.waitUntilReady(firstContainer)
        try await assertCards(in: firstContainer)
        first.layout()
        let measuredHeight = firstContainer.measuredHeight
        #expect(abs(first.host.fittingSize.height - measuredHeight) <= 1)
        first.window.contentView = nil
        #expect(firstContainer.page == nil)

        let remounted = FactoryWindow(content: content)
        defer { remounted.tearDown() }
        let nextContainer = try await remounted.waitForContainer()
        #expect(nextContainer !== firstContainer)
        try await remounted.waitUntilReady(nextContainer)
        try await assertCards(in: nextContainer)
        remounted.layout()
        #expect(nextContainer.measuredHeight == measuredHeight)
        #expect(abs(nextContainer.bounds.height - measuredHeight) <= 1,
                "The native view must not stay at a stale one-point State height after cached preparation is restored")
        #expect(abs(remounted.host.fittingSize.height - measuredHeight) <= 1)
    }

    @Test("The public Markdown view gives a styled HTML preview its full measured TextKit attachment height")
    func publicMarkdownStyledPreviewHasContentHeight() async throws {
        let input = "Before the styled preview.\n\n```html-preview\n" + Self.styledSource + "\n```\n\nAfter the styled preview.\n\n"
        let fixture = FactoryWindow(content: AnyView(PicoMarkdownView(input, embeddedBlockRenderers: [.htmlPreview])))
        defer { fixture.tearDown() }
        let container = try await fixture.waitForContainer()
        try await fixture.waitUntilReady(container)
        try await assertCards(in: container)
        fixture.layout()
        let native = try #require(fixture.textView)
        let attachment = try #require(Self.attachment(in: native))
        let sizes = AsyncStream.makeStream(of: CGSize.self)
        let previousSizeChanged = attachment.onSizeChanged
        attachment.onSizeChanged = { size in previousSizeChanged?(size); sizes.continuation.yield(size) }
        defer { attachment.onSizeChanged = previousSizeChanged; sizes.continuation.finish() }
        attachment.invalidateSize()
        var sizeIterator = sizes.stream.makeAsyncIterator()
        while abs(attachment.measuredSize.height - container.measuredHeight) > 1 {
            try #require(await sizeIterator.next() != nil)
        }
        #expect(abs(attachment.measuredSize.height - container.measuredHeight) <= 1)
        #expect(abs((attachment.hostingView?.bounds.height ?? 0) - container.measuredHeight) <= 1)
        #expect(native.string.contains("Before the styled preview."))
        #expect(native.string.contains("After the styled preview."))
        #expect(native.textLayoutManager != nil)
    }

    @Test("Streaming HTML hides raw source, retains one attachment, and loads only after closure")
    func streamedHTMLUsesStableLoadingAttachment() async throws {
        let delivery = AsyncStream.makeStream(of: String.self)
        defer { delivery.continuation.finish() }
        let fixture = FactoryWindow(content: AnyView(PicoMarkdownView(
            stream: { delivery.stream }, embeddedBlockRenderers: [.htmlPreview])))
        defer { fixture.tearDown() }
        delivery.continuation.yield("Before the preview.\n\n```html-preview\n<div style='height:120px'>First")
        let initial = try await fixture.waitForAttachment(containing: "First")
        #expect(initial.measuredSize.height == 48)
        #expect(fixture.htmlContainer == nil, "An open block must not create a browser or start sanitizing")
        let text = try #require(fixture.textView)
        #expect(!text.string.contains("<div"))
        let hostingView = initial.hostingView

        delivery.continuation.yield(" and second")
        let appended = try await fixture.waitForAttachment(containing: "First and second")
        #expect(appended === initial)
        #expect(appended.hostingView === hostingView)
        #expect(appended.measuredSize.height == 48)
        #expect(fixture.htmlContainer == nil)
        text.setSelectedRange(NSRange(location: 0, length: text.textStorage?.length ?? 0))
        #expect(text.markdownForSelection().contains("```html-preview\n<div style='height:120px'>First and second\n```"))

        delivery.continuation.yield("</div>\n```\n\nAfter the preview.\n\n")
        delivery.continuation.finish()
        let container = try await fixture.waitForContainer()
        try await fixture.waitUntilReady(container)
        fixture.layout()
        #expect(Self.attachment(in: text) === initial)
        #expect(initial.hostingView === hostingView)
        #expect(container.loadCount == 1)
        #expect(container.measuredHeight == 120)
        #expect(!text.string.contains("<div"))
        #expect(text.string.contains("Before the preview.") && text.string.contains("After the preview."))
        text.setSelectedRange(NSRange(location: 0, length: text.textStorage?.length ?? 0))
        #expect(text.markdownForSelection().contains("```html-preview\n<div style='height:120px'>First and second</div>\n```"))
    }

    @Test("Closed HTML reserves its loading card height while off-main preparation is pending", arguments: [false, true], [CGFloat(100), 336])
    func preparationShowsLoadingInsteadOfSource(fails: Bool, width: CGFloat) async throws {
        let source = "<div>" + String(repeating: "Source stays hidden while preparing. ", count: 30) + "</div>"
        let started = AsyncStream.makeStream(of: Void.self)
        let release = AsyncStream.makeStream(of: Void.self)
        defer { started.continuation.finish(); release.continuation.finish() }
        let preparation = HTMLPreviewPreparation(source: source) { source in
            started.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator()
            guard await iterator.next() != nil else { throw CancellationError() }
            if fails { throw HTMLPreviewPolicyError.invalidHTML }
            return try await HTMLPreviewPolicy.prepareOffMainActor(source: source)
        }
        // This is the same handoff used when the core closes a streamed
        // loading attachment: preparation must inherit its existing deadline.
        let sharedLoading = PicoEmbeddedLoadingState()
        sharedLoading.startLoading()
        let context = PicoEmbeddedBlockContext(source: source, kind: .htmlBlock, bodyFontSize: 15,
                                              loadingState: sharedLoading)
        context.update(availableWidth: width, isSelected: false)
        let content = HTMLPreview(context: context, preparation: preparation)
        #expect(content.loadingState === sharedLoading)
        let fixture = FactoryWindow(content: AnyView(content), width: width)
        defer { fixture.tearDown() }
        let container = try await fixture.waitForContainer()
        var starts = started.stream.makeAsyncIterator()
        try #require(await starts.next() != nil)
        fixture.layout()
        let chrome = NSHostingView(rootView: PicoEmbeddedLoadingView(state: sharedLoading, isSelected: false).frame(width: width))
        chrome.frame = NSRect(x: 0, y: 0, width: width, height: 48)
        chrome.layoutSubtreeIfNeeded()
        let loadingHeight = chrome.fittingSize.height
        #expect(abs(fixture.host.fittingSize.height - loadingHeight) <= 1,
                "The loading card must fit the attachment; raw source must not set its height")
        if width == 100 { #expect(loadingHeight > 48, "Wrapped status text needs its full intrinsic height") }
        else { #expect(loadingHeight == 48) }
        #expect(preparation.preparedContent == nil)
        #expect(container.page == nil)
        await content.loadingState.waitForLoadingDelay()
        #expect(content.loadingState.showsPlaceholder)
        #expect(content.loadingState.isLoading)
        fixture.layout()
        #expect(abs(fixture.host.fittingSize.height - loadingHeight) <= 1)

        release.continuation.yield(())
        release.continuation.finish()
        if fails {
            while !container.hasFailed { try await Task.sleep(for: .milliseconds(20)); fixture.layout() }
            await container.pendingFailureNotification?.value
            fixture.layout()
            #expect(container.page == nil)
            #expect(fixture.host.fittingSize.height > 48, "Rejected content restores the existing readable source fallback")
        } else {
            try await fixture.waitUntilReady(container)
            fixture.layout()
            #expect(container.loadCount == 1)
            #expect(preparation.preparedContent != nil)
            #expect(abs(fixture.host.fittingSize.height - container.measuredHeight) <= 1)
            #expect(container.measuredHeight > 48)
        }
        #expect(!content.loadingState.isLoading)
        #expect(!content.loadingState.showsPlaceholder)
    }

    private func assertCards(in container: HTMLPreviewContainer) async throws {
        #expect(container.isReady && !container.hasFailed)
        let page = try #require(container.page)
        let result = try await page.callJavaScript("""
            return { text: document.body.textContent,
                     height: document.body.getBoundingClientRect().height,
                     width: innerWidth };
            """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        let text = try #require(values["text"] as? String)
        #expect(text.contains("Walking time"))
        #expect(text.contains("45 min"))
        #expect(text.contains("Distance"))
        #expect(text.contains("3.2 km"))
        let height = try #require(values["height"] as? Double)
        let width = try #require(values["width"] as? Double)
        #expect(height > 100)
        #expect(abs(width - 336) <= 2)
        #expect(abs(container.measuredHeight - ceil(height)) <= 1)
    }

    private static func attachment(in text: NSTextView) -> PicoHostedAttachment? {
        var result: PicoHostedAttachment?
        guard let storage = text.textStorage else { return nil }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { result = attachment }
        }
        return result
    }

    // The example's responsive two-card markup exercises a nontrivial cached
    // height and reproduces the original narrow-window remount regression.
    private static let styledSource = """
        <style>
          .trip-summary { display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:12px; color:#203047; font-family:-apple-system,sans-serif; }
          .trip-summary article { padding:20px; border:1px solid #b8cbe2; border-radius:16px; background:#edf4fc; }
          .trip-summary h3 { margin:0 0 8px; font-size:1em; }
          .trip-summary strong { font-size:2em; }
          .trip-summary p { margin:8px 0 0; }
        </style>
        <div class="trip-summary">
          <article><h3>Walking time</h3><strong>45 min</strong><p>An easy route with a riverside stop.</p></article>
          <article><h3>Distance</h3><strong>3.2 km</strong><p>A short loop that finishes where it starts.</p></article>
        </div>
        """
}

@MainActor
private final class FactoryWindow {
    let host: NSHostingView<AnyView>
    let window: NSWindow

    init(content: AnyView, width: CGFloat = 336) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        host.frame = NSRect(x: 0, y: 0, width: width, height: 2000)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
        scroll.documentView = host
        window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        layout()
    }

    var textView: StreamingTextKit2View? { find(StreamingTextKit2View.self, in: host) }

    var htmlContainer: HTMLPreviewContainer? { find(HTMLPreviewContainer.self, in: host) }

    func waitForAttachment(containing source: String) async throws -> PicoHostedAttachment {
        while true {
            layout()
            if let storage = textView?.textStorage {
                var match: PicoHostedAttachment?
                storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                    if let attachment = value as? PicoHostedAttachment,
                       attachment.markdownRepresentation().contains(source) { match = attachment }
                }
                if let match, match.hostingView != nil { return match }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitForContainer() async throws -> HTMLPreviewContainer {
        while find(HTMLPreviewContainer.self, in: host) == nil {
            // Native SwiftUI mounts and AppKit attachment layout are serviced by
            // the app's event loop; this command-line host pumps native layout.
            try await Task.sleep(for: .milliseconds(20))
            layout()
        }
        return try #require(find(HTMLPreviewContainer.self, in: host))
    }

    func waitUntilReady(_ container: HTMLPreviewContainer) async throws {
        let ready = AsyncStream.makeStream(of: Void.self)
        container.onReady = { ready.continuation.yield(()) }
        defer { container.onReady = nil; ready.continuation.finish() }
        if !container.isReady {
            // Unlike a running NSApplication, the command-line host does not
            // service deferred SwiftUI/AppKit layout while awaiting WebKit.
            // Keep native layout moving until the actual readiness callback;
            // there is no elapsed-time readiness assumption in this wait.
            let layoutPump = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.layout()
                    do { try await Task.sleep(for: .milliseconds(20)) }
                    catch { break }
                }
            }
            defer { layoutPump.cancel() }
            var iterator = ready.stream.makeAsyncIterator()
            try #require(await iterator.next() != nil)
        }
        layout()
    }

    func layout() {
        host.layoutSubtreeIfNeeded()
        if let textView { textView.needsLayout = true; textView.layoutSubtreeIfNeeded() }
        // NSHostingView centers a short root inside an oversized document.
        // Track its fitting height so a cached short preview is actually in
        // the scroll viewport, rather than centered outside the visible area.
        let fittingHeight = host.fittingSize.height
        if fittingHeight.isFinite, fittingHeight > 0,
           abs(host.frame.height - fittingHeight) > 0.5 {
            host.setFrameSize(NSSize(width: host.frame.width, height: fittingHeight))
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func tearDown() {
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        for child in view.subviews { if let found = find(type, in: child) { return found } }
        return nil
    }
}
#endif
