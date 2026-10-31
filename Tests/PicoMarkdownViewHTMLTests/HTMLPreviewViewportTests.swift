#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownViewHTML

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HTMLPreviewViewportTests {
    @Test("Only visible HTML starts preparation, and scrolling back reuses its prepared result")
    func viewportEvictionAndReload() async throws {
        let counter = ViewportPreparationCounter()
        let fixture = ViewportFixture(prepare: counter.prepare)
        defer { fixture.tearDown() }
        let ready = AsyncStream.makeStream(of: Void.self)
        fixture.preview.onReady = { ready.continuation.yield(()) }
        defer { ready.continuation.finish() }
        var readyIterator = ready.stream.makeAsyncIterator()
        await fixture.drainVisibility()
        #expect(!fixture.preview.isInViewport)
        #expect(fixture.preview.page == nil)
        #expect(fixture.preview.loadCount == 0)
        #expect(await counter.count == 0)

        fixture.scroll(to: 900)
        await fixture.drainVisibility()
        try #require(await readyIterator.next() != nil)
        #expect(fixture.preview.isInViewport && fixture.preview.isReady)
        #expect(fixture.preview.loadCount == 1)
        #expect(await counter.count == 1)
        let measuredHeight = fixture.preview.measuredHeight

        fixture.scroll(to: 0)
        await fixture.drainVisibility()
        #expect(!fixture.preview.isInViewport && !fixture.preview.isReady)
        #expect(fixture.preview.page == nil)
        #expect(fixture.preview.measuredHeight == measuredHeight)

        fixture.scroll(to: 900)
        await fixture.drainVisibility()
        try #require(await readyIterator.next() != nil)
        #expect(fixture.preview.isReady)
        #expect(fixture.preview.loadCount == 2)
        #expect(fixture.preview.measuredHeight == measuredHeight)
        #expect(await counter.count == 1, "Viewport eviction must preserve source preparation")
    }

    @Test("A preview loads when its top is clipped but its lower portion is visible")
    func partiallyVisibleAttachmentLoads() async throws {
        let counter = ViewportPreparationCounter()
        let fixture = ViewportFixture(prepare: counter.prepare)
        defer { fixture.tearDown() }
        let ready = AsyncStream.makeStream(of: Void.self)
        fixture.preview.onReady = { ready.continuation.yield(()) }
        defer { ready.continuation.finish() }
        fixture.scroll(to: 1080)
        await fixture.drainVisibility()
        var readyIterator = ready.stream.makeAsyncIterator()
        try #require(await readyIterator.next() != nil)
        #expect(fixture.preview.visibleRect.minY > fixture.preview.bounds.minY)
        #expect(fixture.preview.visibleRect.height > 0)
        #expect(fixture.preview.isInViewport && fixture.preview.isReady)
        #expect(await counter.count == 1)
    }

    @Test("A preview must intersect both nested scroll viewports")
    func nestedClippingControlsPresentation() async throws {
        let counter = ViewportPreparationCounter()
        let fixture = ViewportFixture(origin: 0, prepare: counter.prepare, nested: true)
        defer { fixture.tearDown() }
        let ready = AsyncStream.makeStream(of: Void.self)
        fixture.preview.onReady = { ready.continuation.yield(()) }
        defer { ready.continuation.finish() }
        let innerScroll = try #require(fixture.innerScroll)
        innerScroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        innerScroll.reflectScrolledClipView(innerScroll.contentView)
        await fixture.drainVisibility()
        #expect(!fixture.preview.isInViewport)
        #expect(await counter.count == 0)

        fixture.scroll(to: 900)
        await fixture.drainVisibility()
        #expect(!fixture.preview.isInViewport, "The outer viewport cannot override inner clipping")
        #expect(await counter.count == 0)

        innerScroll.contentView.scroll(to: .zero)
        innerScroll.reflectScrolledClipView(innerScroll.contentView)
        await fixture.drainVisibility()
        var readyIterator = ready.stream.makeAsyncIterator()
        try #require(await readyIterator.next() != nil)
        #expect(fixture.preview.isInViewport && fixture.preview.isReady)

        fixture.scroll(to: 0)
        await fixture.drainVisibility()
        #expect(!fixture.preview.isInViewport)
        #expect(fixture.preview.page == nil)
        #expect(await counter.count == 1)
    }

    @Test("Hiding or repositioning an ancestor updates visibility without a scroll")
    func hiddenAndRepositionedAncestor() async throws {
        let counter = ViewportPreparationCounter()
        let fixture = ViewportFixture(origin: 40, prepare: counter.prepare)
        defer { fixture.tearDown() }
        let ready = AsyncStream.makeStream(of: Void.self)
        fixture.preview.onReady = { ready.continuation.yield(()) }
        defer { ready.continuation.finish() }
        var readyIterator = ready.stream.makeAsyncIterator()
        await fixture.drainVisibility()
        try #require(await readyIterator.next() != nil)
        fixture.holder.isHidden = true
        await fixture.drainVisibility()
        #expect(!fixture.preview.isInViewport)
        #expect(fixture.preview.page == nil)
        fixture.holder.isHidden = false
        await fixture.drainVisibility()
        try #require(await readyIterator.next() != nil)

        fixture.holder.setFrameOrigin(NSPoint(x: 20, y: 1000))
        await fixture.drainVisibility()
        #expect(!fixture.preview.isInViewport)
        #expect(fixture.preview.page == nil)
        fixture.holder.setFrameOrigin(NSPoint(x: 20, y: 60))
        await fixture.drainVisibility()
        try #require(await readyIterator.next() != nil)
        #expect(fixture.preview.isReady)
        #expect(fixture.preview.loadCount == 3)
        #expect(await counter.count == 1)
    }

    @Test("Preparation completed after scrolling away cannot install an offscreen page")
    func pendingPreparationCannotInstallAfterExit() async throws {
        let gate = ViewportPreparationGate()
        let fixture = ViewportFixture(origin: 40, prepare: { try await gate.prepare($0) })
        defer { fixture.tearDown() }
        await fixture.drainVisibility()
        try await gate.waitUntilStarted()
        let stalePresentation = try #require(fixture.preview.pendingPresentation)
        fixture.scroll(to: 700)
        await fixture.drainVisibility()
        #expect(!fixture.preview.isInViewport)
        let prepared = try HTMLPreviewPolicy.prepare(source: fixture.source)
        await gate.succeed(prepared)
        await stalePresentation.value
        #expect(fixture.preview.page == nil)
        #expect(fixture.preview.loadCount == 0)
        #expect(!fixture.preview.isReady)

        let ready = AsyncStream.makeStream(of: Void.self)
        fixture.preview.onReady = { ready.continuation.yield(()) }
        defer { ready.continuation.finish() }
        fixture.scroll(to: 0)
        await fixture.drainVisibility()
        var readyIterator = ready.stream.makeAsyncIterator()
        try #require(await readyIterator.next() != nil)
        #expect(fixture.preview.loadCount == 1)
        #expect(await gate.count == 1)
    }

    @Test("A replacement native container restores the source owner's cached height and preparation")
    func newContainerReusesPreparationAndMeasurement() async throws {
        let counter = ViewportPreparationCounter()
        let source = "<div style='height:180px'>A recreated native preview.</div>"
        let preparation = HTMLPreviewPreparation(source: source, prepare: counter.prepare)
        let first = ViewportFixture(source: source, origin: 40, prepare: counter.prepare, preparation: preparation)
        defer { first.tearDown() }
        let firstReady = AsyncStream.makeStream(of: Void.self)
        first.preview.onReady = { firstReady.continuation.yield(()) }
        defer { firstReady.continuation.finish() }
        await first.drainVisibility()
        var firstReadyIterator = firstReady.stream.makeAsyncIterator()
        try #require(await firstReadyIterator.next() != nil)
        let measuredHeight = first.preview.measuredHeight
        try #require(measuredHeight > 120)
        #expect(preparation.measuredHeight == measuredHeight)
        first.window.contentView = nil
        #expect(first.preview.page == nil)

        let replacement = ViewportFixture(source: source, origin: 40, prepare: counter.prepare, preparation: preparation)
        defer { replacement.tearDown() }
        #expect(replacement.preview.measuredHeight == measuredHeight,
                "The recreated native view restores size before loading its browser")
        #expect(replacement.preview.loadCount == 0)
        let replacementReady = AsyncStream.makeStream(of: Void.self)
        replacement.preview.onReady = { replacementReady.continuation.yield(()) }
        defer { replacementReady.continuation.finish() }
        await replacement.drainVisibility()
        var replacementIterator = replacementReady.stream.makeAsyncIterator()
        try #require(await replacementIterator.next() != nil)
        #expect(replacement.preview.isReady)
        #expect(replacement.preview.measuredHeight == measuredHeight)
        #expect(replacement.preview.loadCount == 1)
        #expect(await counter.count == 1)
    }

    @Test("Offscreen keyboard focus pins a host until first-responder changes wake the tracker")
    func focusedHostRemainsEligibleUntilFocusLeaves() async throws {
        _ = NSApplication.shared
        let document = FlippedViewportDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        let attachment = NSView(frame: NSRect(x: 20, y: 40, width: 320, height: 120))
        let host = NSView(frame: attachment.bounds)
        let focused = FocusableViewportView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        let outside = FocusableViewportView(frame: NSRect(x: 0, y: 500, width: 40, height: 40))
        host.addSubview(focused)
        attachment.addSubview(host)
        document.addSubview(attachment)
        document.addSubview(outside)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        scroll.documentView = document
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 400, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        try #require(window.makeFirstResponder(focused))
        let focusLeft = AsyncStream.makeStream(of: Void.self)
        let viewport = HTMLPreviewViewport(view: attachment) {
            if window.firstResponder !== focused { focusLeft.continuation.yield(()) }
        }
        defer {
            viewport.stop()
            focusLeft.continuation.finish()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        while let pending = viewport.pendingUpdate { await pending.value }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        scroll.reflectScrolledClipView(scroll.contentView)
        while let pending = viewport.pendingUpdate { await pending.value }
        #expect(!viewport.isEligible(pinning: nil), "The attachment is geometrically outside the viewport")
        #expect(viewport.isEligible(pinning: host), "Removing the browser must not discard active keyboard focus")

        try #require(window.makeFirstResponder(outside))
        var focusLeftIterator = focusLeft.stream.makeAsyncIterator()
        // No scroll, geometry change, or manual scheduling follows the focus
        // change: the first-responder observation must wake this callback.
        try #require(await focusLeftIterator.next() != nil)
        #expect(!viewport.isEligible(pinning: host))
    }

    @Test("Offscreen width and appearance changes retain height and wait to reload")
    func offscreenLayoutChangesWaitForVisibility() async throws {
        let counter = ViewportPreparationCounter()
        let source = "<p>" + String(repeating: "Responsive text wraps within the available width. ", count: 12) + "</p>"
        let fixture = ViewportFixture(source: source, prepare: counter.prepare)
        defer { fixture.tearDown() }
        let ready = AsyncStream.makeStream(of: Void.self)
        fixture.preview.onReady = { ready.continuation.yield(()) }
        defer { ready.continuation.finish() }
        var readyIterator = ready.stream.makeAsyncIterator()
        fixture.scroll(to: 900)
        await fixture.drainVisibility()
        try #require(await readyIterator.next() != nil)
        let wideHeight = fixture.preview.measuredHeight
        fixture.scroll(to: 0)
        await fixture.drainVisibility()
        var style = HTMLPreviewStyle.default
        style.isDark = true
        style.fontSize = 24
        fixture.preview.configure(source: source, style: style)
        fixture.setPreviewWidth(180)
        await fixture.drainVisibility()
        #expect(!fixture.preview.isInViewport)
        #expect(fixture.preview.page == nil)
        #expect(fixture.preview.loadCount == 1)
        #expect(fixture.preview.measuredHeight == wideHeight)
        #expect(await counter.count == 1)

        fixture.scroll(to: 900)
        await fixture.drainVisibility()
        try #require(await readyIterator.next() != nil)
        #expect(fixture.preview.isReady)
        #expect(fixture.preview.loadCount == 2)
        #expect(fixture.preview.measuredHeight > wideHeight)
        #expect(await counter.count == 1)
    }
}

