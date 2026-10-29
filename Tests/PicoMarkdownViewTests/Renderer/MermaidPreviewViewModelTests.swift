#if os(macOS) && canImport(JavaScriptCore)
import AppKit
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
#endif
