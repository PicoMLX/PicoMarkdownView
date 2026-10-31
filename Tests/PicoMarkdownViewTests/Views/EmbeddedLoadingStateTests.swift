#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import PicoMarkdownView

@MainActor
@Suite("Embedded loading deadline", .timeLimit(.minutes(1)))
struct EmbeddedLoadingStateTests {
    @Test("A delayed placeholder is idle initially and source appends cannot restart its timer")
    func firstLoadingDelayIsOneShot() async throws {
        let clock = EmbeddedLoadingTestClock()
        defer { clock.releaseAll() }
        let state = PicoEmbeddedLoadingState(timing: clock.timing)
        #expect(!state.isLoading && !state.showsPlaceholder)
        #expect(state.activity == .receiving)
        #expect(PicoEmbeddedLoadingState.height == 48)
        state.startLoading()
        let request = try #require(await clock.nextRequest())
        #expect(request.duration == .milliseconds(350))
        for _ in 0..<10 { state.startLoading() }
        #expect(clock.requestCount == 1)
        #expect(state.isLoading && !state.showsPlaceholder)
        clock.advance(by: .milliseconds(350))
        clock.release(request.id)
        await state.waitForLoadingDelay()
        #expect(state.isLoading && state.showsPlaceholder)
        state.finishLoading()
        #expect(!state.isLoading && !state.showsPlaceholder)
    }

    @Test("A busy UI actor cannot extend the absolute reveal deadline")
    func delayedTaskStartUsesElapsedDeadline() async {
        let clock = EmbeddedLoadingTestClock()
        defer { clock.releaseAll() }
        let state = PicoEmbeddedLoadingState(timing: clock.timing)
        state.startLoading()
        // No suspension lets the queued reveal begin before time advances.
        clock.advance(by: .seconds(1))
        await state.waitForLoadingDelay()
        #expect(state.isLoading && state.showsPlaceholder)
        #expect(clock.requestCount == 0, "A reveal task starting after the source deadline must not sleep again")
    }

    @Test("Finishing rejects the old timer and a new presentation uses the original remaining delay")
    func presentationRestartRetainsDeadline() async throws {
        let clock = EmbeddedLoadingTestClock()
        defer { clock.releaseAll() }
        let state = PicoEmbeddedLoadingState(timing: clock.timing)
        state.startLoading()
        let first = try #require(await clock.nextRequest())
        let replace = Task { @MainActor in
            state.finishLoading()
            clock.advance(by: .milliseconds(100))
            state.startLoading()
            // This sleeper deliberately ignores cancellation: the original
            // completion must not reveal or clear the replacement's timer.
            clock.release(first.id)
        }
        await state.waitForLoadingDelay()
        await replace.value
        let second = try #require(await clock.nextRequest())
        #expect(second.duration == .milliseconds(250))
        #expect(state.isLoading && !state.showsPlaceholder)
        #expect(clock.requestCount == 2)
        clock.advance(by: .milliseconds(250))
        clock.release(second.id)
        await state.waitForLoadingDelay()
        #expect(state.isLoading && state.showsPlaceholder)
    }

    @Test("Fast completion suppresses late UI and reattachment after the deadline reveals immediately")
    func completedDeadlineIsNotReset() async throws {
        let clock = EmbeddedLoadingTestClock()
        defer { clock.releaseAll() }
        let state = PicoEmbeddedLoadingState(timing: clock.timing)
        state.startLoading()
        let request = try #require(await clock.nextRequest())
        let finish = Task { @MainActor in
            state.finishLoading()
            clock.release(request.id)
        }
        await state.waitForLoadingDelay()
        await finish.value
        #expect(!state.isLoading && !state.showsPlaceholder)
        clock.advance(by: .seconds(1))
        state.startLoading()
        #expect(state.isLoading && state.showsPlaceholder)
        #expect(clock.requestCount == 1, "An elapsed source deadline must not sleep again")
        await state.waitForLoadingDelay()
    }

    @Test("Pause keeps the deadline, while stopped loading is immediate and static")
    func activityDoesNotRestartDeadline() async throws {
        let clock = EmbeddedLoadingTestClock()
        defer { clock.releaseAll() }
        let state = PicoEmbeddedLoadingState(timing: clock.timing)
        state.startLoading()
        let request = try #require(await clock.nextRequest())
        state.setActivity(.paused)
        #expect(!state.showsPlaceholder && state.activity == .paused)
        clock.advance(by: .milliseconds(350))
        clock.release(request.id)
        await state.waitForLoadingDelay()
        #expect(state.showsPlaceholder && state.activity == .paused)
        state.setActivity(.receiving)
        #expect(state.showsPlaceholder && state.activity == .receiving)
        state.setActivity(.stopped)
        #expect(state.isLoading && state.showsPlaceholder && state.activity == .stopped)
        state.finishLoading()
        #expect(!state.isLoading && !state.showsPlaceholder)
        #expect(clock.requestCount == 1)
    }

