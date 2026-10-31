#if os(macOS) && canImport(JavaScriptCore)
import Foundation
import Testing
@testable import PicoMarkdownView

@Suite("Progressive Mermaid previews")
struct MermaidProgressiveTests {
    @Test("Pele renders meaningful prefixes as a diagram grows", arguments: [
        ["flowchart LR\n A[Start]\n",
         "flowchart LR\n A[Start] --> B[Finish]\n",
         "flowchart LR\n A[Start] --> B[Finish]\n B --> C[Next]\n"],
        ["sequenceDiagram\n participant Alice\n",
         "sequenceDiagram\n Alice->>Bob: Hello\n",
         "sequenceDiagram\n Alice->>Bob: Hello\n Bob-->>Alice: Hi\n"]
    ])
    func realPeleRendersGrowingPrefixes(_ sources: [String]) async throws {
        let renderer = try #require(PeleRenderer.shared)
        var previous: PeleRenderResult?
        for source in sources {
            let result = try await renderer.render(source)
            #expect(result.width > 0)
            #expect(result.height > 0)
            #expect(result.svg.hasPrefix("<svg"))
            if let previous {
                #expect(result.svg != previous.svg)
            }
            previous = result
        }
    }

    @Test("An unfinished statement can fail and later become valid")
    func realPeleAcceptsCompletedPartialStatement() async throws {
        let renderer = try #require(PeleRenderer.shared)
        let prefix = "flowchart LR\n A[Start] --> B[Finish]\n B --> C[\n"
        await #expect(throws: PeleRenderError.self) {
            try await renderer.render(prefix)
        }
        let completed = try await renderer.render(prefix + "Next]\n")
        #expect(completed.width > 0)
        #expect(completed.svg.contains("Next"))
    }

    @Test("Preview attempts wait for a meaningful complete line")
    func partialLinesDoNotInvokePele() async throws {
        let fixture = makeFixture(mode: .bestEffortDebounced(milliseconds: 0))
        await fixture.feed("```mermaid\nflowchart LR\n")
        #expect(await fixture.provider.vectorCallCount() == 0)
        await fixture.feed(" A[Sta")
        #expect(await fixture.provider.vectorCallCount() == 0)
        await fixture.feed("rt]\n")
        #expect(await fixture.provider.vectorCallCount() == 1)
        let block = try #require(await fixture.renderer.renderedBlocks().first)
        #expect(block.mermaidDiagram?.svg != nil)
        #expect(block.snapshot.isClosed == false)
        #expect(await fixture.provider.bitmapCallCount() == 0)
    }

    @Test("Invalid streamed tails retain the last valid vector and current source")
    func invalidTailRetainsLastValidPreview() async throws {
        let fixture = makeFixture(mode: .bestEffortDebounced(milliseconds: 0))
        await fixture.feed("```mermaid\nflowchart LR\n A[Start] --> B[Finish]\n")
        let initial = try #require(await fixture.renderer.renderedBlocks().first?.mermaidDiagram)
        let initialSVG = try #require(initial.svg)
        #expect(await fixture.provider.vectorCallCount() == 1)

        await fixture.feed(" B --> C[")
        #expect(await fixture.provider.vectorCallCount() == 1)
        await fixture.feed("\n")
        let pending = try #require(await fixture.renderer.renderedBlocks().first?.mermaidDiagram)
        #expect(pending.svg == initialSVG)
        #expect(pending.source.hasSuffix(" B --> C[\n"))
        #expect(await fixture.provider.vectorCallCount() == 2)

        await fixture.feed("Next]\n")
        let next = try #require(await fixture.renderer.renderedBlocks().first?.mermaidDiagram)
        #expect(next.svg != initialSVG)
        #expect(next.source.hasSuffix("Next]\n"))
        #expect(await fixture.provider.vectorCallCount() == 3)
    }

    @Test("Closing a fence forces the final source despite the preview interval")
    func closeForcesFinalRender() async throws {
        let fixture = makeFixture(mode: .bestEffortDebounced(milliseconds: 600_000))
        await fixture.feed("```mermaid\nflowchart LR\n A[Start]\n")
        #expect(await fixture.provider.vectorCallCount() == 1)
        await fixture.feed(" A --> B[Finish]\n")
        #expect(await fixture.provider.vectorCallCount() == 1)
        await fixture.feed("```\n")
        #expect(await fixture.provider.vectorCallCount() == 2)
        let block = try #require(await fixture.renderer.renderedBlocks().first)
        #expect(block.snapshot.isClosed)
        #expect(block.mermaidDiagram?.source.contains("Finish") == true)
        #expect(await fixture.provider.lastVectorSource()?.contains("Finish") == true)
    }

    @Test("Finishing an unfenced stream includes its final unterminated source line")
    func finishForcesFinalUnterminatedLine() async throws {
        let fixture = makeFixture(mode: .bestEffortDebounced(milliseconds: 600_000))
        await fixture.feed("```mermaid\nflowchart LR\n A[Start]\n")
        #expect(await fixture.provider.vectorCallCount() == 1)
        await fixture.feed(" A --> B[Last node]")
        #expect(await fixture.provider.vectorCallCount() == 1)
        let result = await fixture.tokenizer.finish()
        let diff = await fixture.assembler.apply(result)
        _ = await fixture.renderer.apply(diff)
        let final = try #require(await fixture.renderer.renderedBlocks().first)
        #expect(final.snapshot.isClosed)
        #expect(await fixture.provider.vectorCallCount() == 2)
        #expect(final.mermaidDiagram?.source.contains("Last node") == true)
        #expect(await fixture.provider.lastVectorSource()?.contains("Last node") == true)
    }

    @Test("Fence-close mode preserves the native source preview")
    func fenceCloseModeDoesNotRenderOpenSource() async throws {
        let fixture = makeFixture(mode: .onFenceClose)
        await fixture.feed("```mermaid\nflowchart LR\n A[Start]\n")
        #expect(await fixture.provider.vectorCallCount() == 0)
        let open = try #require(await fixture.renderer.renderedBlocks().first)
        #expect(open.mermaidDiagram == nil)
        #expect(String(open.content.characters).contains("A[Start]"))
        await fixture.feed("```\n")
        #expect(await fixture.provider.vectorCallCount() == 1)
        #expect(await fixture.renderer.renderedBlocks().first?.mermaidDiagram?.svg != nil)
    }

    @Test("Invalid final source falls back to native code instead of a stale diagram")
    func invalidFinalSourceFallsBack() async throws {
        let fixture = makeFixture(mode: .bestEffortDebounced(milliseconds: 0))
        await fixture.feed("```mermaid\nflowchart LR\n A[Start]\n")
        #expect(await fixture.renderer.renderedBlocks().first?.mermaidDiagram?.svg != nil)
        await fixture.feed(" B --> C[\n")
        await fixture.feed("```\n")
        let final = try #require(await fixture.renderer.renderedBlocks().first)
        #expect(final.snapshot.isClosed)
        #expect(final.mermaidDiagram == nil)
        #expect(String(final.content.characters).contains(" B --> C["))
        #expect(await fixture.provider.bitmapCallCount() == 0)
    }

    @Test("Large open sources skip previews but can still render on close", arguments: [
        "flowchart LR\n A[" + String(repeating: "x", count: 8_300) + "]\n",
        "flowchart LR\n" + String(repeating: " A --> B\n", count: 260)
    ])
    func openPreviewBudgetDoesNotDisableFinalRender(_ body: String) async throws {
        let fixture = makeFixture(mode: .bestEffortDebounced(milliseconds: 0))
        await fixture.feed("```mermaid\n" + body)
        #expect(await fixture.provider.vectorCallCount() == 0)
        await fixture.feed("```\n")
        #expect(await fixture.provider.vectorCallCount() == 1)
        #expect(await fixture.renderer.renderedBlocks().first?.mermaidDiagram?.svg != nil)
    }

    private func makeFixture(mode: MermaidRenderingMode) -> ProgressiveFixture {
        let provider = ProgressiveVectorProvider()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer(theme: .default().withMermaidRendering(mode),
                                        mermaidProvider: provider) { id in
            await assembler.block(id)
        }
        return ProgressiveFixture(tokenizer: MarkdownTokenizer(), assembler: assembler,
                                  renderer: renderer, provider: provider)
    }
}

