#if canImport(JavaScriptCore)
import CoreGraphics
import Foundation
import Testing
@testable import PicoMarkdownView

/// Exercises the exact published examples shown in the example app. This is
/// sample coverage, not a claim that every Mermaid option has a visual oracle.
@Suite("Published Pele demo coverage")
struct PeleDemoExamplesTests {
    struct Example: Sendable, CustomTestStringConvertible {
        var section: String
        var number: Int
        var line: Int
        var source: String
        var testDescription: String { "\(section) #\(number), Diagrams.md:\(line)" }
    }

    private static let expectedTypes: [String: String] = [
        "Block": "block", "C4": "c4", "Class": "class", "Entity relationship": "er",
        "Event modeling": "eventmodeling", "Flowchart": "flowchart", "Gantt": "gantt",
        "Git graph": "gitGraph", "Kanban": "kanban", "Mindmap": "mindmap", "Packet": "packet",
        "Pie": "pie", "Quadrant chart": "quadrantChart", "Requirement": "requirement",
        "Sankey": "sankey", "Sequence": "sequence", "State": "state", "Timeline": "timeline",
        "User journey": "journey", "XY chart": "xychart", "Agentflow": "agentflow",
        "Architecture": "architecture", "Cynefin": "cynefin", "Ishikawa": "ishikawa",
        "Radar": "radar", "Railroad": "railroad", "Swimlane": "swimlane", "Tree view": "treeView",
        "Treemap": "treemap", "Use case": "usecase", "Venn": "venn", "Wardley map": "wardley"
    ]

    private static func examples() throws -> [Example] {
        // Keep one canonical source for the app and its regression coverage.
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MarkdownExample/MarkdownExample/markdown files/Diagrams.md")
        let markdown = try String(contentsOf: fixture, encoding: .utf8)
        var examples: [Example] = []
        var section = ""
        var sectionNumber = 0
        var source: [String] = []
        var start: Int?
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
            if let firstLine = start {
                if line.trimmingCharacters(in: .whitespaces) == "```" {
                    sectionNumber += 1
                    examples.append(Example(section: section, number: sectionNumber,
                                            line: firstLine, source: source.joined(separator: "\n")))
                    start = nil
                } else {
                    source.append(line)
                }
            } else if line.hasPrefix("## ") {
                section = String(line.dropFirst(3))
                sectionNumber = 0
            } else if line.trimmingCharacters(in: .whitespaces) == "```mermaid" {
                start = index + 1
                source = []
            }
        }
        #expect(start == nil, "The published demo must not contain an unterminated Mermaid fence")
        return examples
    }

    @Test("The demo retains all 58 published examples across 32 diagram families")
    func publishedInventory() throws {
        let examples = try Self.examples()
        #expect(examples.count == 58)
        #expect(Self.expectedTypes.count == 32)
        #expect(Set(examples.map(\.section)) == Set(Self.expectedTypes.keys))
        #expect(examples.allSatisfy { !$0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    @Test("Each published example renders through bundled Pele and native SVG", arguments: try examples())
    func publishedExampleRenders(example: Example) async throws {
        let renderer = try #require(PeleRenderer.shared)
        let expectedType = try #require(Self.expectedTypes[example.section])
        let result = try await renderer.render(example.source, options: PeleRenderOptions(maxWidth: 360))
        #expect(result.type == expectedType)
        #expect(result.width.isFinite && result.height.isFinite)
        #expect(result.width > 0 && result.height > 0)
        let document = try #require(PeleSVGDocument(svg: result.svg))
        let bitmap = try #require(document.makeCGImage(scale: 1))
        #expect(try paintedPixelCount(in: bitmap) > 100, "The native bitmap must contain diagram content")
        #if os(macOS)
        // Exercise the production hosted canvas's stroke-outline mode too.
        let width = Int(ceil(document.width))
        let height = Int(ceil(document.height))
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: PeleSVGValue.colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / document.width, y: -CGFloat(height) / document.height)
        document.draw(in: context, strokesAsFills: true)
        let vectorDrawing = try #require(context.makeImage())
        #expect(try paintedPixelCount(in: vectorDrawing) > 100, "The native vector path must contain diagram content")
        #endif
    }

    private func paintedPixelCount(in image: CGImage) throws -> Int {
        let data = try #require(image.dataProvider?.data as Data?)
        var count = 0
        for row in 0..<image.height {
            let start = row * image.bytesPerRow
            for column in stride(from: 3, to: image.width * 4, by: 4) {
                if data[start + column] > 0 { count += 1 }
            }
        }
        return count
    }
}
#endif
