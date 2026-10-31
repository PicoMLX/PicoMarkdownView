#if os(macOS)
import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import PicoMarkdownView

/// Opt in locally. These elapsed times include actor scheduling and are not FPS,
/// WebKit comparisons, or pass/fail performance thresholds.
@Suite("Published Vega-Lite gallery benchmarks")
struct VegaLiteGalleryBenchmarks {
    @Test("Real gallery chart rendering and complete streamed Markdown pipeline",
          .enabled(if: ProcessInfo.processInfo.environment["PICO_RUN_VEGA_GALLERY_BENCHMARKS"] == "1"))
    func officialGallery() async throws {
        let environment = ProcessInfo.processInfo.environment
        let targetWidth = Int(environment["PICO_VEGA_GALLERY_TARGET_WIDTH"] ?? "480") ?? 480
        try #require((64...2048).contains(targetWidth))
        let providersOnly = environment["PICO_VEGA_GALLERY_PROVIDER_ONLY"] == "1"
        let clock = ContinuousClock()
        let loadStart = clock.now
        let fixture = try BenchmarkGallery.load()
        try #require(fixture.entries.count == fixture.sources.count)
        var report = GalleryBenchmarkReport(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            providerChartTargetWidth: targetWidth,
            galleryEntries: fixture.entries.count, markdownBytes: fixture.markdown.utf8.count,
            fixtureLoadSeconds: seconds(loadStart.duration(to: clock.now)),
            notes: [
                "Cold means a fresh provider cache; VegaLiteRuntime.shared is reused. The first call may include runtime initialization.",
                "Provider timings include policy checks, compiler/runtime SVG generation and the runtime's SVG validation.",
                "SVG parse and native draw timings are additional isolated operations on successful chart results.",
                "Direct provider timings request width \(targetWidth); pipeline timings use the default theme with no runtime width constraint.",
                "Pipeline timings include tokenizer, assembler and renderer; they exclude TextKit layout, on-screen presentation and animation.",
                "Fallback timings and successful chart timings are reported separately. No timing assertions are made."
            ])
        print("Vega-Lite gallery fixture loaded: \(report.markdownBytes) bytes, process lifetime peak RSS \(peakResidentBytes()) bytes")

        var seen: Set<String> = []
        for index in fixture.entries.indices {
            let entry = fixture.entries[index]
            guard seen.insert(entry.id).inserted else { continue }
            let source = fixture.source(at: index)
            let accepted = VegaLiteSpecPolicy.accepts(source)
            let provider = VegaLiteChartProvider(theme: .default())
            let start = clock.now
            let result = await provider.render(source: source, targetWidth: CGFloat(targetWidth))
            let elapsed = seconds(start.duration(to: clock.now))
            var sample = GalleryRenderSample(id: entry.id, categories: entry.category,
                                             sourceBytes: source.utf8.count, dataIssues: entry.dataIssues)
            if let result {
                sample.outcome = "chart"
                sample.providerCacheColdSeconds = elapsed
                sample.svgBytes = result.svg.utf8.count
                for _ in 0..<5 {
                    let warmStart = clock.now
                    let warm = await provider.render(source: source, targetWidth: CGFloat(targetWidth))
                    sample.providerCacheWarmSeconds.append(seconds(warmStart.duration(to: clock.now)))
                    #expect(warm == result, "\(entry.id) warm cache must preserve its chart")
                }
                let parseStart = clock.now
                let document = try #require(PeleSVGDocument(svg: result.svg, dialect: .vega), "\(entry.id)")
                sample.svgParseSeconds = seconds(parseStart.duration(to: clock.now))
                sample.dataMarkCount = dataMarks(in: document.root)
                let drawStart = clock.now
                let image = try nativeDrawing(document)
                sample.nativeDrawSeconds = seconds(drawStart.duration(to: clock.now))
                #expect(image.width > 0 && image.height > 0)
            } else {
                sample.outcome = source.utf8.count > VegaLiteSpecPolicy.maxSourceBytes ? "source-size-fallback" :
                    accepted ? "runtime-or-svg-fallback" : "policy-fallback"
                sample.fallbackCheckSeconds = elapsed
            }
            report.samples.append(sample)
            print("Vega-Lite gallery \(report.samples.count): \(entry.id) \(sample.outcome) source=\(sample.sourceBytes) bytes")
        }
        report.uniqueSpecs = report.samples.count
        report.providerSummary = summarize(report.samples)
        report.peakResidentBytesAfterProviders = peakResidentBytes()
        report.completedPhase = providersOnly ? "providers-only" : "providers"
        if providersOnly {
            report.notes.append("Provider-only mode requested; no complete-document Markdown pipeline was run.")
            report.processLifetimePeakResidentBytes = peakResidentBytes()
        }
        try saveCheckpoint(report)
        print("Vega-Lite provider outcome summary: " + String(decoding: try JSONEncoder().encode(report.providerSummary), as: UTF8.self))

        if providersOnly { return }

        // The complete document is fed twice: once in one call, once in UTF-8
        // chunks no larger than 8 KiB. Chunks are created only as consumed.
        print("Vega-Lite gallery beginning whole-document pipeline")
        report.pipelines.append(try await pipeline(fixture, chunkBytes: nil))
        report.completedPhase = "whole-document-pipeline"
        try saveCheckpoint(report)
        print("Vega-Lite gallery beginning 8 KiB streamed pipeline")
        report.pipelines.append(try await pipeline(fixture, chunkBytes: 8_192))
        report.processLifetimePeakResidentBytes = peakResidentBytes()
        report.completedPhase = "streamed-pipeline"

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        print("VEGA_LITE_GALLERY_BENCHMARK_REPORT\n" + String(decoding: data, as: UTF8.self))
        try saveCheckpoint(report)
    }

