#if canImport(JavaScriptCore)
import Foundation
import Testing
@testable import PicoMarkdownView

/// Every ```mermaid fence in `Skills/pele-diagrams` must render with the
/// bundled Pele, so the examples a model copies never rot.
@Suite
struct PeleSkillExamplesTests {
    struct Example: CustomTestStringConvertible {
        var file: String
        var line: Int
        var source: String
        var testDescription: String { "\(file):\(line)" }
    }

    private static let skillDirectory: URL = {
        // Tests/PicoMarkdownViewTests/Renderer/<this file> → repository root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Skills/pele-diagrams", isDirectory: true)
    }()

    private static func examples() throws -> [Example] {
        let files = ["SKILL.md", "references/diagram-types.md"]
        var examples: [Example] = []
        for file in files {
            let text = try String(contentsOf: skillDirectory.appendingPathComponent(file), encoding: .utf8)
            var inFence = false
            var start = 0
            var buffer: [String] = []
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                if !inFence, line.trimmingCharacters(in: .whitespaces) == "```mermaid" {
                    inFence = true
                    start = index + 1
                    buffer = []
                } else if inFence, line.trimmingCharacters(in: .whitespaces) == "```" {
                    inFence = false
                    examples.append(Example(file: file, line: start, source: buffer.joined(separator: "\n")))
                } else if inFence {
                    buffer.append(line)
                }
            }
            #expect(!inFence, "\(file): unterminated mermaid fence")
        }
        return examples
    }

    @Test("The skill's examples cover every diagram type in the picker table")
    func examplesCoverEveryType() async throws {
        let renderer = try #require(PeleRenderer.shared)
        let examples = try Self.examples()
        #expect(examples.count >= 30, "expected one example per diagram type, found \(examples.count)")

        var types = Set<String>()
        for example in examples {
            let result = try await renderer.render(example.source, options: PeleRenderOptions(maxWidth: 360))
            types.insert(result.type)
        }
        let expected: Set<String> = [
            "flowchart", "swimlane", "sequence", "class", "state", "er", "architecture", "c4", "gantt",
            "timeline", "gitGraph", "mindmap", "treeView", "ishikawa", "kanban", "pie", "treemap",
            "xychart", "radar", "quadrantChart", "sankey", "venn", "usecase", "packet", "railroad",
            "wardley", "agentflow", "cynefin", "eventmodeling", "requirement", "block", "journey"
        ]
        #expect(expected.subtracting(types).isEmpty, "missing examples for: \(expected.subtracting(types).sorted())")
    }

    @Test("Every example renders and rasterizes", arguments: try examples())
    func exampleRenders(example: Example) async throws {
        let renderer = try #require(PeleRenderer.shared)
        let result = try await renderer.render(example.source, options: PeleRenderOptions(maxWidth: 360))
        #expect(result.width > 0 && result.height > 0)
        // Charts with axes or fixed grids have a built-in width; everything else must fit a phone.
        let fixedWidthTypes: Set<String> = ["gantt", "xychart", "timeline", "cynefin"]
        #expect(result.width <= 360 || fixedWidthTypes.contains(result.type),
                "\(example.testDescription): \(result.type) is \(result.width) pt wide, too wide for a phone")
        let document = try #require(PeleSVGDocument(svg: result.svg))
        #expect(document.makeCGImage(scale: 1) != nil)
    }
}
#endif
