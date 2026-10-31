#if os(macOS) && canImport(JavaScriptCore)
import AppKit
import Synchronization
import Testing
@testable import PicoMarkdownView

@Suite("Paused macOS Mermaid previews")
@MainActor
struct MermaidPreviewViewModelTests {
    private let initialSource = "flowchart LR\n A[Start]\n"
    private let nextLine = " A --> B[Finish]\n"

    @Test("A paused open stream displays its newest complete line without another chunk")
    func trailingPreviewWhilePaused() async throws {
        let model = try await makeWarmedModel()
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let consumer = Task { await model.consume(.stream { stream }) }
        defer { consumer.cancel(); continuation.finish() }

        continuation.yield("```mermaid\n" + initialSource)
        try await waitUntil { model.blocks.first?.mermaidDiagram?.svg != nil }
        let initial = try #require(model.blocks.first?.mermaidDiagram?.svg)
        continuation.yield(nextLine)
        try await waitUntil { model.blocks.first?.mermaidDiagram?.source.contains("Finish") == true }

        // No further yield or finish: only the scheduled trailing refresh can
        // update a prefix that arrived inside the renderer's preview interval.
        try await waitUntil {
            guard let svg = model.blocks.first?.mermaidDiagram?.svg else { return false }
            return svg != initial && svg.contains("Finish")
        }
        #expect(model.blocks.first?.snapshot.isClosed == false)
        #expect(model.blocks.first?.mermaidDiagram?.source == initialSource + nextLine)
        continuation.finish()
        await consumer.value
    }

    @Test("Replacing the document cancels a pending open-diagram preview")
    func replacementSuppressesOldPreview() async throws {
        let model = try await makeWarmedModel()
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let consumer = Task { await model.consume(.stream { stream }) }
        defer { consumer.cancel(); continuation.finish() }

        continuation.yield("```mermaid\n" + initialSource)
        try await waitUntil { model.blocks.first?.mermaidDiagram?.svg != nil }
        continuation.yield(nextLine)
        try await waitUntil { model.blocks.first?.mermaidDiagram?.source.contains("Finish") == true }
        await model.consume(.text("Replacement document"))
        try await waitUntil { model.blocks.first.map { String($0.content.characters).contains("Replacement document") } == true }
        let replacementIdentity = model.documentIdentity

        // Observe across the old 200ms deadline, including main-queue flushes.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(350))
        while clock.now < deadline {
            #expect(model.documentIdentity == replacementIdentity)
            #expect(model.blocks.allSatisfy { $0.mermaidDiagram == nil })
            #expect(model.blocks.first.map { String($0.content.characters).contains("Replacement document") } == true)
            try await Task.sleep(for: .milliseconds(10))
        }
        continuation.finish()
        await consumer.value
    }

    @Test("A slow closing render cannot be superseded by its trailing preview deadline", .timeLimit(.minutes(1)), arguments: [false, true])
    func slowCloseOutlivesPreviewDeadline(useChunks: Bool) async throws {
        _ = NSApplication.shared
        let provider = DelayedPreviewVectorProvider()
        let model = MarkdownStreamingViewModel(
            theme: .default().withMermaidRendering(.bestEffortDebounced(milliseconds: 100)),
            mermaidProvider: provider)
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let consumer = Task {
            if useChunks {
                await model.consume(.chunks(["```mermaid\n" + initialSource, nextLine, "```\n"]))
            } else {
                await model.consume(.stream { stream })
            }
        }
        defer { consumer.cancel(); continuation.finish() }

        if !useChunks {
            continuation.yield("```mermaid\n" + initialSource)
            try await waitUntil { model.blocks.first?.mermaidDiagram?.svg != nil }
            continuation.yield(nextLine)
            try await waitUntil { model.blocks.first?.mermaidDiagram?.source.contains("Finish") == true }
            continuation.yield("```\n")
        }
        _ = try await waitForRequest(provider, isPreview: false)

        // Cross the configured timer deadline while the provider deliberately
        // holds the final result. The deadline must not start a second final.
        try await Task.sleep(for: .milliseconds(250))
        #expect(await provider.finalRequestCount() == 1)
        await provider.releaseAll()
        try await waitUntil { model.blocks.first?.snapshot.isClosed == true }
        let diagram = try #require(model.blocks.first?.mermaidDiagram)
        #expect(diagram.svg?.contains("final:\((initialSource + nextLine).utf8.count)") == true)
        #expect(diagram.source == initialSource + nextLine)
        #expect(await provider.finalRequestCount() == 1)
        continuation.finish()
        await consumer.value
    }