    private func saveCheckpoint(_ report: GalleryBenchmarkReport) throws {
        guard let path = ProcessInfo.processInfo.environment["PICO_VEGA_GALLERY_BENCHMARK_REPORT"] else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
        print("Saved Vega-Lite gallery benchmark phase \(report.completedPhase) to \(path)")
        fflush(nil)
    }

    private func pipeline(_ fixture: BenchmarkGallery, chunkBytes: Int?) async throws -> GalleryPipelineSample {
        let clock = ContinuousClock()
        let pipeline = MarkdownStreamingPipeline()
        let start = clock.now
        var chunks = 0
        if let chunkBytes {
            let bytes = fixture.markdown.utf8
            var cursor = bytes.startIndex
            var nextProgress = 8_388_608
            var consumedBytes = 0
            while cursor < bytes.endIndex {
                var upper = bytes.index(cursor, offsetBy: chunkBytes, limitedBy: bytes.endIndex) ?? bytes.endIndex
                while String.Index(upper, within: fixture.markdown) == nil { upper = bytes.index(before: upper) }
                let lower = try #require(String.Index(cursor, within: fixture.markdown))
                let end = try #require(String.Index(upper, within: fixture.markdown))
                _ = await pipeline.feed(String(fixture.markdown[lower..<end]))
                chunks += 1
                consumedBytes += bytes.distance(from: cursor, to: upper)
                cursor = upper
                if consumedBytes >= nextProgress {
                    print("Vega-Lite streamed pipeline consumed at least \(nextProgress) bytes; elapsed \(seconds(start.duration(to: clock.now))) seconds; peak RSS \(peakResidentBytes()) bytes")
                    fflush(nil)
                    nextProgress += 8_388_608
                }
            }
        } else {
            _ = await pipeline.feed(fixture.markdown)
            chunks = 1
        }
        _ = await pipeline.finish()
        let blocks = await pipeline.blocksSnapshot()
        let elapsed = seconds(start.duration(to: clock.now))
        let fences = blocks.filter { block in
            if case let .fencedCode(language) = block.kind { return language == "vega-lite" }
            return false
        }
        try #require(fences.count == fixture.entries.count)
        var rendered = 0
        var sourceSizeFallbacks = 0
        var policyFallbacks = 0
        var runtimeFallbacks = 0
        var categories: [String: [String: Int]] = [:]
        for (index, block) in fences.enumerated() {
            let source = fixture.source(at: index)
            #expect(block.snapshot.isClosed)
            #expect(block.snapshot.codeText == source, "\(fixture.entries[index].id)")
            let outcome: String
            if let chart = block.vegaLiteChart {
                rendered += 1
                outcome = "chart"
                #expect(chart.source == source)
            } else {
                #expect(block.codeBlock?.code == source)
                if source.utf8.count > VegaLiteSpecPolicy.maxSourceBytes {
                    sourceSizeFallbacks += 1
                    outcome = "source-size-fallback"
                } else if !VegaLiteSpecPolicy.accepts(source) {
                    policyFallbacks += 1
                    outcome = "policy-fallback"
                } else {
                    runtimeFallbacks += 1
                    outcome = "runtime-or-svg-fallback"
                }
            }
            categories[fixture.entries[index].category.joined(separator: " / "), default: [:]][outcome, default: 0] += 1
        }
        let sample = GalleryPipelineSample(
            mode: chunkBytes == nil ? "whole-document" : "streamed", maxChunkBytes: chunkBytes,
            chunks: chunks, elapsedSeconds: elapsed, charts: rendered,
            sourceSizeFallbacks: sourceSizeFallbacks, policyFallbacks: policyFallbacks,
            runtimeOrSVGFallbacks: runtimeFallbacks, categories: categories,
            processLifetimePeakResidentBytes: peakResidentBytes())
        print("Vega-Lite \(sample.mode) pipeline: \(elapsed) seconds, \(rendered) charts, \(sourceSizeFallbacks + policyFallbacks + runtimeFallbacks) source fallbacks")
        return sample
    }

