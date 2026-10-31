#if os(macOS)
import Foundation
import Testing
@testable import PicoMarkdownView

@Suite struct VegaLiteChartProviderTests {
    private static let bars = #"{"data":{"values":[{"category":"Alpha","value":28},{"category":"Beta","value":55}]},"mark":"bar","encoding":{"x":{"field":"category","type":"nominal"},"y":{"field":"value","type":"quantitative"}}}"#

    @Test func officialCompilerRendersInlineDataThroughNativeSVG() async throws {
        let provider = VegaLiteChartProvider(theme: .default())
        let result = try #require(await provider.render(source: Self.bars, targetWidth: 400))
        #expect(result.intrinsicSize.width > 100)
        #expect(result.intrinsicSize.width <= 400)
        #expect(result.intrinsicSize.height > 100)
        #expect(result.svg.contains("Alpha"))
        #expect(result.svg.contains("Beta"))
        let document = try #require(PeleSVGDocument(svg: result.svg, dialect: .vega))
        #expect(document.makeCGImage(scale: 1) != nil)
        let repeatResult = await provider.render(source: Self.bars, targetWidth: 400)
        #expect(repeatResult == result)
        let narrow = try #require(await provider.render(source: Self.bars, targetWidth: 240))
        #expect(narrow.intrinsicSize.width < result.intrinsicSize.width)
    }

    @Test(arguments: [
        #"{"data":{"url":"https://example.com/data.json"},"mark":"bar"}"#,
        #"{"data":{"values":[{}]},"mark":"image"}"#,
        #"{"data":{"sequence":{"start":0,"stop":1e12}},"mark":"bar"}"#,
        #"{"data":{"values":[{}]},"mark":"bar","transform":[{"density":"x","steps":1e12}]}"#,
        #"{"data":{"values":[{}]},"mark":"bar","encoding":{"x":{"field":"x","axis":{"tickCount":"millisecond"}}}}"#,
        #"{"data":{"values":[{}]},"mark":{"type":"text","fontSize":1e12}}"#,
        #"{"repeat":{"invalid":["x"]},"spec":{"mark":"bar"}}"#,
        #"{"mark":"bar","width":1e12}"#,
        #"{"mark":"bar","encoding":{"x":{"field":"x","axis":{"format":"1000000000f"}}}}"#,
        #"{"mark":"bar","encoding":{"x":{"axis":{"values":[{"signal":"range(0, 1000000000)"}]}}}}"#,
        #"{"mark":"bar","encoding":{"color":{"scale":{"scheme":{"name":"blues","count":1000000000}}}}}"#,
        #"{"mark":"bar","encoding":{"x":{"scale":{"bins":{"start":0,"stop":1000000000,"step":1}}}}}"#,
        #"{"data":{"values":[{"x":0},{"x":1000000000}]},"mark":"bar","encoding":{"x":{"field":"x","bin":{"step":1}}}}"#,
        #"{"data":{"values":[{"type":"Point","coordinates":[0,0]}]},"mark":"geoshape","projection":{"type":"mercator","precision":1e-100}}"#,
        "not JSON"
    ])
    func unsafeOrUnboundedSpecFailsPreflight(_ source: String) {
        #expect(!VegaLiteSpecPolicy.accepts(source))
    }

    @Test func boundedExpressionsRenderFilteredCalculatedAndConditionalMarks() async throws {
        let source = #"{"data":{"values":[{"category":"A","x":1},{"category":"B","x":3},{"category":"C","x":5}]},"transform":[{"filter":{"and":["datum.x > 1",{"field":"x","lte":5}]}},{"calculate":"datum.x * 2","as":"doubled"}],"mark":"bar","encoding":{"x":{"field":"category","type":"nominal"},"y":{"field":"doubled","type":"quantitative"},"color":{"condition":{"test":"datum.x > 4","value":"red"},"value":"blue"}}}"#
        #expect(VegaLiteSpecPolicy.accepts(source))
        let provider = VegaLiteChartProvider(theme: .default())
        let result = try #require(await provider.render(source: source, targetWidth: 336))
        let document = try #require(PeleSVGDocument(svg: result.svg, dialect: .vega))
        let marks = Self.descendants(document.root).filter { $0.attributes["aria-roledescription"] == "bar" }
        #expect(marks.count == 2)
        #expect(marks.contains { $0.attributes["aria-label"]?.contains("doubled: 6") == true })
        #expect(marks.contains { $0.attributes["aria-label"]?.contains("doubled: 10") == true })
        #expect(Set(marks.compactMap { $0.attributes["fill"] }).count == 2)
        #expect(!result.svg.contains("NaN"))
        #expect(document.makeCGImage(scale: 1) != nil)
    }

