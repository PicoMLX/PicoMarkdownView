#if os(macOS) && canImport(JavaScriptCore)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS presentation cancellation", .timeLimit(.minutes(1)))
@MainActor
struct MacPresentationCancellationTests {
    @Test("Already cancelled view-model refreshes neither change nor memoize presentation", arguments: MacPresentationChange.allCases)
    func cancelledViewModelEntry(_ change: MacPresentationChange) async throws {
        let model = MarkdownStreamingViewModel()
        await model.updateMermaidContentWidth(336)
        await model.consume(.text(chartMarkdown))
        await drainMainQueue()
        let original = try #require(model.blocks.first?.vegaLiteChart)

        let task = Task { @MainActor in await change.apply(to: model) }
        task.cancel()
        await task.value
        await drainMainQueue()
        #expect(model.blocks.first?.vegaLiteChart == original)

        await change.apply(to: model)
        await drainMainQueue()
        try assertPresentation(model.blocks, change: change)
    }

    @Test("Already cancelled renderer refreshes leave the same request available for retry", arguments: MacPresentationChange.allCases)
    func cancelledRendererEntry(_ change: MacPresentationChange) async throws {
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.updateMermaidContentWidth(336)
        _ = await pipeline.feed(chartMarkdown)
        _ = await pipeline.finish()
        let original = try #require(await pipeline.blocksSnapshot().first?.vegaLiteChart)

        let task = Task { @MainActor in await change.apply(to: pipeline) }
        task.cancel()
        _ = await task.value
        #expect(await pipeline.blocksSnapshot().first?.vegaLiteChart == original)

        _ = await change.apply(to: pipeline)
        try assertPresentation(await pipeline.blocksSnapshot(), change: change)
    }

    @Test("Accepted view-model refreshes finish after caller cancellation and retain native chart state", arguments: MacPresentationChange.allCases)
    func cancelledAcceptedViewModelRefresh(_ change: MacPresentationChange) async throws {
        let fixture = try await makeFixture()
        let storage = try #require(fixture.view.textStorage)
        let original = try #require(chartAttachment(in: storage))
        fixture.view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let selection = fixture.view.selectedRange()
        let copied = fixture.view.markdownForSelection()

        await fixture.provider.holdNextRender()
        let task = Task { @MainActor in await change.apply(to: fixture.model) }
        await fixture.provider.waitUntilHeld()
        task.cancel()
        await fixture.provider.release()
        await task.value
        await drainMainQueue()
        apply(fixture)

        try assertPresentation(fixture.model.blocks, change: change)
        #expect(chartAttachment(in: storage) === original)
        #expect(fixture.view.selectedRange() == selection)
        #expect(fixture.view.markdownForSelection() == copied)
        #expect(original.markdownRepresentation() == chartMarkdown.trimmingCharacters(in: .newlines))
        let invalid = try #require(fixture.model.blocks.first { $0.snapshot.codeText == invalidSource })
        #expect(invalid.snapshot.isClosed)
        #expect(invalid.vegaLiteChart == nil)
        #expect(invalid.codeBlock?.code == invalidSource)

        // Identical requests may now deduplicate only because the accepted
        // operation actually completed, not because a cancelled render was cached.
        await change.apply(to: fixture.model)
        await drainMainQueue()
        try assertPresentation(fixture.model.blocks, change: change)
    }

    @Test("Accepted direct renderer refreshes finish after caller cancellation", arguments: MacPresentationChange.allCases)
    func cancelledAcceptedRendererRefresh(_ change: MacPresentationChange) async throws {
        let provider = PresentationGateProvider()
        let pipeline = MarkdownStreamingPipeline(theme: .default().withMermaidRendering(.onFenceClose),
                                                  mermaidProvider: provider)
        _ = await pipeline.updateMermaidContentWidth(336)
        _ = await pipeline.feed(mixedMarkdown)
        _ = await pipeline.finish()
        await provider.holdNextRender()
        let task = Task { @MainActor in await change.apply(to: pipeline) }
        await provider.waitUntilHeld()
        task.cancel()
        await provider.release()
        _ = await task.value
        try assertPresentation(await pipeline.blocksSnapshot(), change: change)
        _ = await change.apply(to: pipeline)
        try assertPresentation(await pipeline.blocksSnapshot(), change: change)
    }

    @Test("A newer width wins while a cancelled older refresh finishes")
    func newerWidthWins() async throws {
        let fixture = try await makeFixture()
        await fixture.provider.holdNextRender()
        let older = Task { @MainActor in await fixture.model.updateMermaidContentWidth(400) }
        await fixture.provider.waitUntilHeld()
        older.cancel()
        await fixture.model.updateMermaidContentWidth(240)
        await drainMainQueue()
        #expect(fixture.model.blocks.compactMap(\.vegaLiteChart).first?.maxWidth == 240)
        await fixture.provider.release()
        await older.value
        await drainMainQueue()
        #expect(fixture.model.blocks.compactMap(\.vegaLiteChart).first?.maxWidth == 240)
        #expect(fixture.model.blocks.compactMap(\.vegaLiteChart).count == 1)
    }

    @Test("A newer scale wins while a cancelled older refresh finishes")
    func newerScaleWins() async throws {
        let fixture = try await makeFixture()
        await fixture.provider.holdNextRender()
        let older = Task { @MainActor in await fixture.model.updateTextScale(1.25) }
        await fixture.provider.waitUntilHeld()
        older.cancel()
        await fixture.model.updateTextScale(1.5)
        await drainMainQueue()
        await fixture.provider.release()
        await older.value
        await drainMainQueue()
        let chart = try #require(fixture.model.blocks.first { $0.vegaLiteChart != nil })
        #expect(abs(fontSize(in: chart) - MarkdownRenderTheme.default().bodyFont.pointSize * 1.5) < 0.01)
    }

