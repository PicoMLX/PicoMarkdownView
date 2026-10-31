#if os(macOS)
import AppKit
import SwiftUI
import Testing
import WebKit
@testable import PicoMarkdownView
@testable import PicoMarkdownViewHTML

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HTMLPreviewPreparationTests {
    @Test("Preparation starts lazily and simultaneous consumers share one result")
    func lazySharedPreparation() async throws {
        let gate = PreparationGate()
        let owner = HTMLPreviewPreparation(source: "<p>Shared</p>", prepare: { try await gate.prepare($0) })
        #expect(await gate.callCount == 0)
        let first = owner.resultTask()
        let second = owner.resultTask()
        defer { first.cancel(); second.cancel() }
        try await gate.waitForCalls(1)
        #expect(await gate.callCount == 1)
        let expected = try HTMLPreviewPolicy.prepare(source: "<p>Shared</p>")
        await gate.succeed(source: owner.source, with: expected)
        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(firstResult == expected)
        #expect(secondResult == expected)
        #expect(try await owner.resultTask().value == expected)
        var dark = HTMLPreviewStyle.default
        dark.isDark = true
        dark.fontSize = 24
        #expect(firstResult.document().html != secondResult.document(style: dark).html)
        #expect(await gate.callCount == 1, "Style composition and later consumers must not parse again")
    }

    @Test("A failed preparation is cached rather than retried")
    func failedResultIsCached() async throws {
        let gate = PreparationGate()
        let owner = HTMLPreviewPreparation(source: "Rejected", prepare: { try await gate.prepare($0) })
        let first = owner.resultTask()
        defer { first.cancel() }
        try await gate.waitForCalls(1)
        await gate.fail(source: owner.source, with: HTMLPreviewPolicyError.invalidHTML)
        await #expect(throws: HTMLPreviewPolicyError.invalidHTML) { try await first.value }
        await #expect(throws: HTMLPreviewPolicyError.invalidHTML) { try await owner.resultTask().value }
        #expect(await gate.callCount == 1)
    }

    @Test("Discarding the source owner cancels its worker without retaining the owner")
    func discardedOwnerCancelsWork() async throws {
        let gate = PreparationGate()
        var owner: HTMLPreviewPreparation? = HTMLPreviewPreparation(source: "Pending", prepare: { try await gate.prepare($0) })
        weak var weakOwner = owner
        let worker = try #require(owner?.resultTask())
        defer { worker.cancel() }
        try await gate.waitForCalls(1)
        owner = nil
        try #require(weakOwner == nil, "The worker must not retain the preparation owner across its await")
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(await gate.pendingCount == 0)
    }

    @Test("Source B remains installed when a superseded preparation A finishes later")
    func supersededSourceCannotInstallStalePage() async throws {
        let gate = PreparationGate()
        let sourceA = "<p>Source A</p>"
        let sourceB = "<p>Source B</p>"
        let preparationA = HTMLPreviewPreparation(source: sourceA, prepare: { try await gate.prepare($0) })
        let (view, window) = makeView(preparation: preparationA, gate: gate)
        defer { tearDown(view, window) }
        view.configure(source: sourceA, style: .default)
        window.contentView = view
        window.orderFront(nil)
        try await gate.waitForCalls(1)
        let stalePresentation = try #require(view.pendingPresentation)
        view.configure(source: sourceB, style: .default)
        try await gate.waitForCalls(2)
        let ready = AsyncStream.makeStream(of: Void.self)
        view.onReady = { ready.continuation.yield(()) }
        try await gate.succeed(source: sourceB, with: HTMLPreviewPolicy.prepare(source: sourceB))
        var readyIterator = ready.stream.makeAsyncIterator()
        try #require(await readyIterator.next() != nil)
        let pageB = try #require(view.page)
        #expect(view.loadCount == 1)

        // Retain A's owner until completion: cancelling a presentation must
        // neither cancel the reusable preparation nor install its late result.
        try await gate.succeed(source: sourceA, with: HTMLPreviewPolicy.prepare(source: sourceA))
        _ = try await preparationA.resultTask().value
        await stalePresentation.value
        #expect(view.page === pageB)
        #expect(view.loadCount == 1)
        #expect(view.isReady && !view.hasFailed)
        let body = try await pageB.callJavaScript("return document.body.textContent", contentWorld: .defaultClient) as? String
        #expect(body?.contains("Source B") == true)
        #expect(body?.contains("Source A") == false)
    }

    @Test("Replacing a ready source publishes loading before its next preparation completes")
    func sourceReplacementResetsReadiness() async throws {
        let gate = PreparationGate()
        let sourceA = "<p>Ready source A</p>"
        let sourceB = "<p>Pending source B</p>"
        let preparationA = HTMLPreviewPreparation(source: sourceA, prepare: { try await gate.prepare($0) })
        let (view, window) = makeView(preparation: preparationA, gate: gate)
        defer { tearDown(view, window) }
        let readyA = AsyncStream.makeStream(of: Void.self)
        view.onReady = { readyA.continuation.yield(()) }
        view.configure(source: sourceA, style: .default)
        window.contentView = view
        window.orderFront(nil)
        try await gate.waitForCalls(1)
        try await gate.succeed(source: sourceA, with: HTMLPreviewPolicy.prepare(source: sourceA))
        var readyAIterator = readyA.stream.makeAsyncIterator()
        try #require(await readyAIterator.next() != nil)
        try #require(view.isReady)
        let measuredHeight = view.measuredHeight

        let readiness = AsyncStream.makeStream(of: Bool.self)
        view.onReadinessChanged = { readiness.continuation.yield($0) }
        view.configure(source: sourceB, style: .default)
        var readinessIterator = readiness.stream.makeAsyncIterator()
        #expect(await readinessIterator.next() == false)
        try await gate.waitForCalls(2)
        #expect(!view.isReady, "The source placeholder must return while the replacement is pending")
        #expect(view.page == nil)
        #expect(view.measuredHeight == measuredHeight, "Loading preserves the attachment's last measured height")
        #expect(await gate.pendingCount == 1)

        try await gate.succeed(source: sourceB, with: HTMLPreviewPolicy.prepare(source: sourceB))
        #expect(await readinessIterator.next() == true)
        #expect(view.isReady && !view.hasFailed)
        #expect(view.loadCount == 2)
    }

    @Test("A deferred failure from discarded source A cannot reject replacement source B")
    func discardedFailureCannotRejectReplacement() async throws {
        let gate = PreparationGate()
        let sourceA = "<p>Discarded source A</p>"
        let sourceB = "<p>Replacement source B</p>"
        let preparationA = HTMLPreviewPreparation(source: sourceA, prepare: { try await gate.prepare($0) })
        let (view, window) = makeView(preparation: preparationA, gate: gate)
        defer { tearDown(view, window) }
        view.configure(source: sourceA, style: .default)
        window.contentView = view
        window.orderFront(nil)
        try await gate.waitForCalls(1)
        var failureCount = 0
        view.onFailure = { failureCount += 1 }
        view.fail()
        let staleNotification = try #require(view.pendingFailureNotification)
        // Replace A in the same actor turn, before its deferred failure can run.
        view.configure(source: sourceB, style: .default)
        await staleNotification.value
        #expect(failureCount == 0)
        #expect(!view.hasFailed)
        try await gate.waitForCalls(2)

        let ready = AsyncStream.makeStream(of: Void.self)
        view.onReady = { ready.continuation.yield(()) }
        try await gate.succeed(source: sourceB, with: HTMLPreviewPolicy.prepare(source: sourceB))
        var readyIterator = ready.stream.makeAsyncIterator()
        try #require(await readyIterator.next() != nil)
        #expect(view.isReady && !view.hasFailed)
        #expect(view.loadCount == 1)
        #expect(failureCount == 0)
        try await gate.succeed(source: sourceA, with: HTMLPreviewPolicy.prepare(source: sourceA))
        _ = try await preparationA.resultTask().value
    }

    @Test("Detachment discards pending presentation while keeping reusable prepared content")
    func detachedPreparationFinishesWithoutInstalling() async throws {
        let gate = PreparationGate()
        let source = "<p>Detached source</p>"
        let preparation = HTMLPreviewPreparation(source: source, prepare: { try await gate.prepare($0) })
        let (view, window) = makeView(preparation: preparation, gate: gate)
        defer { tearDown(view, window) }
        view.configure(source: source, style: .default)
        window.contentView = view
        window.orderFront(nil)
        try await gate.waitForCalls(1)
        let stalePresentation = try #require(view.pendingPresentation)
        window.contentView = nil
        try await gate.succeed(source: source, with: HTMLPreviewPolicy.prepare(source: source))
        _ = try await preparation.resultTask().value
        await stalePresentation.value
        #expect(view.page == nil)
        #expect(view.loadCount == 0)

        let ready = AsyncStream.makeStream(of: Void.self)
        view.onReady = { ready.continuation.yield(()) }
        window.contentView = view
        var readyIterator = ready.stream.makeAsyncIterator()
        try #require(await readyIterator.next() != nil)
        #expect(view.page != nil)
        #expect(view.loadCount == 1)
        #expect(await gate.callCount == 1, "Reattaching consumes the already prepared result")
    }

    @Test("Native streaming and source copying continue while HTML preparation is pending")
    func streamingContinuesDuringPreparation() async throws {
        _ = NSApplication.shared
        let gate = PreparationGate()
        let state = SourceState()
        let renderer = PicoEmbeddedBlockRenderer(selectors: [.htmlBlock]) { context in
            let preparation = HTMLPreviewPreparation(source: context.source, prepare: { try await gate.prepare($0) })
            state.preparation = preparation
            return AnyView(Text(context.source))
        }
        let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [renderer])
        let controller = TextKitStreamingController()
        let text = controller.makeTextKit2View(configuration: .default()) as! StreamingTextKit2View
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = text
        defer { window.contentView = nil; window.close() }
        let initial = try #require(await pipeline.feed("Before.\n\n<div>Original source</div>\n\nTail"))
        controller.update(textView: text, blocks: initial.blocks, diffs: [initial.diff], replaceToken: 1, configuration: .default())
        let preparation = try #require(state.preparation)
        let worker = preparation.resultTask()
        defer { worker.cancel() }
        try await gate.waitForCalls(1)
        let next = try #require(await pipeline.feed(" continues while preparation waits.\n\n"))
        controller.update(textView: text, blocks: next.blocks, diffs: [next.diff], replaceToken: 1, configuration: .default())
        #expect(text.string.contains("Tail continues while preparation waits."))
        text.setSelectedRange(NSRange(location: 0, length: text.textStorage?.length ?? 0))
        let copied = text.markdownForSelection()
        #expect(copied.contains("<div>Original source</div>"))
        #expect(copied.contains("Before."))
        #expect(copied.contains("Tail continues"))
        #expect(!copied.contains("\u{FFFC}"))
        #expect(await gate.pendingCount == 1)
        #expect(await gate.callCount == 1)
        try await gate.succeed(source: preparation.source, with: HTMLPreviewPolicy.prepare(source: preparation.source))
        _ = try await worker.value
    }

    private func makeView(preparation: HTMLPreviewPreparation, gate: PreparationGate) -> (HTMLPreviewContainer, NSWindow) {
        _ = NSApplication.shared
        let view = HTMLPreviewContainer(preparation: preparation, prepare: { try await gate.prepare($0) })
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 400, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return (view, window)
    }

    private func tearDown(_ view: HTMLPreviewContainer, _ window: NSWindow) {
        view.suspend()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    @MainActor private final class SourceState {
        var preparation: HTMLPreviewPreparation?
    }
}