    private func nativeDrawing(_ document: PeleSVGDocument) throws -> CGImage {
        let width = Int(ceil(document.width))
        let height = Int(ceil(document.height))
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: PeleSVGValue.colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / document.width, y: -CGFloat(height) / document.height)
        document.draw(in: context, strokesAsFills: true)
        return try #require(context.makeImage())
    }

    private func dataMarks(in element: PeleSVGElement) -> Int {
        let own = element.attributes["role"] == "graphics-symbol" &&
            ["path", "rect", "circle", "line", "text"].contains(element.name) &&
            element.attributes["aria-roledescription"] != nil ? 1 : 0
        return own + element.children.reduce(0) { count, node in
            guard case let .element(child) = node else { return count }
            return count + dataMarks(in: child)
        }
    }

    private func summarize(_ samples: [GalleryRenderSample]) -> [String: GalleryOutcomeSummary] {
        Dictionary(grouping: samples, by: \.outcome).mapValues { group in
            let provider = group.compactMap(\.providerCacheColdSeconds)
            let fallback = group.compactMap(\.fallbackCheckSeconds)
            let warm = group.flatMap(\.providerCacheWarmSeconds)
            return GalleryOutcomeSummary(count: group.count,
                                         providerCacheCold: distribution(provider),
                                         providerCacheWarm: distribution(warm),
                                         fallbackCheck: distribution(fallback),
                                         svgParse: distribution(group.compactMap(\.svgParseSeconds)),
                                         nativeDraw: distribution(group.compactMap(\.nativeDrawSeconds)),
                                         zeroDataMarkCharts: group.filter { $0.dataMarkCount == 0 }.count)
        }
    }

    private func distribution(_ values: [Double]) -> GalleryTimingDistribution? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return GalleryTimingDistribution(count: values.count, totalSeconds: values.reduce(0, +),
                                         medianSeconds: sorted[(sorted.count - 1) / 2],
                                         p95Seconds: sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
                                         maxSeconds: sorted[sorted.count - 1])
    }

    private func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    private func peakResidentBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int64(usage.ru_maxrss)
    }
}

