#if os(macOS)
import Foundation
import Testing
@testable import PicoMarkdownView

@Suite("Mermaid overlapping resize renders")
struct MermaidResizeRaceTests {
    @Test("An older resize cannot pair the newest drawing with its stale width cap", .timeLimit(.minutes(1)))
    func staleResizeKeepsDrawingWidthTogether() async throws {
        let provider = ResizeGatedVectorProvider()
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer(theme: .default().withMermaidRendering(.onFenceClose),
                                        mermaidProvider: provider) { await assembler.block($0) }
        _ = await renderer.updateMermaidContentWidth(800)
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed("```mermaid\nflowchart LR\n A --> B\n```\n")))
        _ = await renderer.apply(await assembler.apply(await tokenizer.finish()))
        let initial = try #require(await renderer.renderedBlocks().first?.mermaidDiagram)
        #expect(initial.maxWidth == 800)
        #expect(initial.svg?.contains("width:800") == true)

        let shrinking = Task { await renderer.updateMermaidContentWidth(400) }
        await provider.waitUntilNarrowRenderStarts()
        // Simulate an immediate cached wide render overtaking the narrow one.
        _ = await renderer.updateMermaidContentWidth(800)
        #expect(await renderer.renderedBlocks().first?.mermaidDiagram?.maxWidth == 800)
        await provider.releaseNarrowRender()
        _ = await shrinking.value

        let completed = try #require(await renderer.renderedBlocks().first?.mermaidDiagram)
        #expect(completed.svg == initial.svg)
        #expect(completed.maxWidth == 800,
                "Returning the newest SVG from an overtaken request must retain that SVG's width metadata")
        #expect(await renderer.updateMermaidContentWidth(800) == nil,
                "An unchanged width is a no-op, so it cannot repair stale metadata after the race")
    }
}

private actor ResizeGatedVectorProvider: MermaidVectorDiagramProvider {
    private var narrowStarted = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var finishWaiter: CheckedContinuation<Void, Never>?

    func renderVector(_ request: MermaidRenderRequest) async -> MermaidVectorRenderResult? {
        let width = request.targetWidth ?? 800
        if width == 400 {
            narrowStarted = true
            startWaiter?.resume()
            startWaiter = nil
            await withCheckedContinuation { finishWaiter = $0 }
        }
        return MermaidVectorRenderResult(
            svg: "<svg width=\"800\" height=\"200\"><text>width:\(Int(width))</text></svg>",
            intrinsicSize: CGSize(width: 800, height: 200))
    }

    func render(_ request: MermaidRenderRequest) async -> MermaidRenderResult? { nil }

    func waitUntilNarrowRenderStarts() async {
        guard !narrowStarted else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func releaseNarrowRender() {
        finishWaiter?.resume()
        finishWaiter = nil
    }
}
#endif
