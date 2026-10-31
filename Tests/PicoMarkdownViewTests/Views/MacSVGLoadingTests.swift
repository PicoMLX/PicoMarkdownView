#if os(macOS)
import AppKit
import Synchronization
import Testing
@testable import PicoMarkdownView

@Suite("macOS SVG loading lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct MacSVGLoadingTests {
    @Test("An open SVG waits once before showing its compact loading presentation")
    func oneDelayAcrossStreamingUpdates() async throws {
        let delay = SVGLoadingTestGate()
        defer { delay.releaseAll() }
        let model = makeModel(source: "<svg", timing: delay.timing)
        let request = try #require(await delay.nextRequest())
        #expect(request.duration == .milliseconds(350))
        #expect(model.isLoadingSVG)
        #expect(!model.showsLoadingPlaceholder)
        #expect(model.parseCount == 0)
        #expect(model.document == nil)
        for width: CGFloat in [1, 180, 640] {
            #expect(model.viewportHeight(availableWidth: width) == 48)
        }
        let received = "<svg xmlns=\"http://www.w3.org/2000/svg\">\n  <text>🧭 &amp; progress  "
        for prefix in ["<svg xmlns=\"http://", "<svg xmlns=\"http://www.w3.org/2000/svg\">\n", received] {
            model.update(svg: prefix, source: prefix, language: "svg", isClosed: false)
        }
        #expect(model.source == received)
        #expect(model.parseCount == 0)
        #expect(!model.showsLoadingPlaceholder)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(model.copySource(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == received)
        #expect(model.markdownRepresentation() == "```svg\n" + received + "\n```")

        delay.releaseAll()
        await model.waitForSVGLoadingDelay()
        #expect(delay.requestCount == 1, "Source appends must keep the original reveal deadline")
        #expect(model.showsLoadingPlaceholder)
        #expect(model.isLoadingSVG)
        #expect(model.loadingActivity == .receiving)
        #expect(model.parseCount == 0)
    }

    @Test("Closing before the delay suppresses late loading UI and decodes unchanged source once")
    func fastCloseCancelsReveal() async throws {
        let delay = SVGLoadingTestGate()
        defer { delay.releaseAll() }
        let model = makeModel(source: source, timing: delay.timing)
        _ = try #require(await delay.nextRequest())
        #expect(model.parseCount == 0)
        let close = Task { @MainActor in
            model.update(svg: source, source: source, language: "svg", isClosed: true)
            // The test sleeper intentionally returns after cancellation. The
            // model must reject that old timer's result rather than reveal it.
            delay.releaseAll()
        }
        await model.waitForSVGLoadingDelay()
        await close.value
        #expect(delay.requestCount == 1)
        #expect(!model.isLoadingSVG)
        #expect(!model.showsLoadingPlaceholder)
        #expect(model.parseCount == 1)
        #expect(model.isRenderable)
        #expect(model.intrinsicSize == CGSize(width: 320, height: 160))
        model.update(svg: source, source: source, language: "svg", isClosed: true)
        #expect(model.parseCount == 1)
    }

    @Test("Pause retains the reveal deadline and stop leaves a static incomplete graphic")
    func pausedAndStoppedActivity() async throws {
        let delay = SVGLoadingTestGate()
        defer { delay.releaseAll() }
        let model = makeModel(source: "<svg", timing: delay.timing)
        _ = try #require(await delay.nextRequest())
        model.setLoadingActivity(.paused)
        #expect(model.loadingActivity == .paused)
        #expect(!model.showsLoadingPlaceholder)
        delay.releaseAll()
        await model.waitForSVGLoadingDelay()
        #expect(model.showsLoadingPlaceholder)
        #expect(model.loadingActivity == .paused, "The view uses this static state instead of a receiving spinner")
        #expect(model.parseCount == 0)
        model.setLoadingActivity(.receiving)
        #expect(model.loadingActivity == .receiving)
        #expect(model.showsLoadingPlaceholder)
        model.setLoadingActivity(.stopped)
        #expect(model.loadingActivity == .stopped)
        #expect(model.showsLoadingPlaceholder)
        #expect(model.isLoadingSVG)
        #expect(delay.requestCount == 1)
        #expect(model.parseCount == 0)
    }

    @Test("Stopping before the reveal shows incomplete state and suppresses the canceled timer")
    func stopCancelsDelayedReveal() async throws {
        let delay = SVGLoadingTestGate()
        defer { delay.releaseAll() }
        let model = makeModel(source: "<svg><rect", timing: delay.timing)
        _ = try #require(await delay.nextRequest())
        let stop = Task { @MainActor in
            model.setLoadingActivity(.stopped)
            delay.releaseAll()
        }
        await model.waitForSVGLoadingDelay()
        await stop.value
        #expect(model.loadingActivity == .stopped)
        #expect(model.showsLoadingPlaceholder)
        #expect(model.parseCount == 0)
        #expect(model.source == "<svg><rect")
        #expect(delay.requestCount == 1)
    }

    @Test("An invalid final SVG retires loading without retaining a partial drawing")
    func invalidCloseFinishesLoading() async throws {
        let delay = SVGLoadingTestGate()
        defer { delay.releaseAll() }
        let raw = "<svg><rect"
        let model = makeModel(source: raw, timing: delay.timing)
        _ = try #require(await delay.nextRequest())
        delay.releaseAll()
        await model.waitForSVGLoadingDelay()
        #expect(model.showsLoadingPlaceholder)
        model.update(svg: raw, source: raw, language: "svg", isClosed: true)
        #expect(!model.isLoadingSVG)
        #expect(!model.showsLoadingPlaceholder)
        #expect(!model.isRenderable)
        #expect(model.document == nil)
        #expect(model.parseCount == 1)
        #expect(model.source == raw)
    }

    private let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"320\" height=\"160\"><rect width=\"320\" height=\"160\" fill=\"#3973d5\"/></svg>"

    private func makeModel(source: String, timing: SVGLoadingTiming) -> PicoHostedVectorModel {
        PicoHostedVectorModel(svg: source, source: source, language: "svg", isClosed: false,
                              kind: .svg, loadingTiming: timing)
    }
}

/// A controlled sleeper that deliberately ignores Task cancellation. Tests can
/// release an old delay after closure and await the actual presentation task,
/// without guessing a wall-clock deadline or MainActor scheduling order.
private final class SVGLoadingTestGate: Sendable {
    struct Request: Sendable {
        let id: Int
        let duration: Duration
    }
    private struct State {
        var count = 0
        var isReleased = false
        var pending: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    private let requests: AsyncStream<Request>
    private let continuation: AsyncStream<Request>.Continuation

    init() {
        (requests, continuation) = AsyncStream.makeStream(of: Request.self)
    }

    var timing: SVGLoadingTiming {
        SVGLoadingTiming(sleep: { duration in await self.sleep(duration) })
    }

    var requestCount: Int { state.withLock { $0.count } }

    func nextRequest() async -> Request? {
        var iterator = requests.makeAsyncIterator()
        return await iterator.next()
    }

    func releaseAll() {
        let pending = state.withLock { state in
            state.isReleased = true
            let pending = state.pending
            state.pending.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume() }
    }

    private func sleep(_ duration: Duration) async {
        await withCheckedContinuation { waiter in
            let (request, shouldResume) = state.withLock { state in
                state.count += 1
                if !state.isReleased { state.pending.append(waiter) }
                return (Request(id: state.count, duration: duration), state.isReleased)
            }
            if shouldResume { waiter.resume() }
            continuation.yield(request)
        }
    }
}
#endif