    @Test("An in-flight preview unwinds before the closing render starts", .timeLimit(.minutes(1)), arguments: [false, true])
    func inFlightPreviewFinishesBeforeClose(delaySecondFeed: Bool) async throws {
        _ = NSApplication.shared
        let provider = DelayedPreviewVectorProvider(delayPreviewsAfterFirst: true)
        let clock = PreviewTestClock()
        let model = MarkdownStreamingViewModel(
            theme: .default().withMermaidRendering(.bestEffortDebounced(milliseconds: 100)),
            mermaidProvider: provider, mermaidPreviewTiming: clock.timing)
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let consumer = Task { await model.consume(.stream { stream }) }
        defer { consumer.cancel(); continuation.finish() }

        continuation.yield("```mermaid\n" + initialSource)
        try await waitUntil { model.blocks.first?.mermaidDiagram?.svg != nil }
        let initialDeadline = try await clock.nextDeadline()
        // CI can delay the main actor beyond the real 100ms interval. Keep
        // both the renderer and timer on controlled time even across that lag.
        if delaySecondFeed { try await Task.sleep(for: .milliseconds(250)) }
        continuation.yield(nextLine)
        try await waitUntil { model.blocks.first?.mermaidDiagram?.source.contains("Finish") == true }
        let trailingDeadline = try await clock.nextDeadline(after: initialDeadline)
        #expect(await provider.previewRequestCount() == 1,
                "The next source must publish before its trailing provider call starts")
        clock.advance(by: .milliseconds(100))
        let preview = try await waitForRequest(provider, isPreview: true, after: 0)
        #expect(clock.hasFired(trailingDeadline))
        continuation.yield("```\n")
        let final = try await waitForRequest(provider, isPreview: false)
        let events = await provider.recordedEvents()
        let previewFinished = events.firstIndex(of: "finished:\(preview)")
        let finalStarted = events.firstIndex(of: "started:\(final)")
        #expect(previewFinished != nil, "Cancellation must drain the already-running preview")
        if let previewFinished, let finalStarted {
            #expect(previewFinished < finalStarted)
        }
        await provider.releaseAll()
        try await waitUntil { model.blocks.first?.snapshot.isClosed == true }
        #expect(model.blocks.first?.mermaidDiagram?.svg?.contains("final:") == true)
        #expect(model.blocks.first?.mermaidDiagram?.source == initialSource + nextLine)
        #expect(await provider.finalRequestCount() == 1)
        continuation.finish()
        await consumer.value
    }

    @Test("A buffered partial fence retries a cancelled trailing preview", .timeLimit(.minutes(1)), arguments: [false, true])
    func bufferedFenceRetainsCancelledPreview(delaySecondFeed: Bool) async throws {
        _ = NSApplication.shared
        let provider = DelayedPreviewVectorProvider(delayPreviewsAfterFirst: true)
        let clock = PreviewTestClock()
        let model = MarkdownStreamingViewModel(
            theme: .default().withMermaidRendering(.bestEffortDebounced(milliseconds: 100)),
            mermaidProvider: provider, mermaidPreviewTiming: clock.timing)
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let consumer = Task { await model.consume(.stream { stream }) }
        defer { consumer.cancel(); continuation.finish() }

        continuation.yield("```mermaid\n" + initialSource)
        try await waitUntil { model.blocks.first?.mermaidDiagram?.svg != nil }
        let initialDeadline = try await clock.nextDeadline()
        if delaySecondFeed { try await Task.sleep(for: .milliseconds(250)) }
        continuation.yield(nextLine)
        try await waitUntil { model.blocks.first?.mermaidDiagram?.source.contains("Finish") == true }
        let trailingDeadline = try await clock.nextDeadline(after: initialDeadline)
        #expect(await provider.previewRequestCount() == 1,
                "The next source must publish before its trailing provider call starts")
        clock.advance(by: .milliseconds(100))
        _ = try await waitForRequest(provider, isPreview: true, after: 0)
        #expect(clock.hasFired(trailingDeadline))

        // Only fence markers, with no newline: the tokenizer buffers this
        // chunk and emits no diff. It still cancels the in-flight refresh.
        continuation.yield("``")
        let retryDeadline = try await clock.nextDeadline(after: trailingDeadline)
        #expect(await provider.previewRequestCount() == 2)
        clock.advance(by: .milliseconds(100))
        _ = try await waitForRequest(provider, isPreview: true, after: 1)
        #expect(clock.hasFired(retryDeadline))
        #expect(await provider.previewRequestCount() == 3,
                "The paused stream must retry its cancelled complete-line preview without another chunk")
        await provider.releaseAll()
        try await waitUntil {
            model.blocks.first?.mermaidDiagram?.svg?.contains("preview:\((initialSource + nextLine).utf8.count)") == true
        }
        #expect(model.blocks.first?.snapshot.isClosed == false)
        #expect(model.blocks.first?.mermaidDiagram?.source == initialSource + nextLine)
        continuation.yield("`\n")
        _ = try await waitForRequest(provider, isPreview: false)
        await provider.releaseAll()
        continuation.finish()
        await consumer.value
    }

    private func waitForRequest(_ provider: DelayedPreviewVectorProvider,
                                isPreview: Bool, after index: Int = -1) async throws -> Int {
        var iterator = provider.started.makeAsyncIterator()
        while true {
            let request = try #require(await iterator.next(), "The expected vector render did not start")
            if request.isPreview == isPreview, request.index > index { return request.index }
        }
    }

    private func makeWarmedModel() async throws -> MarkdownStreamingViewModel {
        _ = NSApplication.shared
        let theme = MarkdownRenderTheme.default().withMermaidRendering(.bestEffortDebounced(milliseconds: 200))
        // Warm Pele's shared JavaScript/font resources before measuring a short
        // pause; each view model still owns its own provider and source cache.
        let provider = PeleDiagramProvider(theme: theme)
        _ = try #require(await provider.renderVector(MermaidRenderRequest(source: initialSource,
                                                                         targetWidth: nil, scale: 1)))
        return MarkdownStreamingViewModel(theme: theme)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(predicate(), "The expected stream presentation did not arrive before the deadline")
    }
}

