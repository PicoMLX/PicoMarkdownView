import Foundation
import Testing
@testable import PicoMarkdownView

enum VegaLiteRenderingFixture {
    static let source = #"""
    {
      "description" : "Keep  spaces and an escaped \n, 🧭.",
      "width": 300,
      "height": 120,
      "data" : {"values" : [{"category" : "A", "value": 2}, {"category" : "B", "value": 5}]},
      "mark": "bar",
      "encoding": {
        "x": {"field": "category", "type": "nominal"},
        "y": {"field": "value", "type": "quantitative"}
      }
    }
    """# + "\n"

    static func markdown(source: String = source, language: String = "vega-lite") -> String {
        "```" + language + "\n" + source + "```\n\n"
    }

    static func theme(maxWidth: CGFloat) -> MarkdownRenderTheme {
        let defaults = MarkdownRenderTheme.default()
        return MarkdownRenderTheme(bodyFont: defaults.bodyFont,
                                   codeFont: defaults.codeFont,
                                   blockquoteColor: defaults.blockquoteColor,
                                   linkColor: defaults.linkColor,
                                   headingFonts: defaults.headingFonts,
                                   imageMaxWidth: maxWidth,
                                   codeBlockTheme: defaults.codeBlockTheme,
                                   codeHighlighter: defaults.codeHighlighter,
                                   mermaidRenderingMode: .disabled)
    }
}

@Suite("Vega-Lite fence rendering")
struct VegaLiteRendererTests {
    @Test("Theme copies preserve the independent chart setting")
    func themeCopiesPreserveChartSetting() {
        let disabled = MarkdownRenderTheme.default().withVegaLiteRendering(false)
        #expect(disabled.vegaLiteRenderingEnabled == false)
        #expect(disabled.scaled(by: 1.5).vegaLiteRenderingEnabled == false)
        #expect(disabled.withMermaidRendering(.disabled).vegaLiteRenderingEnabled == false)
        #expect(disabled.withCodeHighlighting(codeBlockTheme: nil, codeHighlighter: nil).vegaLiteRenderingEnabled == false)
        #expect(disabled.withVegaLiteRendering(true).vegaLiteRenderingEnabled)
    }

    @Test("Single-shot and split chunks produce the same chart, source and surrounding text")
    func chunkSplitsProduceEquivalentRendering() async throws {
        let markdown = "Before 🧭.\n\n" + VegaLiteRenderingFixture.markdown() + "After **native** text.\n\n"
        let baseline = await render(markdown, chunkSize: markdown.count)
        for chunkSize in [1, 7, 29] {
            let streamed = await render(markdown, chunkSize: chunkSize)
            #expect(streamed.map(\.kind) == baseline.map(\.kind), "Chunk size \(chunkSize)")
            #expect(streamed.map { String($0.content.characters) } == baseline.map { String($0.content.characters) },
                    "Chunk size \(chunkSize)")
            #expect(streamed.map { $0.snapshot.codeText } == baseline.map { $0.snapshot.codeText })
            #expect(streamed.map { $0.snapshot.isClosed } == baseline.map { $0.snapshot.isClosed })
#if os(macOS)
            let expected = try #require(baseline.compactMap(\.vegaLiteChart).first)
            let chart = try #require(streamed.compactMap(\.vegaLiteChart).first)
            #expect(streamed.compactMap(\.vegaLiteChart).count == 1)
            #expect(chart.source == VegaLiteRenderingFixture.source)
            #expect(chart.source == expected.source)
            #expect(chart.language == expected.language)
            #expect(chart.intrinsicSize == expected.intrinsicSize)
            #expect(chart.svg.contains("<svg"))
#else
            #expect(streamed.allSatisfy { $0.vegaLiteChart == nil })
            #expect(streamed.contains { String($0.content.characters).contains(VegaLiteRenderingFixture.source) })
#endif
        }
    }

#if os(iOS)
    @Test("Vega-Lite stays native code on iOS even when enabled")
    func iOSKeepsExistingCodeRendering() async throws {
        let blocks = await render(VegaLiteRenderingFixture.markdown(), chunkSize: 11)
        let block = try #require(blocks.first)
        #expect(block.snapshot.isClosed)
        #expect(block.vegaLiteChart == nil)
        #expect(block.mermaidDiagram == nil)
        #expect(block.codeBlock?.code == VegaLiteRenderingFixture.source)
        #expect(String(block.content.characters).contains(VegaLiteRenderingFixture.source))
    }
#endif

    private func render(_ markdown: String, chunkSize: Int) async -> [RenderedBlock] {
        let pipeline = MarkdownStreamingPipeline()
        var start = markdown.startIndex
        while start < markdown.endIndex {
            let end = markdown.index(start, offsetBy: chunkSize, limitedBy: markdown.endIndex) ?? markdown.endIndex
            _ = await pipeline.feed(String(markdown[start..<end]))
            start = end
        }
        _ = await pipeline.finish()
        return await pipeline.blocksSnapshot()
    }
}