    @Test(arguments: [
        "repeat('x', 1000000000)", "sequence(0, 1e12)", "format(1, '1000000000f')",
        "datum.x.toString()", "datum['constructor']", "datum[datum.x]", "data('secret')",
        "test(/(a+)+$/, datum.x)", "window", "datum.x = 3", "datum.x +", "[datum.x]"
    ])
    func unsupportedExpressionsFailBeforeRendering(_ expression: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "data": ["values": [["x": 2]]], "mark": "bar",
            "transform": [["calculate": expression, "as": "y"]],
            "encoding": ["y": ["field": "y", "type": "quantitative"]]
        ])
        let source = String(decoding: data, as: UTF8.self)
        // The structural pass delegates expression syntax to the official AST parser.
        #expect(VegaLiteSpecPolicy.accepts(source))
        let provider = VegaLiteChartProvider(theme: .default())
        #expect(await provider.render(source: source, targetWidth: 336) == nil)
    }

    @Test(arguments: ["datum.toString", "datum.valueOf"])
    func inheritedFunctionsAreNotScalarExpressionResults(_ expression: String) async throws {
        let source = "{\"data\":{\"values\":[{\"x\":1}]},\"transform\":[{\"calculate\":\"" + expression + "\",\"as\":\"label\"}],\"mark\":\"text\",\"encoding\":{\"text\":{\"field\":\"label\"}}}"
        let provider = VegaLiteChartProvider(theme: .default())
        #expect(await provider.render(source: source, targetWidth: 336) == nil)
    }

    @Test func expressionResultsCannotGrowAcrossCalculationStages() async throws {
        let source = #"{"data":{"values":[{"label":"xxxxxxxx"}]},"transform":[{"calculate":"datum.label + datum.label","as":"label"},{"calculate":"datum.label + datum.label","as":"label"},{"calculate":"datum.label + datum.label","as":"label"},{"calculate":"datum.label + datum.label","as":"label"},{"calculate":"datum.label + datum.label","as":"label"},{"calculate":"datum.label + datum.label","as":"label"},{"calculate":"datum.label + datum.label","as":"label"},{"calculate":"datum.label + datum.label","as":"label"},{"calculate":"datum.label + datum.label","as":"label"},{"calculate":"datum.label + datum.label","as":"label"},{"calculate":"datum.label + datum.label","as":"label"}],"mark":"text","encoding":{"text":{"field":"label"}}}"#
        #expect(VegaLiteSpecPolicy.accepts(source))
        let provider = VegaLiteChartProvider(theme: .default())
        #expect(await provider.render(source: source, targetWidth: 336) == nil)
        // One failed chart must not poison the serial runtime's next render.
        #expect(await provider.render(source: Self.bars, targetWidth: 336) != nil)
    }

    @Test func dataColumnsAreNotInterpretedAsSpecificationKeys() {
        let source = #"{"data":{"values":[{"url":"https://example.com","expr":"column data","calculate":"ordinary column","filter":"ordinary column","test":"ordinary column","x":2}]},"mark":"bar","encoding":{"x":{"field":"x","type":"quantitative"}}}"#
        #expect(VegaLiteSpecPolicy.accepts(source))
    }

    @Test func boundedDeclarativeTransformsRemainAvailable() {
        let source = #"{"data":{"values":[{"category":"A","value":2},{"category":"A","value":3}]},"transform":[{"filter":{"field":"value","gte":2}},{"aggregate":[{"op":"sum","field":"value","as":"total"}],"groupby":["category"]}],"mark":"bar","encoding":{"x":{"field":"category","type":"nominal"},"y":{"field":"total","type":"quantitative"}}}"#
        #expect(VegaLiteSpecPolicy.accepts(source))
    }

    @Test func repeatedFieldsReferToTheEnclosingComposition() async throws {
        let source = #"{"data":{"values":[{"category":"A","first":2,"second":3},{"category":"B","first":4,"second":5}]},"repeat":{"layer":["first","second"]},"spec":{"mark":"bar","encoding":{"x":{"field":"category","type":"nominal"},"y":{"field":{"repeat":"layer"},"type":"quantitative"},"color":{"datum":{"repeat":"layer"},"type":"nominal"},"xOffset":{"datum":{"repeat":"layer"}}}}}"#
        #expect(VegaLiteSpecPolicy.accepts(source))
        let provider = VegaLiteChartProvider(theme: .default())
        let result = try #require(await provider.render(source: source, targetWidth: 336))
        let document = try #require(PeleSVGDocument(svg: result.svg, dialect: .vega))
        #expect(Self.descendants(document.root).filter { $0.attributes["aria-roledescription"] == "bar" }.count == 4)
        #expect(!result.svg.contains("NaN"))
    }

    @Test func tupleAndCompositionBudgetsApplyBeforeJavaScript() throws {
        let rows = Array(repeating: ["x": 1], count: 4_097)
        let data = try JSONSerialization.data(withJSONObject: ["data": ["values": rows], "mark": "bar"])
        #expect(!VegaLiteSpecPolicy.accepts(String(decoding: data, as: UTF8.self)))
        var child: [String: Any] = ["mark": "bar"]
        for _ in 0..<6 { child = ["layer": [child, ["mark": "bar"]]] }
        let layered = try JSONSerialization.data(withJSONObject: child)
        #expect(!VegaLiteSpecPolicy.accepts(String(decoding: layered, as: UTF8.self)))
        let maliciousRepeat = Dictionary(uniqueKeysWithValues: (0..<100).map { ("key\($0)", ["x", "y"]) })
        let repeated = try JSONSerialization.data(withJSONObject: ["repeat": maliciousRepeat, "spec": ["mark": "bar"]])
        #expect(!VegaLiteSpecPolicy.accepts(String(decoding: repeated, as: UTF8.self)))
    }

    @Test func automaticBinningRemainsBoundedForLargeDataExtents() async throws {
        let source = #"{"data":{"values":[{"x":0},{"x":1000000000}]},"mark":"bar","encoding":{"x":{"field":"x","type":"quantitative","bin":{"maxbins":20}},"y":{"aggregate":"count","type":"quantitative"}}}"#
        #expect(VegaLiteSpecPolicy.accepts(source))
        let provider = VegaLiteChartProvider(theme: .default())
        let result = try #require(await provider.render(source: source, targetWidth: 400))
        #expect(result.svg.utf8.count < 100_000)
    }

    @Test func allFiveExampleFencesProduceFiniteDataMarks() async throws {
        let provider = VegaLiteChartProvider(theme: .default())
        let minimumMarks = [3, 5, 5, 2, 1]
        let sources = try Self.exampleSources()
        try #require(sources.count == 5)
        for (index, source) in sources.enumerated() {
            let result = try #require(await provider.render(source: source, targetWidth: 480), "Example \(index + 1)")
            let document = try #require(PeleSVGDocument(svg: result.svg, dialect: .vega))
            #expect(!result.svg.contains("NaN"))
            #expect(!result.svg.contains("Infinity"))
            let marks = Self.descendants(document.root).filter {
                $0.name == "path" && $0.attributes["role"] == "graphics-symbol" &&
                    ["bar", "point", "line mark"].contains($0.attributes["aria-roledescription"] ?? "") &&
                    !($0.attributes["d"] ?? "").isEmpty
            }
            #expect(marks.count >= minimumMarks[index], "Example \(index + 1) must contain real data marks")
            if index == 1 {
                let line = try #require(marks.first { $0.attributes["aria-roledescription"] == "line mark" })
                #expect((line.attributes["d"] ?? "").filter { $0 == "L" }.count == 3)
                #expect(result.svg.contains("Monthly output"))
            }
        }
    }

    @Test func themeTextScalingChangesNativeChartLabels() async throws {
        let normal = VegaLiteChartProvider(theme: .default())
        let scaled = VegaLiteChartProvider(theme: MarkdownRenderTheme.default().scaled(by: 1.5))
        let first = try #require(await normal.render(source: Self.bars, targetWidth: 480))
        let second = try #require(await scaled.render(source: Self.bars, targetWidth: 480))
        let normalDocument = try #require(PeleSVGDocument(svg: first.svg, dialect: .vega))
        let scaledDocument = try #require(PeleSVGDocument(svg: second.svg, dialect: .vega))
        let normalSize = try #require(Self.descendants(normalDocument.root).first { $0.name == "text" }?.length("font-size"))
        let scaledSize = try #require(Self.descendants(scaledDocument.root).first { $0.name == "text" }?.length("font-size"))
        #expect(scaledSize > normalSize * 1.4)
    }

    private static func descendants(_ element: PeleSVGElement) -> [PeleSVGElement] {
        var elements = [element]
        for case let .element(child) in element.children { elements += descendants(child) }
        return elements
    }

    private static func exampleSources() throws -> [String] {
        // The app and these tests share one canonical Markdown fixture.
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MarkdownExample/MarkdownExample/markdown files/Charts.md")
        let markdown = try String(contentsOf: fixture, encoding: .utf8)
        var sources: [String] = []
        var lines: [String]?
        var prefix = ""
        for line in markdown.components(separatedBy: "\n") {
            if lines != nil {
                let content = line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
                if content.trimmingCharacters(in: .whitespaces) == "```" {
                    sources.append(lines!.joined(separator: "\n"))
                    lines = nil
                } else { lines!.append(content) }
            } else if let opening = line.range(of: "```vega-lite"),
                      line[opening.lowerBound...].trimmingCharacters(in: .whitespaces) == "```vega-lite" {
                prefix = String(line[..<opening.lowerBound])
                lines = []
            }
        }
        #expect(lines == nil, "Charts.md must not contain an unterminated chart fence")
        return sources
    }

    @Test func invalidTargetWidthFailsWithoutRendering() async {
        let provider = VegaLiteChartProvider(theme: .default())
        #expect(await provider.render(source: Self.bars, targetWidth: .infinity) == nil)
        #expect(await provider.render(source: Self.bars, targetWidth: -.infinity) == nil)
        #expect(await provider.render(source: Self.bars, targetWidth: .nan) == nil)
        #expect(await provider.render(source: Self.bars, targetWidth: -1) == nil)
    }
}
#endif