private actor PreparationGate {
    private(set) var callCount = 0
    private var pending: [String: AsyncThrowingStream<HTMLPreparedContent, any Error>.Continuation] = [:]
    private var callWaiters: [UUID: (count: Int, continuation: AsyncStream<Void>.Continuation)] = [:]
    var pendingCount: Int { pending.count }

    func prepare(_ source: String) async throws -> HTMLPreparedContent {
        callCount += 1
        let gate = AsyncThrowingStream.makeStream(of: HTMLPreparedContent.self)
        pending[source] = gate.continuation
        let satisfied = callWaiters.filter { $0.value.count <= callCount }
        for (id, waiter) in satisfied {
            callWaiters[id] = nil
            waiter.continuation.yield(())
            waiter.continuation.finish()
        }
        defer { pending[source] = nil }
        var iterator = gate.stream.makeAsyncIterator()
        guard let result = try await iterator.next() else { throw CancellationError() }
        return result
    }

    func waitForCalls(_ count: Int) async throws {
        guard callCount < count else { return }
        let id = UUID()
        let gate = AsyncStream.makeStream(of: Void.self)
        callWaiters[id] = (count, gate.continuation)
        defer { callWaiters[id] = nil }
        for await _ in gate.stream { break }
        try Task.checkCancellation()
    }

    func succeed(source: String, with content: HTMLPreparedContent) {
        pending[source]?.yield(content)
        pending[source]?.finish()
    }

    func fail(source: String, with error: any Error) {
        pending[source]?.finish(throwing: error)
    }
}
#endif
