#if canImport(JavaScriptCore)
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import PicoMarkdownView

@Suite
struct PeleDiagramProviderTests {
    private let flowchart = "flowchart LR\n  A[Start] --> B{Check} --> C[Finish]\n  B --> D[Other]"

    @Test("The default provider is Pele")
    func defaultProviderIsPele() {
        let provider = MermaidDiagramProviders.makeDefaultProvider(theme: .default())
        #expect(provider is PeleDiagramProvider)
        #expect(MermaidDiagramProviders.makeDefaultProvider(theme: .default().withMermaidRendering(.disabled)) == nil)
    }

    @Test("Renders a fence to an image with Pele's intrinsic size")
    func rendersImage() async throws {
        let provider = PeleDiagramProvider(theme: .default())
        let result = try #require(await provider.render(MermaidRenderRequest(source: flowchart, targetWidth: nil, scale: 2)))
        #expect(result.intrinsicSize.width > 100)
        #expect(result.intrinsicSize.height > 20)
        #expect(result.image.size == result.intrinsicSize, "the image is sized in points")

        let renderer = try #require(PeleRenderer.shared)
        let direct = try await renderer.render(flowchart, options: PeleRenderOptions(fontSize: MarkdownRenderTheme.default().bodyFont.pointSize, fontFamily: "sans-serif"))
        #expect(result.intrinsicSize == CGSize(width: direct.width, height: direct.height))
    }

    @Test("Unsupported or empty sources yield no diagram")
    func rejectsUnsupported() async {
        let provider = PeleDiagramProvider(theme: .default())
        #expect(await provider.render(MermaidRenderRequest(source: "not a diagram at all", targetWidth: nil, scale: 2)) == nil)
        #expect(await provider.render(MermaidRenderRequest(source: "   \n", targetWidth: nil, scale: 2)) == nil)

        let tiny = PeleDiagramProvider(theme: .default(), maxSourceLength: 8)
        #expect(await tiny.render(MermaidRenderRequest(source: flowchart, targetWidth: nil, scale: 2)) == nil)
    }

    @Test("A narrow target width makes the flowchart narrower")
    func respectsTargetWidth() async throws {
        let provider = PeleDiagramProvider(theme: .default())
        let wide = try #require(await provider.render(MermaidRenderRequest(source: flowchart, targetWidth: nil, scale: 2)))
        let narrow = try #require(await provider.render(MermaidRenderRequest(source: flowchart, targetWidth: 220, scale: 2)))
        #expect(narrow.intrinsicSize.width < wide.intrinsicSize.width)
        #expect(narrow.intrinsicSize.width <= 220)
    }

    @Test("Identical requests are served from the cache")
    func cachesResults() async throws {
        let provider = PeleDiagramProvider(theme: .default())
        let request = MermaidRenderRequest(source: flowchart, targetWidth: 500, scale: 2)
        let first = try #require(await provider.render(request))
        let second = try #require(await provider.render(request))
        #expect(first.image === second.image)

        let sameBucket = try #require(await provider.render(MermaidRenderRequest(source: flowchart, targetWidth: 503, scale: 2)))
        #expect(sameBucket.image === first.image, "widths are bucketed like the renderer's content width")

        let otherScale = try #require(await provider.render(MermaidRenderRequest(source: flowchart, targetWidth: 500, scale: 1)))
        #expect(otherScale.image !== first.image)
    }

    @Test("Theme colors reach the SVG for both appearances")
    func mapsThemeColors() throws {
        let theme = MarkdownRenderTheme.default()
        let light = PeleDiagramProvider.peleTheme(for: theme, appearance: .light)
        let dark = PeleDiagramProvider.peleTheme(for: theme, appearance: .dark)
        #expect(light["fg"] != dark["fg"])
        #expect(light["surface"] != dark["surface"])
        #expect(light["font"] == "sans-serif")
        for (_, value) in light {
            #expect(!value.contains(";"), "values are substituted into attributes verbatim")
        }
        let expectedLink = theme.linkColor.light
        let expectedHex = String(format: "#%02x%02x%02x",
                                 Int((expectedLink.red * 255).rounded()),
                                 Int((expectedLink.green * 255).rounded()),
                                 Int((expectedLink.blue * 255).rounded()))
        #expect(light["accent"] == expectedHex)
        let border = try #require(light["border"])
        #expect(border.hasPrefix("rgba("), "translucent colors keep their alpha")
    }

    @Test("Labels are measured with the system font, not Arial metrics")
    func measuresWithSystemFont() async throws {
        let text = "Measured label"
        let size: CGFloat = 14
        let expected = PeleTextMeasurer.width(of: text, size: size, style: 0, family: "sans-serif", monoFamily: "monospace")
        let font = PeleSVGFonts.font(family: "sans-serif", size: size, bold: false, italic: false)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]))
        #expect(abs(expected - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) < 0.001)

        let bold = PeleTextMeasurer.width(of: text, size: size, style: 1, family: "sans-serif", monoFamily: "monospace")
        #expect(bold > expected, "bold glyphs are wider")
        let superscript = PeleTextMeasurer.width(of: text, size: size, style: 16, family: "sans-serif", monoFamily: "monospace")
        #expect(superscript < expected, "superscripts render smaller")

        // A node's width is its label plus padding, so a wider label yields a wider node.
        let renderer = try #require(PeleRenderer.shared)
        let narrow = try await renderer.render("flowchart LR\n  A[iiii]", options: PeleRenderOptions(fontSize: size, fontFamily: "sans-serif"))
        let wide = try await renderer.render("flowchart LR\n  A[WWWW]", options: PeleRenderOptions(fontSize: size, fontFamily: "sans-serif"))
        let narrowLabel = PeleTextMeasurer.width(of: "iiii", size: size, style: 0, family: "sans-serif", monoFamily: "monospace")
        let wideLabel = PeleTextMeasurer.width(of: "WWWW", size: size, style: 0, family: "sans-serif", monoFamily: "monospace")
        #expect(abs((wide.width - narrow.width) - (wideLabel - narrowLabel)) < 1.0,
                "node widths differ by exactly the measured label difference")
    }

    @Test("Closed mermaid fences render through the default provider")
    func defaultPipelineRendersDiagram() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer(theme: MarkdownRenderTheme.default()) { id in
            await assembler.block(id)
        }
        let markdown = """
        ```mermaid
        sequenceDiagram
        Alice->>Bob: Hello
        ```

        """
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed(markdown)))
        _ = await renderer.apply(await assembler.apply(await tokenizer.finish()))

        let blocks = await renderer.renderedBlocks()
        let diagram = blocks.first?.mermaidDiagram
        #expect(diagram != nil)
        #expect((diagram?.size.width ?? 0) > 0)
        let content = blocks.first.map { String($0.content.characters) } ?? ""
        #expect(!content.contains("sequenceDiagram"))
    }
}
#endif