/// A cancellation-aware clock shared by the view-model timer and renderer's
/// debounce check. Scheduling and advancing are explicit, independent of load.
private final class PreviewTestClock: Sendable {
    private struct Sleep {
        let deadline: ContinuousClock.Instant
        let continuation: AsyncStream<Void>.Continuation
    }
    private struct State {
        var now = ContinuousClock.now
        var nextID = 0
        var sleeps: [Int: Sleep] = [:]
        var fired: Set<Int> = []
    }
    private let state = Mutex(State())

    var timing: MermaidPreviewTiming {
        MermaidPreviewTiming(now: { self.state.withLock { $0.now } },
                             sleep: { try await self.sleep(for: $0) })
    }

    private func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let gate = AsyncStream.makeStream(of: Void.self)
        let id = state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.sleeps[id] = Sleep(deadline: state.now.advanced(by: duration), continuation: gate.continuation)
            return id
        }
        defer { state.withLock { $0.sleeps[id] = nil } }
        // AsyncStream wakes on cancellation just like the production sleep.
        for await _ in gate.stream { break }
        try Task.checkCancellation()
    }

    func advance(by duration: Duration) {
        let ready = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let ids = state.sleeps.filter { $0.value.deadline <= state.now }.map(\.key)
            state.fired.formUnion(ids)
            return ids.compactMap { state.sleeps.removeValue(forKey: $0)?.continuation }
        }
        for continuation in ready { continuation.yield(()); continuation.finish() }
    }

    func hasFired(_ id: Int) -> Bool { state.withLock { $0.fired.contains(id) } }

    func nextDeadline(after previous: Int = -1) async throws -> Int {
        let wallClock = ContinuousClock()
        let timeout = wallClock.now.advanced(by: .seconds(5))
        var scheduled: Int?
        repeat {
            scheduled = state.withLock { $0.sleeps.keys.filter { $0 > previous }.min() }
            if scheduled == nil { try await Task.sleep(for: .milliseconds(5)) }
        } while scheduled == nil && wallClock.now < timeout
        let latest = scheduled ?? state.withLock { $0.sleeps.keys.filter { $0 > previous }.min() }
        return try #require(latest, "The expected trailing preview deadline was not scheduled")
    }
}

private actor DelayedPreviewVectorProvider: MermaidVectorDiagramProvider {
    struct StartedRequest: Sendable { let index: Int; let isPreview: Bool }
    private struct Pending {
        let request: StartedRequest
        let continuation: AsyncStream<Void>.Continuation
    }
    nonisolated let started: AsyncStream<StartedRequest>
    private let startedContinuation: AsyncStream<StartedRequest>.Continuation
    private let delayPreviewsAfterFirst: Bool
    private var requests: [MermaidRenderRequest] = []
    private var pending: [Int: Pending] = [:]
    private var events: [String] = []

    init(delayPreviewsAfterFirst: Bool = false) {
        let signal = AsyncStream.makeStream(of: StartedRequest.self)
        started = signal.stream
        startedContinuation = signal.continuation
        self.delayPreviewsAfterFirst = delayPreviewsAfterFirst
    }

    func renderVector(_ request: MermaidRenderRequest) async -> MermaidVectorRenderResult? {
        let index = requests.count
        requests.append(request)
        let signal = StartedRequest(index: index, isPreview: request.isPreview)
        events.append("started:\(index)")
        startedContinuation.yield(signal)
        if !request.isPreview || (delayPreviewsAfterFirst && requests.filter(\.isPreview).count > 1) {
            let gate = AsyncStream.makeStream(of: Void.self)
            pending[index] = Pending(request: signal, continuation: gate.continuation)
            // AsyncStream's iterator wakes on cancellation, allowing the
            // production cancellation barrier to drain this suspended render.
            for await _ in gate.stream { break }
            pending[index] = nil
        }
        events.append("finished:\(index)")
        let label = request.isPreview ? "preview" : "final"
        return MermaidVectorRenderResult(
            svg: "<svg width=\"200\" height=\"100\"><text>\(label):\(request.source.utf8.count)</text></svg>",
            intrinsicSize: CGSize(width: 200, height: 100))
    }

    func render(_ request: MermaidRenderRequest) async -> MermaidRenderResult? { nil }
    func finalRequestCount() -> Int { requests.filter { !$0.isPreview }.count }
    func previewRequestCount() -> Int { requests.filter(\.isPreview).count }
    func recordedEvents() -> [String] { events }

    func releaseAll() {
        let gates = pending.values.map(\.continuation)
        pending.removeAll()
        for gate in gates { gate.yield(()); gate.finish() }
    }
}
#endif