    @Test("Stopping before the reveal cancels its timer without resurrecting finished loading")
    func stopBeforeDeadlineIsImmediate() async throws {
        let clock = EmbeddedLoadingTestClock()
        defer { clock.releaseAll() }
        let state = PicoEmbeddedLoadingState(timing: clock.timing)
        state.startLoading()
        let request = try #require(await clock.nextRequest())
        let stop = Task { @MainActor in
            state.setActivity(.stopped)
            #expect(state.isLoading && state.showsPlaceholder)
            state.finishLoading()
            clock.release(request.id)
        }
        await state.waitForLoadingDelay()
        await stop.value
        #expect(!state.isLoading && !state.showsPlaceholder)
        state.setActivity(.receiving)
        #expect(!state.isLoading && !state.showsPlaceholder)
        state.setActivity(.stopped)
        #expect(!state.isLoading && !state.showsPlaceholder)
        state.startLoading()
        #expect(state.isLoading && state.showsPlaceholder)
        #expect(clock.requestCount == 1)
    }

    @Test("Discarding loading state cancels its worker without retaining the state")
    func discardedStateCancelsWorker() async throws {
        let clock = EmbeddedLoadingTestClock()
        defer { clock.releaseAll() }
        var state: PicoEmbeddedLoadingState? = PicoEmbeddedLoadingState(timing: clock.timing)
        weak let weakState = state
        state?.startLoading()
        let request = try #require(await clock.nextRequest())
        state = nil
        #expect(weakState == nil, "The suspended reveal must not retain its source-owned state")
        clock.release(request.id)
        let completion = try #require(await clock.nextCompletion())
        #expect(completion.id == request.id)
        #expect(completion.wasCancelled)
    }
}

/// The sleeper intentionally completes after cancellation so the production
/// task's cancellation and generation guards remain part of the regression.
private final class EmbeddedLoadingTestClock: Sendable {
    struct Request: Sendable { let id: Int; let duration: Duration }
    struct Completion: Sendable { let id: Int; let wasCancelled: Bool }
    private struct State {
        var now = ContinuousClock.now
        var count = 0
        var releasesAll = false
        var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    }
    private let state = Mutex(State())
    private let requests: AsyncStream<Request>
    private let requestContinuation: AsyncStream<Request>.Continuation
    private let completions: AsyncStream<Completion>
    private let completionContinuation: AsyncStream<Completion>.Continuation

    init() {
        (requests, requestContinuation) = AsyncStream.makeStream(of: Request.self)
        (completions, completionContinuation) = AsyncStream.makeStream(of: Completion.self)
    }

    var timing: PicoEmbeddedLoadingTiming {
        PicoEmbeddedLoadingTiming(now: { self.state.withLock { $0.now } },
                                  sleep: { await self.sleep($0) })
    }
    var requestCount: Int { state.withLock { $0.count } }

    func advance(by duration: Duration) { state.withLock { $0.now = $0.now.advanced(by: duration) } }

    func nextRequest() async -> Request? {
        var iterator = requests.makeAsyncIterator()
        return await iterator.next()
    }

    func nextCompletion() async -> Completion? {
        var iterator = completions.makeAsyncIterator()
        return await iterator.next()
    }

    func release(_ id: Int) {
        state.withLock { $0.pending.removeValue(forKey: id) }?.resume()
    }

    func releaseAll() {
        let pending = state.withLock { state in
            state.releasesAll = true
            let pending = Array(state.pending.values)
            state.pending.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume() }
    }

    private func sleep(_ duration: Duration) async {
        let request = state.withLock { state in
            state.count += 1
            return Request(id: state.count, duration: duration)
        }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let released = state.withLock { state in
                if !state.releasesAll { state.pending[request.id] = waiter }
                return state.releasesAll
            }
            if released { waiter.resume() }
            requestContinuation.yield(request)
        }
        completionContinuation.yield(Completion(id: request.id, wasCancelled: Task.isCancelled))
    }
}
#endif