private struct ProgressiveFixture: Sendable {
    let tokenizer: MarkdownTokenizer
    let assembler: MarkdownAssembler
    let renderer: MarkdownRenderer
    let provider: ProgressiveVectorProvider

    func feed(_ text: String) async {
        let result = await tokenizer.feed(text)
        let diff = await assembler.apply(result)
        _ = await renderer.apply(diff)
    }
}

private actor ProgressiveVectorProvider: MermaidVectorDiagramProvider {
    private var vectorSources: [String] = []
    private var bitmapCalls = 0

    func renderVector(_ request: MermaidRenderRequest) async -> MermaidVectorRenderResult? {
        vectorSources.append(request.source)
        guard !request.source.hasSuffix("C[\n") else { return nil }
        let width: CGFloat = 220
        let height: CGFloat = 120
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="220" height="120" viewBox="0 0 220 120">
        <rect x="1" y="1" width="218" height="118" fill="#2266cc"/>
        <text x="8" y="24">Source bytes: \(request.source.utf8.count)</text>
        </svg>
        """
        return MermaidVectorRenderResult(svg: svg, intrinsicSize: CGSize(width: width, height: height))
    }

    func render(_ request: MermaidRenderRequest) async -> MermaidRenderResult? {
        bitmapCalls += 1
        return nil
    }

    func vectorCallCount() -> Int { vectorSources.count }
    func bitmapCallCount() -> Int { bitmapCalls }
    func lastVectorSource() -> String? { vectorSources.last }
}
#endif