    @Test("Completing a cancelled refresh cannot publish into a replacement document")
    func replacementDocumentWins() async throws {
        let fixture = try await makeFixture()
        await fixture.provider.holdNextRender()
        let older = Task { @MainActor in await fixture.model.updateMermaidContentWidth(400) }
        await fixture.provider.waitUntilHeld()
        older.cancel()
        await fixture.model.consume(.text("Replacement prose.\n\n"))
        await fixture.provider.release()
        await older.value
        await drainMainQueue()
        apply(fixture)
        #expect(fixture.model.blocks.map { String($0.content.characters) }.joined() == "Replacement prose.\n")
        #expect(fixture.model.blocks.allSatisfy { $0.vegaLiteChart == nil })
        #expect(chartAttachment(in: try #require(fixture.view.textStorage)) == nil)
    }

    private let source = "{\"data\":{\"values\":[{\"x\":\"A\",\"y\":1},{\"x\":\"B\",\"y\":2}]},\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"x\",\"type\":\"nominal\"},\"y\":{\"field\":\"y\",\"type\":\"quantitative\"}}}\n"
    private let invalidSource = "{\"mark\":\"bar\",broken JSON}\n"
    private var chartMarkdown: String { "```vega-lite\n" + source + "```\n" }
    private var mixedMarkdown: String {
        "```mermaid\nflowchart LR\nA --> B\n```\n\n" + chartMarkdown + "\n```vega-lite\n" + invalidSource + "```\n"
    }

    private struct Fixture {
        let model: MarkdownStreamingViewModel
        let provider: PresentationGateProvider
        let controller: TextKitStreamingController
        let view: StreamingTextKit2View
    }

    private func makeFixture() async throws -> Fixture {
        let provider = PresentationGateProvider()
        let model = MarkdownStreamingViewModel(theme: .default().withMermaidRendering(.onFenceClose),
                                               mermaidProvider: provider)
        await model.updateMermaidContentWidth(336)
        await model.consume(.text(mixedMarkdown))
        await drainMainQueue()
        let controller = TextKitStreamingController()
        let view = try #require(controller.makeTextKit2View(configuration: .default()) as? StreamingTextKit2View)
        view.frame = NSRect(x: 0, y: 0, width: 336, height: 900)
        let fixture = Fixture(model: model, provider: provider, controller: controller, view: view)
        apply(fixture)
        #expect(model.blocks.compactMap(\.vegaLiteChart).count == 1)
        return fixture
    }

    private func apply(_ fixture: Fixture) {
        fixture.controller.update(textView: fixture.view, blocks: fixture.model.blocks, diffs: fixture.model.diffQueue,
                                  replaceToken: fixture.model.replaceToken, configuration: .default(),
                                  documentIdentity: fixture.model.documentIdentity)
    }

    private func assertPresentation(_ blocks: [RenderedBlock], change: MacPresentationChange) throws {
        let block = try #require(blocks.first { $0.vegaLiteChart != nil })
        let chart = try #require(block.vegaLiteChart)
        #expect(block.snapshot.isClosed)
        #expect(chart.source == source)
        #expect(block.snapshot.codeText == source)
        #expect(blocks.compactMap(\.vegaLiteChart).count == 1)
        switch change {
        case .scale:
            #expect(abs(fontSize(in: block) - MarkdownRenderTheme.default().bodyFont.pointSize * 1.25) < 0.01)
        case .width:
            #expect(chart.maxWidth == 240)
        }
    }

    private func fontSize(in block: RenderedBlock) -> CGFloat {
        (NSAttributedString.picoConverted(from: block.content).attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
    }

    private func chartAttachment(in storage: NSTextStorage) -> PicoHostedAttachment? {
        var result: PicoHostedAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let attachment = value as? PicoHostedAttachment,
                  attachment.markdownRepresentation().hasPrefix("```vega-lite\n") else { return }
            result = attachment
            stop.pointee = true
        }
        return result
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

enum MacPresentationChange: CaseIterable, Sendable {
    case scale, width

    @MainActor
    func apply(to model: MarkdownStreamingViewModel) async {
        switch self {
        case .scale: await model.updateTextScale(1.25)
        case .width: await model.updateMermaidContentWidth(240)
        }
    }

    func apply(to pipeline: MarkdownStreamingPipeline) async -> [RenderedBlock]? {
        switch self {
        case .scale: await pipeline.updateTextScale(1.25)
        case .width: await pipeline.updateMermaidContentWidth(240)
        }
    }
}

private actor PresentationGateProvider: MermaidVectorDiagramProvider {
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func holdNextRender() { holdNext = true }

    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        held?.resume()
        held = nil
    }

    func renderVector(_ request: MermaidRenderRequest) async -> MermaidVectorRenderResult? {
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                held = continuation
                for waiter in waiters { waiter.resume() }
                waiters.removeAll()
            }
        }
        let svg = "<svg width=\"200\" height=\"80\"><rect width=\"200\" height=\"80\" fill=\"red\"/></svg>"
        return MermaidVectorRenderResult(svg: svg, intrinsicSize: CGSize(width: 200, height: 80))
    }

    func render(_ request: MermaidRenderRequest) async -> MermaidRenderResult? { nil }
}
#endif
