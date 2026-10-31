#if os(macOS)
import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import PicoMarkdownView

/// Exercises the exported specifications verbatim. Unsupported examples stay
/// source code; the complete gallery is not a compatibility claim.
@Suite("Published Vega-Lite gallery")
struct VegaLiteGalleryTests {
    private static let fixture = Result { try GalleryFixture.load() }

    @Test("Every official gallery fence matches its manifest and is classified before JavaScript")
    func completeInventoryAndPreflight() throws {
        let fixture = try Self.fixture.get()
        #expect(fixture.entries.count == 203)
        #expect(Set(fixture.entries.map(\.id)).count == 189)
        try #require(fixture.sources.count == fixture.entries.count)
        var accepted = 0
        var oversized = 0
        var otherRejected = 0
        var categories: [String: [String: Int]] = [:]
        for index in fixture.entries.indices {
            let entry = fixture.entries[index]
            let source = fixture.source(at: index)
            let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == entry.sourceSHA256, "\(entry.id) occurrence \(entry.occurrence)")
            let supported = VegaLiteSpecPolicy.accepts(source)
            if supported { accepted += 1 }
            else if source.utf8.count > VegaLiteSpecPolicy.maxSourceBytes { oversized += 1 }
            else { otherRejected += 1 }
            categories[entry.category.joined(separator: " / "), default: [:]][supported ? "preflightAccepted" : "preflightRejected", default: 0] += 1
        }
        #expect(accepted > 0)
        #expect(oversized + otherRejected > 0)
        let report: [String: Any] = [
            "kind": "vega-lite-gallery-preflight", "entries": fixture.entries.count,
            "uniqueSpecs": Set(fixture.entries.map(\.id)).count,
            "preflightAccepted": accepted, "sourceSizeRejected": oversized,
            "otherPolicyRejected": otherRejected, "categories": categories,
            "note": "Preflight acceptance is not a successful-render or visual-fidelity result."
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }

