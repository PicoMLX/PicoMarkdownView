#if os(macOS)
import Foundation
import Observation
import Testing
@testable import PicoMarkdownView

@Suite("SVG loading stream lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct SVGStreamLifecycleTests {
    @Test("Canceling an SVG stream stops presentation activity without completing its fence")
    func canceledOpenFenceStaysOpen() async throws {
        let model = MarkdownStreamingViewModel(theme: .default().withSVGRendering())
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let task = Task { await model.consume(.stream { stream }) }
        defer { task.cancel(); continuation.finish() }
        continuation.yield("Before.\n\n```svg\n" + source + "\n")
        await waitUntil { model.blocks.contains { $0.snapshot.codeText?.contains("<rect") == true } }
        #expect(model.isSVGStreamActive)
        let beforeCancellation = model.blocks
        let open = try #require(model.blocks.first { $0.snapshot.codeText != nil })
        #expect(!open.snapshot.isClosed)

        task.cancel()
        await task.value
        #expect(!model.isSVGStreamActive)
        #expect(model.blocks == beforeCancellation)
        #expect(model.blocks.first { $0.id == open.id }?.snapshot.isClosed == false)
        #expect(model.blocks.first { $0.id == open.id }?.snapshot.codeText == open.snapshot.codeText)
    }

    @Test("Normal stream completion closes the canonical fence and stops loading activity")
    func completedStreamClosesFence() async throws {
        let model = MarkdownStreamingViewModel(theme: .default().withSVGRendering())
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let task = Task { await model.consume(.stream { stream }) }
        defer { task.cancel(); continuation.finish() }
        continuation.yield("```svg\n" + source + "\n")
        await waitUntil { model.blocks.first?.snapshot.codeText?.contains("<rect") == true }
        #expect(model.isSVGStreamActive)
        #expect(model.blocks.first?.snapshot.isClosed == false)

        continuation.finish()
        await task.value
        await waitUntil { model.blocks.first?.snapshot.isClosed == true }
        #expect(!model.isSVGStreamActive)
        let closed = try #require(model.blocks.first)
        #expect(closed.snapshot.isClosed)
        #expect(closed.snapshot.codeText == source + "\n")
    }

    @Test("Canceling a suspended factory stops activity and cannot stop a newer SVG stream")
    func oldFactoryCannotStopNewInput() async throws {
        let model = MarkdownStreamingViewModel(theme: .default().withSVGRendering())
        let factory = SuspendedSVGStreamFactory()
        let old = Task { await model.consume(.stream { await factory.makeStream() }) }
        await factory.waitUntilEntered()
        #expect(model.isSVGStreamActive)
        old.cancel()
        // The canceled factory deliberately remains suspended. The loading
        // activity still has to stop before the old consume call returns.
        await waitUntil { !model.isSVGStreamActive }

        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let current = Task { await model.consume(.stream { stream }) }
        defer { old.cancel(); current.cancel(); continuation.finish() }
        continuation.yield("New document.\n\n```svg\n" + source + "\n")
        await waitUntil { model.blocks.contains { $0.snapshot.codeText?.contains("<rect") == true } }
        #expect(model.isSVGStreamActive)
        let currentBlocks = model.blocks

        await factory.release()
        await old.value
        #expect(model.isSVGStreamActive)
        #expect(model.blocks == currentBlocks)
        #expect(model.blocks.contains { String($0.content.characters).contains("New document.") })
        #expect(model.blocks.last?.snapshot.isClosed == false)

        current.cancel()
        await current.value
        #expect(!model.isSVGStreamActive)
    }

    @Test("Complete text and chunk inputs leave no loading activity")
    func completeInputsStopActivity() async {
        let model = MarkdownStreamingViewModel(theme: .default().withSVGRendering())
        #expect(!model.isSVGStreamActive)
        await model.consume(.text("```svg\n" + source + "\n```\n"))
        #expect(!model.isSVGStreamActive)
        await model.consume(.chunks(["Before.\n\n```svg\n", source, "\n```\n"]))
        #expect(!model.isSVGStreamActive)
    }

    /// Await actual observed mutations rather than imposing a wall-clock
    /// polling deadline on main-actor parsing and coalesced publication.
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

    private let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 80 40\"><rect width=\"80\" height=\"40\" fill=\"red\"/></svg>"
}

private actor SuspendedSVGStreamFactory {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var result: CheckedContinuation<AsyncStream<String>, Never>?

    func makeStream() async -> AsyncStream<String> {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { result = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        result?.resume(returning: AsyncStream { $0.finish() })
        result = nil
    }
}
#endif