private struct GalleryBenchmarkReport: Encodable {
    var operatingSystem: String
    #if DEBUG
    var buildConfiguration = "debug"
    #else
    var buildConfiguration = "release"
    #endif
    var providerChartTargetWidth = 480
    var sourceByteLimit = VegaLiteSpecPolicy.maxSourceBytes
    var galleryEntries: Int
    var markdownBytes: Int
    var fixtureLoadSeconds: Double
    var notes: [String]
    var completedPhase = "fixture-loaded"
    var uniqueSpecs = 0
    var samples: [GalleryRenderSample] = []
    var providerSummary: [String: GalleryOutcomeSummary] = [:]
    var peakResidentBytesAfterProviders: Int64 = 0
    var pipelines: [GalleryPipelineSample] = []
    var processLifetimePeakResidentBytes: Int64 = 0
}

private struct GalleryRenderSample: Encodable {
    var id: String
    var categories: [String]
    var sourceBytes: Int
    var dataIssues: [String]
    var outcome = ""
    var providerCacheColdSeconds: Double?
    var providerCacheWarmSeconds: [Double] = []
    var fallbackCheckSeconds: Double?
    var svgBytes: Int?
    var svgParseSeconds: Double?
    var nativeDrawSeconds: Double?
    var dataMarkCount: Int?
}

private struct GalleryPipelineSample: Encodable {
    var mode: String
    var maxChunkBytes: Int?
    var chunks: Int
    var elapsedSeconds: Double
    var charts: Int
    var sourceSizeFallbacks: Int
    var policyFallbacks: Int
    var runtimeOrSVGFallbacks: Int
    var categories: [String: [String: Int]]
    var processLifetimePeakResidentBytes: Int64
}

private struct GalleryOutcomeSummary: Encodable {
    var count: Int
    var providerCacheCold: GalleryTimingDistribution?
    var providerCacheWarm: GalleryTimingDistribution?
    var fallbackCheck: GalleryTimingDistribution?
    var svgParse: GalleryTimingDistribution?
    var nativeDraw: GalleryTimingDistribution?
    var zeroDataMarkCharts: Int
}

private struct GalleryTimingDistribution: Encodable {
    var count: Int
    var totalSeconds: Double
    var medianSeconds: Double
    var p95Seconds: Double
    var maxSeconds: Double
}

private struct BenchmarkGallery {
    struct Entry: Decodable {
        var id: String
        var category: [String]
        var dataIssues: [String]
    }
    private struct Manifest: Decodable { var entries: [Entry] }
    var entries: [Entry]
    var markdown: String
    var sources: [Range<String.Index>]
    func source(at index: Int) -> String { String(markdown[sources[index]]) }

    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf:
            root.appendingPathComponent("Tests/Fixtures/VegaLiteGallery/manifest.json")))
        let compressed = try Data(contentsOf: root.appendingPathComponent(
            "MarkdownExample/MarkdownExample/markdown files/Charts-Gallery.md.deflate"))
        let data = try (compressed as NSData).decompressed(using: .zlib) as Data
        let markdown = try #require(String(data: data, encoding: .utf8))
        var cursor = markdown.startIndex
        var sources: [Range<String.Index>] = []
        while let opening = markdown.range(of: "```vega-lite\n", range: cursor..<markdown.endIndex) {
            let closing = try #require(markdown.range(of: "\n```\n", range: opening.upperBound..<markdown.endIndex))
            sources.append(opening.upperBound..<markdown.index(after: closing.lowerBound))
            cursor = closing.upperBound
        }
        return Self(entries: manifest.entries, markdown: markdown, sources: sources)
    }
}
#endif