    @Test("Rendering preview retains every gallery entry and only exact successful chart fences")
    func renderingPreviewRetainsInventoryAndExactSources() throws {
        let fixture = try Self.fixture.get()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let preview = try JSONDecoder().decode(GalleryPreviewManifest.self, from: Data(contentsOf:
            root.appendingPathComponent("Tests/Fixtures/VegaLiteGallery/preview-manifest.json")))
        let compressed = try Data(contentsOf: root.appendingPathComponent(
            "MarkdownExample/MarkdownExample/markdown files/Charts-Gallery-Preview.md.deflate"))
        let data = try (compressed as NSData).decompressed(using: .zlib) as Data
        let markdown = try #require(String(data: data, encoding: .utf8))
        let sources = try GalleryFixture.fenceRanges(in: markdown)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let fullDigest = SHA256.hash(data: Data(fixture.markdown.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(preview.kind == "rendering-preview")
        #expect(preview.entryCount == 203)
        #expect(preview.chartCount == 128)
        #expect(preview.noticeCount == 75)
        #expect(preview.markdown.decodedBytes == data.count)
        #expect(preview.markdown.decodedSHA256 == digest)
        #expect(preview.sourceMarkdownSHA256 == fullDigest)
        try #require(preview.entries.count == fixture.entries.count)
        #expect(sources.count == preview.chartCount)
        #expect(markdown.components(separatedBy: "Not rendered by current static profile:").count - 1 == preview.noticeCount)
        let lines = markdown.components(separatedBy: "\n")
        let expectedHeadings = fixture.markdown.split(separator: "\n").filter { $0.hasPrefix("##") }.map(String.init)
        #expect(lines.filter { $0.hasPrefix("##") } == expectedHeadings)
        let links = lines.filter { $0.hasPrefix("[Official example](") }
        try #require(links.count == fixture.entries.count)
        var kept = 0
        var notices = 0
        for (index, entry) in preview.entries.enumerated() {
            let original = fixture.entries[index]
            #expect(entry.fullEntryIndex == index)
            #expect(entry.id == original.id)
            #expect(entry.title == original.title)
            #expect(entry.category == original.category)
            #expect(entry.occurrence == original.occurrence)
            #expect(entry.sourceSHA256 == original.sourceSHA256)
            #expect(entry.sourceURL == original.sourceURL)
            #expect(links[index].contains("](\(original.sourceURL))"))
            if entry.disposition == "chart" {
                let fenceIndex = try #require(entry.fenceIndex)
                try #require(sources.indices.contains(fenceIndex))
                #expect(entry.outcome == "chart")
                #expect(fenceIndex == kept)
                let source = String(markdown[sources[fenceIndex]])
                #expect(source == fixture.source(at: index), "\(entry.id) occurrence \(entry.occurrence)")
                let sourceDigest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
                #expect(sourceDigest == original.sourceSHA256)
                kept += 1
            } else {
                #expect(entry.disposition == "notice")
                #expect(entry.fenceIndex == nil)
                #expect(["source-size-fallback", "policy-fallback", "runtime-or-svg-fallback"].contains(entry.outcome))
                notices += 1
            }
        }
        #expect(kept == preview.chartCount)
        #expect(notices == preview.noticeCount)
    }


    @Test("User-reported missing official charts retain their real data marks", arguments: [
        "bar_aggregate", "bar_aggregate_sort_by_encoding", "bar_grouped_repeated",
        "stacked_bar_weather", "stacked_bar_count_corner_radius_mark", "stacked_bar_normalize",
        "stacked_bar_h_normalized_labeled", "bar_layered_transparent",
        "bar_diverging_stack_population_pyramid", "bar_diverging_stack_transform"
    ], [336, 480])
    func userReportedOfficialChartsRender(id: String, width: Int) async throws {
        let expectedMarks = [
            "bar_aggregate": 19, "bar_aggregate_sort_by_encoding": 19,
            "bar_grouped_repeated": 26, "stacked_bar_weather": 54,
            "stacked_bar_count_corner_radius_mark": 54, "stacked_bar_normalize": 38,
            "stacked_bar_h_normalized_labeled": 76, "bar_layered_transparent": 38,
            "bar_diverging_stack_population_pyramid": 38, "bar_diverging_stack_transform": 40
        ]
        let fixture = try Self.fixture.get()
        let index = try #require(fixture.entries.firstIndex { $0.id == id })
        let source = fixture.source(at: index)
        #expect(VegaLiteSpecPolicy.accepts(source), "\(id) at \(width) points")
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.updateMermaidContentWidth(CGFloat(width))
        _ = await pipeline.feed("```vega-lite\n" + source + "```\n\n")
        _ = await pipeline.finish()
        let blocks = await pipeline.blocksSnapshot()
        let block = try #require(blocks.first { $0.vegaLiteChart != nil }, "\(id) at \(width) points")
        let chart = try #require(block.vegaLiteChart)
        #expect(blocks.count == 1)
        #expect(block.snapshot.isClosed)
        #expect(block.snapshot.codeText == source)
        #expect(chart.source == source)
        #expect(!chart.svg.contains("NaN"))
        #expect(!chart.svg.contains("Infinity"))
        let document = try #require(PeleSVGDocument(svg: chart.svg, dialect: .vega))
        #expect(Self.dataMarks(in: document.root) == expectedMarks[id], "\(id) must retain its complete grouped or stacked data")
        let bitmap = try #require(document.makeCGImage(scale: 1))
        #expect(Self.paintedPixels(in: bitmap) > 100)
    }

    @Test("Bounded official examples produce real native marks and preserve exact fence source")
    func representativeNativeChartsAndFallback() async throws {
        let fixture = try Self.fixture.get()
        for id in ["bar", "bar_gantt", "arc_pie"] {
            let index = try #require(fixture.entries.firstIndex { $0.id == id })
            let source = fixture.source(at: index)
            #expect(VegaLiteSpecPolicy.accepts(source), "\(id)")
            let pipeline = MarkdownStreamingPipeline()
            _ = await pipeline.feed("Before the official chart.\n\n```vega-lite\n" + source)
            let loading = try #require(await pipeline.blocksSnapshot().compactMap(\.vegaLiteChart).first)
            #expect(loading.svg.isEmpty, "An open official fence must not compile a chart")
            #expect(loading.source == source)
            _ = await pipeline.feed("```\n\nAfter the official chart.\n\n")
            _ = await pipeline.finish()
            let blocks = await pipeline.blocksSnapshot()
            let block = try #require(blocks.first { $0.vegaLiteChart != nil }, "\(id)")
            let chart = try #require(block.vegaLiteChart)
            #expect(chart.source == source)
            #expect(block.snapshot.codeText == source)
            #expect(block.snapshot.isClosed)
            let document = try #require(PeleSVGDocument(svg: chart.svg, dialect: .vega), "\(id)")
            #expect(Self.dataMarks(in: document.root) >= 3, "\(id) must contain data marks, not only axes")
            let bitmap = try #require(document.makeCGImage(scale: 1))
            #expect(Self.paintedPixels(in: bitmap) > 100)
        }

        let fallbackIndex = try #require(fixture.entries.firstIndex { $0.id == "scatter_image" })
        let source = fixture.source(at: fallbackIndex)
        #expect(!VegaLiteSpecPolicy.accepts(source))
        let pipeline = MarkdownStreamingPipeline()
        let markdown = "```vega-lite\n" + source + "```\n\n"
        var start = markdown.startIndex
        while start < markdown.endIndex {
            let end = markdown.index(start, offsetBy: 37, limitedBy: markdown.endIndex) ?? markdown.endIndex
            _ = await pipeline.feed(String(markdown[start..<end]))
            start = end
        }
        _ = await pipeline.finish()
        let blocks = await pipeline.blocksSnapshot()
        let block = try #require(blocks.first)
        #expect(blocks.count == 1)
        #expect(block.vegaLiteChart == nil)
        #expect(block.snapshot.isClosed)
        #expect(block.snapshot.codeText == source)
        #expect(block.codeBlock?.code == source)
    }

    private static func dataMarks(in element: PeleSVGElement) -> Int {
        let own = element.attributes["role"] == "graphics-symbol" &&
            ["path", "rect", "circle", "line", "text"].contains(element.name) &&
            element.attributes["aria-roledescription"] != nil ? 1 : 0
        return own + element.children.reduce(0) { count, node in
            guard case let .element(child) = node else { return count }
            return count + dataMarks(in: child)
        }
    }

    private static func paintedPixels(in image: CGImage) -> Int {
        guard let bytes = image.dataProvider?.data as Data? else { return 0 }
        var count = 0
        for row in 0..<image.height {
            for column in stride(from: 3, to: image.width * 4, by: 4) {
                if bytes[row * image.bytesPerRow + column] > 0 { count += 1 }
            }
        }
        return count
    }
}

private struct GalleryFixture: Sendable {
    struct Entry: Decodable, Sendable {
        var id: String
        var title: String
        var category: [String]
        var occurrence: Int
        var sourceSHA256: String
        var sourceURL: String
    }
    private struct Manifest: Decodable { var entries: [Entry] }
    var entries: [Entry]
    var markdown: String
    var sources: [Range<String.Index>]

    func source(at index: Int) -> String { String(markdown[sources[index]]) }

    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf:
            root.appendingPathComponent("Tests/Fixtures/VegaLiteGallery/manifest.json")))
        let compressed = try Data(contentsOf: root.appendingPathComponent(
            "MarkdownExample/MarkdownExample/markdown files/Charts-Gallery.md.deflate"))
        let data = try (compressed as NSData).decompressed(using: .zlib) as Data
        let markdown = try #require(String(data: data, encoding: .utf8))
        return Self(entries: manifest.entries, markdown: markdown, sources: try fenceRanges(in: markdown))
    }

    static func fenceRanges(in markdown: String) throws -> [Range<String.Index>] {
        var cursor = markdown.startIndex
        var sources: [Range<String.Index>] = []
        while let opening = markdown.range(of: "```vega-lite\n", range: cursor..<markdown.endIndex) {
            let closing = try #require(markdown.range(of: "\n```\n", range: opening.upperBound..<markdown.endIndex),
                                       "Every gallery chart must have a complete fence")
            sources.append(opening.upperBound..<markdown.index(after: closing.lowerBound))
            cursor = closing.upperBound
        }
        return sources
    }
}
private struct GalleryPreviewManifest: Decodable {
    struct Markdown: Decodable {
        var decodedBytes: Int
        var decodedSHA256: String
    }
    struct Entry: Decodable {
        var id: String
        var title: String
        var category: [String]
        var occurrence: Int
        var sourceSHA256: String
        var sourceURL: String
        var disposition: String
        var outcome: String
        var fullEntryIndex: Int
        var fenceIndex: Int?
    }
    var kind: String
    var entryCount: Int
    var chartCount: Int
    var noticeCount: Int
    var markdown: Markdown
    var sourceMarkdownSHA256: String
    var entries: [Entry]
}

#endif
