#if os(macOS)
import AppKit
import Synchronization
import Testing
@testable import PicoMarkdownView

@Suite("macOS chart loading lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct MacChartLoadingTests {
    @Test("Open charts keep one reveal deadline and exact source across appends and widths")
    func oneDeadlineAcrossAppends() async throws {
        let delay = ChartLoadingTestGate()
        defer { delay.releaseAll() }
        let model = makeModel(source: "{", timing: delay.timing)
        let request = try #require(await delay.nextRequest())
        #expect(request.duration == .milliseconds(350))
        #expect(model.isLoading)
        #expect(!model.showsLoadingPlaceholder)
        #expect(model.loadingAccessibilityLabel == nil)
        #expect(model.parseCount == 0)
        #expect(model.document == nil)
        for width: CGFloat in [1, 140, 336, 700] {
            #expect(model.viewportHeight(availableWidth: width) == 48)
            model.update(svg: "", source: "{\n  \"description\": \"Keep  spaces and 🧭\",",
                         language: "vega-lite", isClosed: false, maxWidth: width, kind: .vegaLite)
        }
        model.update(svg: "", source: source, language: "vega-lite", isClosed: false, kind: .vegaLite)
        #expect(model.source == source)
        #expect(model.parseCount == 0)
        #expect(!model.showsLoadingPlaceholder)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(model.copySource(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == source)
        #expect(model.markdownRepresentation() == "```vega-lite\n" + source + "```")
        delay.releaseAll()
        await model.waitForLoadingDelay()
        #expect(delay.requestCount == 1)
        #expect(model.showsLoadingPlaceholder)
        #expect(model.loadingActivity == .receiving)
        #expect(model.loadingAccessibilityLabel?.isEmpty == false)
        #expect(model.parseCount == 0)
    }

    @Test("Fast completion cancels a late reveal and parses the completed drawing once")
    func fastCompletionSuppressesReveal() async throws {
        let delay = ChartLoadingTestGate()
        defer { delay.releaseAll() }
        let model = makeModel(source: source, timing: delay.timing)
        _ = try #require(await delay.nextRequest())
        let close = Task { @MainActor in
            model.update(svg: svg, source: source, language: "vega-lite", isClosed: true, kind: .vegaLite)
            // The sleeper deliberately returns after cancellation; the stale
            // deadline must still be unable to reveal the placeholder.
            delay.releaseAll()
        }
        await model.waitForLoadingDelay()
        await close.value
        #expect(!model.isLoading)
        #expect(!model.showsLoadingPlaceholder)
        #expect(model.loadingAccessibilityLabel == nil)
        #expect(model.parseCount == 1)
        #expect(model.isRenderable)
        #expect(model.intrinsicSize == CGSize(width: 320, height: 160))
        #expect(model.viewportHeight(availableWidth: 320) == 160)
        model.update(svg: svg, source: source, language: "vega-lite", isClosed: true, kind: .vegaLite)
        #expect(model.parseCount == 1)
        #expect(delay.requestCount == 1)
    }

    @Test("A revealed placeholder disappears synchronously on completion without a minimum dwell")
    func revealedCompletionHasNoDwell() async throws {
        let delay = ChartLoadingTestGate()
        defer { delay.releaseAll() }
        let model = makeModel(source: source, timing: delay.timing)
        _ = try #require(await delay.nextRequest())
        delay.releaseAll()
        await model.waitForLoadingDelay()
        #expect(model.showsLoadingPlaceholder)
        model.update(svg: svg, source: source, language: "vega-lite", isClosed: true, kind: .vegaLite)
        #expect(!model.showsLoadingPlaceholder)
        #expect(!model.isLoading)
        #expect(model.isRenderable)
        #expect(model.parseCount == 1)
    }

    @Test("Pause preserves the deadline and resume preserves the revealed placeholder")
    func pausedAndResumedActivity() async throws {
        let delay = ChartLoadingTestGate()
        defer { delay.releaseAll() }
        let model = makeModel(source: "{", timing: delay.timing)
        _ = try #require(await delay.nextRequest())
        model.setLoadingActivity(.paused)
        #expect(model.loadingActivity == .paused)
        #expect(!model.showsLoadingPlaceholder)
        delay.releaseAll()
        await model.waitForLoadingDelay()
        #expect(model.showsLoadingPlaceholder)
        #expect(model.loadingActivity == .paused)
        let pausedLabel = try #require(model.loadingAccessibilityLabel)
        model.setLoadingActivity(.receiving)
        #expect(model.loadingActivity == .receiving)
        #expect(model.showsLoadingPlaceholder)
        let receivingLabel = try #require(model.loadingAccessibilityLabel)
        model.setLoadingActivity(.stopped)
        #expect(model.loadingActivity == .stopped)
        #expect(model.showsLoadingPlaceholder)
        let incompleteLabel = try #require(model.loadingAccessibilityLabel)
        #expect(Set([pausedLabel, receivingLabel, incompleteLabel]).count == 3)
        #expect(model.isLoading)
        #expect(model.parseCount == 0)
        #expect(delay.requestCount == 1)
    }

    @Test("Stopping before the deadline shows static incomplete state and rejects a late timer")
    func stopBeforeReveal() async throws {
        let delay = ChartLoadingTestGate()
        defer { delay.releaseAll() }
        let model = makeModel(source: "{\"mark\":", timing: delay.timing)
        _ = try #require(await delay.nextRequest())
        let stop = Task { @MainActor in
            model.setLoadingActivity(.stopped)
            delay.releaseAll()
        }
        await model.waitForLoadingDelay()
        await stop.value
        #expect(model.loadingActivity == .stopped)
        #expect(model.showsLoadingPlaceholder)
        #expect(model.source == "{\"mark\":")
        #expect(model.parseCount == 0)
    }

    @Test("Retiring invalid or removed loading content hides it without changing its source", arguments: [false, true])
    func retirementSuppressesLateReveal(alreadyRevealed: Bool) async throws {
        let delay = ChartLoadingTestGate()
        defer { delay.releaseAll() }
        let raw = "{\"mark\":broken"
        let model = makeModel(source: raw, timing: delay.timing)
        _ = try #require(await delay.nextRequest())
        if alreadyRevealed {
            delay.releaseAll()
            await model.waitForLoadingDelay()
            #expect(model.showsLoadingPlaceholder)
            model.finishLoading()
        } else {
            let retirement = Task { @MainActor in
                model.finishLoading()
                delay.releaseAll()
            }
            await model.waitForLoadingDelay()
            await retirement.value
        }
        #expect(!model.showsLoadingPlaceholder)
        #expect(model.loadingAccessibilityLabel == nil)
        #expect(model.loadingActivity == .stopped)
        #expect(!model.isClosed, "Retirement does not rewrite the retained block's canonical source state")
        #expect(model.source == raw)
        #expect(model.parseCount == 0)
        #expect(model.document == nil)
    }

    @Test("The pending deadline does not retain a removed model")
    func pendingTimerDoesNotRetainModel() async throws {
        let delay = ChartLoadingTestGate()
        defer { delay.releaseAll() }
        var model: PicoHostedVectorModel? = makeModel(source: "{", timing: delay.timing)
        let retained = { [weak model] in model }
        _ = try #require(await delay.nextRequest())
        model = nil
        #expect(retained() == nil)
        delay.releaseAll()
    }

    @Test("Open Mermaid previews retain their existing parsed drawing and viewport behavior")
    func mermaidDoesNotUseChartLoading() {
        let delay = ChartLoadingTestGate()
        let model = PicoHostedVectorModel(svg: svg, source: "flowchart LR\nA-->B", language: "mermaid",
                                          isClosed: false, kind: .mermaid, loadingTiming: delay.timing)
        #expect(!model.isLoading)
        #expect(!model.showsLoadingPlaceholder)
        #expect(model.isRenderable)
        #expect(model.parseCount == 1)
        #expect(model.viewportHeight(availableWidth: 320) == 160)
        model.setLoadingActivity(.paused)
        model.finishLoading()
        #expect(model.loadingActivity == .receiving)
        #expect(delay.requestCount == 0)
    }

    private let source = "{\n  \"description\": \"Keep  spaces and 🧭\",\n  \"mark\": \"bar\"\n}\n"
    private let svg = "<svg width=\"320\" height=\"160\"><rect width=\"320\" height=\"160\" fill=\"#3973d5\"/></svg>"

    private func makeModel(source: String, timing: HostedLoadingTiming) -> PicoHostedVectorModel {
        PicoHostedVectorModel(svg: "", source: source, language: "vega-lite", isClosed: false,
                              kind: .vegaLite, loadingTiming: timing)
    }
}

/// A controlled sleeper that ignores cancellation to exercise stale deadlines.
private final class ChartLoadingTestGate: Sendable {
    struct Request: Sendable { let duration: Duration }
    private struct State {
        var count = 0
        var isReleased = false
        var pending: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    private let requests: AsyncStream<Request>
    private let continuation: AsyncStream<Request>.Continuation

    init() { (requests, continuation) = AsyncStream.makeStream(of: Request.self) }
    var timing: HostedLoadingTiming { HostedLoadingTiming(sleep: { duration in await self.sleep(duration) }) }
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
            let shouldResume = state.withLock { state in
                state.count += 1
                if !state.isReleased { state.pending.append(waiter) }
                return state.isReleased
            }
            if shouldResume { waiter.resume() }
            continuation.yield(Request(duration: duration))
        }
    }
}
#endif
