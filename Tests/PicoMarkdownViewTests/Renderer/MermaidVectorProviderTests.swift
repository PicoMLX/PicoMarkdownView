#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS Mermaid vector provider")
struct MermaidVectorProviderTests {
    private let source = "flowchart LR\n  A[Start] --> B{Check} --> C[Finish]\n  B --> D[Other]"

    @Test("Pele returns drawable SVG and its point size without rasterizing")
    func returnsVectorData() async throws {
        let provider: any MermaidVectorDiagramProvider = PeleDiagramProvider(theme: .default())
        let result = try #require(await provider.renderVector(MermaidRenderRequest(source: source, targetWidth: nil, scale: 2)))
        let drawing = try #require(PeleSVGDocument(svg: result.svg))
        #expect(result.svg.contains("<svg"))
        #expect(result.svg.contains("Start"))
        #expect(result.intrinsicSize == CGSize(width: drawing.width, height: drawing.height))
        #expect(result.intrinsicSize.width > 100)
        #expect(result.intrinsicSize.height > 20)
        #expect(result.diagnostics == nil)
    }

    @Test("Unsupported, empty and over-limit source has no vector result")
    func rejectsInvalidInput() async {
        let provider = PeleDiagramProvider(theme: .default())
        #expect(await provider.renderVector(MermaidRenderRequest(source: "not a diagram", targetWidth: nil, scale: 2)) == nil)
        #expect(await provider.renderVector(MermaidRenderRequest(source: " \n\t", targetWidth: nil, scale: 2)) == nil)
        let short = PeleDiagramProvider(theme: .default(), maxSourceLength: 8)
        #expect(await short.renderVector(MermaidRenderRequest(source: source, targetWidth: nil, scale: 2)) == nil)
        let fewLines = PeleDiagramProvider(theme: .default(), maxLineCount: 2)
        #expect(await fewLines.renderVector(MermaidRenderRequest(source: source, targetWidth: nil, scale: 2)) == nil)
    }

    @Test("Available width still constrains vector layout")
    func respectsLayoutWidth() async throws {
        let provider = PeleDiagramProvider(theme: .default())
        let wide = try #require(await provider.renderVector(MermaidRenderRequest(source: source, targetWidth: nil, scale: 2)))
        let narrow = try #require(await provider.renderVector(MermaidRenderRequest(source: source, targetWidth: 220, scale: 2)))
        #expect(narrow.intrinsicSize.width < wide.intrinsicSize.width)
        #expect(narrow.intrinsicSize.width <= 220)
        #expect(narrow.svg != wide.svg)
    }

    @Test("Vectors ignore display scale and retain width-bucket reuse")
    func scaleIndependentGeometry() async throws {
        // Initialize AppKit before requesting the appearance-dependent cache.
        await MainActor.run { _ = NSApplication.shared }
        let provider = PeleDiagramProvider(theme: .default())
        let initial = try #require(await provider.renderVector(MermaidRenderRequest(source: source, targetWidth: 500, scale: 1)))
        let scaled = try #require(await provider.renderVector(MermaidRenderRequest(source: source, targetWidth: 503, scale: .greatestFiniteMagnitude)))
        #expect(scaled == initial, "display scale must not create a raster-sized result")
        let normalized = source.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(await provider.renderVector(MermaidRenderRequest(source: normalized, targetWidth: 500, scale: 2)) == initial)
    }

    @Test("The vector route leaves the bitmap provider contract available")
    func bitmapCompatibility() async throws {
        let provider = PeleDiagramProvider(theme: .default())
        let vector = try #require(await provider.renderVector(MermaidRenderRequest(source: source, targetWidth: 220, scale: 2)))
        let bitmap = try #require(await provider.render(MermaidRenderRequest(source: source, targetWidth: 220, scale: 2)))
        #expect(bitmap.intrinsicSize == vector.intrinsicSize)
        #expect(bitmap.image.size == vector.intrinsicSize)
    }

    @Test("A cancelled vector request produces no result")
    func cancelledRequest() async {
        let provider = PeleDiagramProvider(theme: .default())
        let request = MermaidRenderRequest(source: source, targetWidth: 220, scale: 2)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await provider.renderVector(request)
        }
        #expect(await task.value == nil)
    }

    @Test("Cancelling a closed render does not cache a failed attempt")
    func cancelledClosedRenderCanRetry() async throws {
        let provider = CancelledFirstVectorProvider()
        let builder = MarkdownAttributeBuilder(theme: .default().withMermaidRendering(.onFenceClose),
                                               mermaidProvider: provider,
                                               runtimeMermaidMaxWidth: 220)
        let snapshot = BlockSnapshot(id: 1, kind: .fencedCode(language: "mermaid"),
                                     codeText: source, isClosed: true)
        let task = Task { await builder.render(snapshot: snapshot) }
        await provider.waitForFirstRequest()
        task.cancel()
        await provider.finishFirstRequest()
        #expect(await task.value.mermaidDiagram == nil)

        let retry = await builder.render(snapshot: snapshot)
        #expect(await provider.callCount == 2)
        let diagram = try #require(retry.mermaidDiagram)
        #expect(diagram.svg != nil)
        #expect(diagram.source == source)
    }

    @Test("Growing previews and the completed result retain the current source")
    func completesGrowingPreviews() async throws {
        let provider = PeleDiagramProvider(theme: .default(), maxEntries: 1)
        let first = "flowchart LR\n A[Start]\n"
        let final = first + " A --> B[Finish]\n"
        let initial = try #require(await provider.renderVector(MermaidRenderRequest(source: first, targetWidth: 220,
                                                                                   scale: 1, isPreview: true)))
        let preview = try #require(await provider.renderVector(MermaidRenderRequest(source: final, targetWidth: 220,
                                                                                   scale: 1, isPreview: true)))
        #expect(preview.svg.contains("Finish"))
        #expect(preview.svg != initial.svg)
        let completed = try #require(await provider.renderVector(MermaidRenderRequest(source: final, targetWidth: 220,
                                                                                     scale: 2)))
        #expect(completed == preview)
        #expect(await provider.renderVector(MermaidRenderRequest(source: final, targetWidth: 220, scale: 1)) == completed)
    }
}

private actor CancelledFirstVectorProvider: MermaidVectorDiagramProvider {
    private(set) var callCount = 0
    private var firstRequestStarted = false
    private var started: CheckedContinuation<Void, Never>?
    private var finish: CheckedContinuation<Void, Never>?

    func renderVector(_ request: MermaidRenderRequest) async -> MermaidVectorRenderResult? {
        callCount += 1
        if callCount == 1 {
            firstRequestStarted = true
            started?.resume()
            started = nil
            await withCheckedContinuation { finish = $0 }
            return nil
        }
        let svg = "<svg width=\"220\" height=\"120\"><rect width=\"220\" height=\"120\"/></svg>"
        return MermaidVectorRenderResult(svg: svg, intrinsicSize: CGSize(width: 220, height: 120))
    }

    func render(_ request: MermaidRenderRequest) async -> MermaidRenderResult? { nil }

    func waitForFirstRequest() async {
        guard !firstRequestStarted else { return }
        await withCheckedContinuation { started = $0 }
    }

    func finishFirstRequest() {
        finish?.resume()
        finish = nil
    }
}
#endif
