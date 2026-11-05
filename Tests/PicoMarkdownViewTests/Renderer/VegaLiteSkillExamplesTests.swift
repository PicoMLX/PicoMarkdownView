#if os(macOS)
import Foundation
import PicoMarkdownSkills
import Testing
@testable import PicoMarkdownView

@Suite("Vega-Lite skill examples")
struct VegaLiteSkillExamplesTests {
    struct Example: Sendable, CustomTestStringConvertible {
        var line: Int
        var source: String
        var testDescription: String { "vega-lite-charts/SKILL.md:\(line)" }
    }

    private static func examples() throws -> [Example] {
        let file = PicoMarkdownSkills.directoryURL
            .appendingPathComponent("vega-lite-charts/SKILL.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        var examples: [Example] = []
        var openingLine: Int?
        var source: [String] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if openingLine == nil, line == "```vega-lite" {
                openingLine = index + 1
                source = []
            } else if let start = openingLine, line == "```" {
                examples.append(Example(line: start, source: source.joined(separator: "\n")))
                openingLine = nil
            } else if openingLine != nil {
                source.append(line)
            }
        }
        try #require(openingLine == nil, "The canonical skill has an unfinished Vega-Lite fence")
        return examples
    }

    @Test("The canonical skill covers count bars, a temporal line and calculated scatter points")
    func examplesCoverNumericalForms() throws {
        let examples = try Self.examples()
        var marks = Set<String>()
        for example in examples {
            let spec = try #require(try JSONSerialization.jsonObject(with: Data(example.source.utf8)) as? [String: Any])
            let mark = (spec["mark"] as? String) ?? (spec["mark"] as? [String: Any])?["type"] as? String
            marks.insert(try #require(mark))
        }
        #expect(marks == ["bar", "line", "point"])
    }

    @Test("Every canonical fence creates real data marks and drawable native SVG",
          arguments: try examples(), [280, 672])
    func exampleRenders(example: Example, width: Int) async throws {
        #expect(VegaLiteSpecPolicy.accepts(example.source))
        let provider = VegaLiteChartProvider(theme: .default())
        let result = try #require(await provider.render(source: example.source, targetWidth: CGFloat(width)))
        #expect(result.intrinsicSize.width.isFinite && result.intrinsicSize.width > 0)
        #expect(result.intrinsicSize.height.isFinite && result.intrinsicSize.height > 0)
        #expect(!result.svg.contains("NaN"))
        #expect(!result.svg.contains("Infinity"))
        let document = try #require(PeleSVGDocument(svg: result.svg, dialect: .vega))
        let marks = Self.descendants(document.root).filter {
            $0.name == "path" && $0.attributes["role"] == "graphics-symbol" &&
                ["bar", "point", "line mark"].contains($0.attributes["aria-roledescription"] ?? "") &&
                !($0.attributes["d"] ?? "").isEmpty
        }
        #expect(marks.count >= 3, "A chart must contain data marks, not only axes")
        if example.source.contains("itemsPerSecond") {
            let points = marks.filter { $0.attributes["aria-roledescription"] == "point" }
            #expect(points.count == 4, "The zero-duration row must be filtered out")
            let labels = points.compactMap { $0.attributes["aria-label"] }
            for throughput in [125, 200, 250, 400] {
                #expect(labels.contains { $0.contains(String(throughput)) },
                        "Calculated throughput \(throughput) must be represented in the data marks")
            }
        }
        let bitmap = try #require(document.makeCGImage(scale: 1))
        #expect(bitmap.width > 0 && bitmap.height > 0)
    }

    private static func descendants(_ element: PeleSVGElement) -> [PeleSVGElement] {
        [element] + element.children.flatMap { node -> [PeleSVGElement] in
            if case let .element(child) = node { return descendants(child) }
            return []
        }
    }
}
#endif
