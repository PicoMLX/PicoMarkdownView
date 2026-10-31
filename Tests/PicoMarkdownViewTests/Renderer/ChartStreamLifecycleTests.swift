#if os(macOS)
import Foundation
import Observation
import Testing
@testable import PicoMarkdownView

@Suite("Hosted chart stream lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct ChartStreamLifecycleTests {
    @Test("Cancelling an open chart stops presentation activity without finishing its fence")
    func cancelledOpenFenceStaysOpen() async throws {
        let model = MarkdownStreamingViewModel()
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let task = Task { await model.consume(.stream { stream }) }
        defer { task.cancel(); continuation.finish() }
        continuation.yield("Before.\n\n```vega-lite\n" + source + "\n")
        await waitUntil { model.blocks.contains { $0.snapshot.codeText == source + "\n" } }
        #expect(model.isHostedStreamActive)
        let before = model.blocks
        let open = try #require(model.blocks.first { $0.snapshot.codeText != nil })
        #expect(!open.snapshot.isClosed)

        task.cancel()
        await task.value
        #expect(!model.isHostedStreamActive)
        #expect(model.blocks == before)
        #expect(model.blocks.first { $0.id == open.id }?.snapshot.isClosed == false)
        #expect(model.blocks.first { $0.id == open.id }?.snapshot.codeText == open.snapshot.codeText)
    }

    @Test("Normal completion closes the canonical chart fence and stops loading activity")
    func completedStreamClosesFence() async throws {
        let model = MarkdownStreamingViewModel()
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let task = Task { await model.consume(.stream { stream }) }
        defer { task.cancel(); continuation.finish() }
        continuation.yield("```vega-lite\n" + source + "\n")
        await waitUntil { model.blocks.first?.snapshot.codeText == source + "\n" }
        #expect(model.isHostedStreamActive)
        #expect(model.blocks.first?.snapshot.isClosed == false)

        continuation.finish()
        await task.value
        await waitUntil { model.blocks.first?.snapshot.isClosed == true }
        #expect(!model.isHostedStreamActive)
        let closed = try #require(model.blocks.first)
        #expect(closed.snapshot.isClosed)
        #expect(closed.snapshot.codeText == source + "\n")
        #expect(closed.vegaLiteChart?.source == source + "\n")
    }

    @Test("A suspended factory can stop loading before its cancelled consume call returns")
    func cancelledSuspendedFactoryCannotStopNewInput() async {
        let model = MarkdownStreamingViewModel()
        let factory = SuspendedChartStreamFactory()
        let old = Task { await model.consume(.stream { await factory.makeStream() }) }
        defer { old.cancel(); Task { await factory.release() } }
        await factory.waitUntilEntered()
        #expect(model.isHostedStreamActive)
        old.cancel()
        await waitUntil { !model.isHostedStreamActive }

        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let current = Task { await model.consume(.stream { stream }) }
        defer { current.cancel(); continuation.finish() }
        continuation.yield("New document.\n\n```vega-lite\n" + source + "\n")
        await waitUntil { model.blocks.contains { $0.snapshot.codeText == source + "\n" } }
        #expect(model.isHostedStreamActive)
        let currentBlocks = model.blocks

        await factory.release()
        await old.value
        #expect(model.isHostedStreamActive)
        #expect(model.blocks == currentBlocks)
        #expect(model.blocks.last?.snapshot.isClosed == false)

        current.cancel()
        await current.value
        #expect(!model.isHostedStreamActive)
    }

    @Test("Cancelling an older factory after replacement cannot stop the current stream")
    func lateOldCancellationCannotStopCurrentStream() async {
        let model = MarkdownStreamingViewModel()
        let factory = SuspendedChartStreamFactory()
        let old = Task { await model.consume(.stream { await factory.makeStream() }) }
        defer { old.cancel(); Task { await factory.release() } }
        await factory.waitUntilEntered()

        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let current = Task { await model.consume(.stream { stream }) }
        defer { current.cancel(); continuation.finish() }
        continuation.yield("Current document.\n\n```vega-lite\n" + source + "\n")
        await waitUntil { model.blocks.contains { $0.snapshot.codeText == source + "\n" } }
        let currentBlocks = model.blocks
        old.cancel()
        await factory.release()
        await old.value
        #expect(model.isHostedStreamActive)
        #expect(model.blocks == currentBlocks)
        current.cancel()
        await current.value
        #expect(!model.isHostedStreamActive)
    }

    @Test("A superseded uncancelled factory cannot overwrite a complete replacement")
    func replacementSupersedesSuspendedFactory() async {
        let model = MarkdownStreamingViewModel()
        let factory = SuspendedChartStreamFactory()
        let old = Task { await model.consume(.stream { await factory.makeStream() }) }
        defer { old.cancel(); Task { await factory.release() } }
        await factory.waitUntilEntered()
        await model.consume(.text("Replacement text.\n\n"))
        await waitUntil { model.blocks.first.map { String($0.content.characters) == "Replacement text.\n" } == true }
        let replacement = model.blocks
        #expect(!model.isHostedStreamActive)
        await factory.release()
        await old.value
        #expect(!model.isHostedStreamActive)
        #expect(model.blocks == replacement)
    }

    @Test("Complete text and chunk inputs leave no active loading presentation")
    func completeInputsStopActivity() async {
        let model = MarkdownStreamingViewModel()
        #expect(!model.isHostedStreamActive)
        await model.consume(.text("```vega-lite\n" + source + "\n```\n"))
        #expect(!model.isHostedStreamActive)
        await model.consume(.chunks(["Before.\n\n```vega-lite\n", source, "\n```\n"]))
        #expect(!model.isHostedStreamActive)
    }

    @Test("An already cancelled stream does not invoke its factory or finish a fence")
    func alreadyCancelledStreamDoesNotStartFactory() async {
        let model = MarkdownStreamingViewModel()
        let counter = ChartFactoryCounter()
        let task = Task {
            await model.consume(.stream {
                await counter.recordCall()
                return AsyncStream { $0.finish() }
            })
        }
        task.cancel()
        await task.value
        #expect(await counter.calls == 0)
        #expect(!model.isHostedStreamActive)
        #expect(model.blocks.isEmpty)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        while !predicate() {
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = predicate()
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }

    private let source = "{\"data\":{\"values\":[{\"category\":\"A\",\"value\":2}]},\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"category\",\"type\":\"nominal\"},\"y\":{\"field\":\"value\",\"type\":\"quantitative\"}}}"
}

private actor ChartFactoryCounter {
    private(set) var calls = 0
    func recordCall() { calls += 1 }
}

private actor SuspendedChartStreamFactory {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var result: CheckedContinuation<AsyncStream<String>, Never>?

    func makeStream() async -> AsyncStream<String> {
        entered = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        return await withCheckedContinuation { result = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        result?.resume(returning: AsyncStream { $0.finish() })
        result = nil
    }
}
#endif