@MainActor
private final class ViewportFixture {
    let source: String
    let window: NSWindow
    let scroll: NSScrollView
    let innerScroll: NSScrollView?
    let document: FlippedViewportDocument
    let holder: FlippedViewportDocument
    let preview: HTMLPreviewContainer

    init(source: String = "<div style='height:120px'>A source-backed preview.</div>",
         origin: CGFloat = 1000, prepare: @escaping HTMLPreviewPreparation.Prepare,
         nested: Bool = false, preparation: HTMLPreviewPreparation? = nil) {
        _ = NSApplication.shared
        self.source = source
        document = FlippedViewportDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        holder = FlippedViewportDocument(frame: NSRect(x: 20, y: origin, width: 320, height: 120))
        preview = HTMLPreviewContainer(preparation: preparation, prepare: prepare)
        preview.frame = holder.bounds
        holder.addSubview(preview)
        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        scroll.borderType = .noBorder
        scroll.documentView = document
        if nested {
            let innerDocument = FlippedViewportDocument(frame: NSRect(x: 0, y: 0, width: 380, height: 1000))
            innerDocument.addSubview(holder)
            let inner = NSScrollView(frame: NSRect(x: 0, y: 1000, width: 380, height: 200))
            inner.borderType = .noBorder
            inner.documentView = innerDocument
            document.addSubview(inner)
            innerScroll = inner
        } else {
            document.addSubview(holder)
            innerScroll = nil
        }
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 400, height: 240),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        preview.onHeight = { [weak preview, weak holder] height in
            guard let preview, let holder else { return }
            preview.setFrameSize(NSSize(width: preview.frame.width, height: height))
            holder.setFrameSize(NSSize(width: holder.frame.width, height: height))
        }
        preview.configure(source: source, style: .default)
        window.contentView = scroll
        window.orderFront(nil)
    }

    func scroll(to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func setPreviewWidth(_ width: CGFloat) {
        holder.setFrameSize(NSSize(width: width, height: holder.frame.height))
        preview.setFrameSize(NSSize(width: width, height: preview.frame.height))
    }

    func drainVisibility() async {
        window.contentView?.layoutSubtreeIfNeeded()
        while let pending = preview.pendingVisibilityUpdate { await pending.value }
    }

    func tearDown() {
        preview.suspend()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class FlippedViewportDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class FocusableViewportView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private actor ViewportPreparationCounter {
    private(set) var count = 0
    func prepare(source: String) async throws -> HTMLPreparedContent {
        count += 1
        return try await HTMLPreviewPolicy.prepareOffMainActor(source: source)
    }
}

private actor ViewportPreparationGate {
    private(set) var count = 0
    private var pending: AsyncThrowingStream<HTMLPreparedContent, any Error>.Continuation?
    private var started: AsyncStream<Void>.Continuation?

    func prepare(_ source: String) async throws -> HTMLPreparedContent {
        count += 1
        let gate = AsyncThrowingStream.makeStream(of: HTMLPreparedContent.self)
        pending = gate.continuation
        started?.yield(())
        started?.finish()
        var iterator = gate.stream.makeAsyncIterator()
        guard let result = try await iterator.next() else { throw CancellationError() }
        return result
    }

    func waitUntilStarted() async throws {
        guard count == 0 else { return }
        let gate = AsyncStream.makeStream(of: Void.self)
        started = gate.continuation
        defer { started = nil }
        for await _ in gate.stream { break }
        try Task.checkCancellation()
    }

    func succeed(_ content: HTMLPreparedContent) {
        pending?.yield(content)
        pending?.finish()
        pending = nil
    }
}
#endif
