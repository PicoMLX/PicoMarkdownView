#if os(macOS)
import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PicoMarkdownView

/// Local, opt-in elapsed-time measurements, with no pass/fail timing limits.
@Suite("Progressive JPEG preview benchmarks", .timeLimit(.minutes(1)))
struct ProgressiveImageBenchmarks {
    @Test("Bounded JPEG decoding alongside the streamed Markdown pipeline",
          .enabled(if: ProcessInfo.processInfo.environment["PICO_RUN_IMAGE_PREVIEW_BENCHMARKS"] == "1"))
    func boundedPreviewsAndPipeline() async throws {
        let jpeg = try makeJPEG()
        let chunks = (0..<48).map { index in
            "## Section \(index)\n\n" + String(repeating:
                "Streaming **Markdown** preserves [links](https://example.com), `inline code`, and ordinary paragraph text.\n\n",
                count: 16) + "- First item\n- Second item\n\n"
        }
        let isolated = await [measureDecoding(jpeg, instances: 1), measureDecoding(jpeg, instances: 4)]
        for sample in isolated {
            #expect(sample.previewCount > 0)
            #expect(sample.attemptsPerDecoder.allSatisfy { $0 <= ProgressiveJPEGPreviewDecoder.maxDecodeAttempts })
            #expect(sample.maxSnapshotWidth <= ProgressiveJPEGPreviewDecoder.maxPreviewPixelSize)
            #expect(sample.maxSnapshotHeight <= ProgressiveJPEGPreviewDecoder.maxPreviewPixelSize)
        }

        // Exclude one warm-up per configuration. Reverse ordering on alternate
        // measured rounds so baseline is not always the first or last run.
        for instances in [0, 1, 4] {
            _ = await measurePipeline(chunks, jpeg: jpeg, instances: instances, round: -1, position: 0)
        }
        var samples: [PipelineMeasurement] = []
        for round in 0..<4 {
            let order = round.isMultiple(of: 2) ? [0, 1, 4] : [4, 1, 0]
            for (position, instances) in order.enumerated() {
                samples.append(await measurePipeline(chunks, jpeg: jpeg, instances: instances,
                                                     round: round, position: position))
            }
        }
        let summaries = [0, 1, 4].map { instances in
            PipelineSummary(decoderInstances: instances,
                feedMilliseconds: Distribution(samples.filter { $0.decoderInstances == instances }.flatMap(\.feedMilliseconds)))
        }
        let report = Report(
            date: ISO8601DateFormatter().string(from: Date()),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount,
            configuration: _isDebugAssertConfiguration() ? "debug" : "release",
            jpegBytes: jpeg.count, sourceWidth: 1536, sourceHeight: 768,
            markdownBytes: chunks.reduce(0) { $0 + $1.utf8.count },
            chunkBytes: chunks.map { $0.utf8.count },
            isolatedDecoding: isolated, pipelineSamples: samples, pipelineSummaries: summaries,
            notes: [
                "Generated progressive JPEG; no network, disk image loading, final-image decode, or image cache is measured.",
                "Each decoder receives eight geometric full-prefix checkpoints from 4 KiB through 512 KiB; snapshots are at most 1024 pixels per side.",
                "One and four concurrent decoder instances share the production serial utility queue; this does not mean four parallel Image I/O workers.",
                "Isolated decoding elapsed time includes submission, queue scheduling, partial thumbnail decoding, and the lightweight preview callback.",
                "Every pipeline run feeds the same finite chunks into a fresh default MarkdownStreamingPipeline, then finishes it. One warm-up per configuration is excluded.",
                "Pipeline feed latency includes tokenizer, assembler, renderer, and actor scheduling. It excludes TextKit, SwiftUI, canvas drawing, and on-screen FPS.",
                "Concurrent checkpoints are submitted before every sixth chunk. Feeds with decode-attempt starts record observed overlap; decoder workload span also includes time between checkpoints.",
                "Four measured rounds alternate baseline-first and baseline-last ordering. Measurements describe this machine/run; there are no elapsed-time assertions."
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let path = ProcessInfo.processInfo.environment["PICO_IMAGE_PREVIEW_BENCHMARK_REPORT"]
            ?? "/private/tmp/pico-progressive-image-benchmark.json"
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        print("PROGRESSIVE_IMAGE_BENCHMARK_REPORT\n" + String(decoding: data, as: UTF8.self))
        print("Saved progressive image benchmark to \(path)")
    }

    private func measureDecoding(_ jpeg: Data, instances: Int) async -> DecoderMeasurement {
        let previews = PreviewMeasurements()
        let decoders = (0..<instances).map { _ in ProgressiveJPEGPreviewDecoder { previews.record($0) } }
        let start = ContinuousClock.now
        for checkpoint in checkpoints(jpeg) {
            for decoder in decoders { decoder.submit(checkpoint) }
            for decoder in decoders { await decoder.waitUntilIdle() }
        }
        let elapsed = milliseconds(start.duration(to: .now))
        let sample = previews.measurement(instances: instances, elapsed: elapsed,
                                         attempts: decoders.map(\.decodeAttemptCount))
        for decoder in decoders { decoder.finish() }
        return sample
    }

    private func measurePipeline(_ chunks: [String], jpeg: Data, instances: Int,
                                 round: Int, position: Int) async -> PipelineMeasurement {
        let pipeline = MarkdownStreamingPipeline()
        let previews = PreviewMeasurements()
        let decoders = (0..<instances).map { _ in ProgressiveJPEGPreviewDecoder { previews.record($0) } }
        let prefixes = checkpoints(jpeg)
        var latencies: [Double] = []
        var feedsWithDecodeAttemptStarts = 0
        var updateCount = 0
        let start = ContinuousClock.now
        for (index, chunk) in chunks.enumerated() {
            if index.isMultiple(of: 6) {
                for decoder in decoders { decoder.submit(prefixes[index / 6]) }
            }
            let before = decoders.reduce(0) { $0 + $1.decodeAttemptCount }
            let feedStart = ContinuousClock.now
            if await pipeline.feed(chunk) != nil { updateCount += 1 }
            latencies.append(milliseconds(feedStart.duration(to: .now)))
            if decoders.reduce(0, { $0 + $1.decodeAttemptCount }) > before { feedsWithDecodeAttemptStarts += 1 }
        }
        let finishStart = ContinuousClock.now
        _ = await pipeline.finish()
        let finishMilliseconds = milliseconds(finishStart.duration(to: .now))
        let pipelineMilliseconds = milliseconds(start.duration(to: .now))
        let finalBlockCount = await pipeline.blocksSnapshot().count
        for decoder in decoders { await decoder.waitUntilIdle() }
        let decoding = instances == 0 ? nil : previews.measurement(instances: instances,
            elapsed: milliseconds(start.duration(to: .now)), attempts: decoders.map(\.decodeAttemptCount))
        for decoder in decoders { decoder.finish() }
        return PipelineMeasurement(round: round, position: position, decoderInstances: instances,
            pipelineMilliseconds: pipelineMilliseconds, finishMilliseconds: finishMilliseconds,
            feedMilliseconds: latencies, feedDistribution: Distribution(latencies),
            feedsWithDecodeAttemptStarts: feedsWithDecodeAttemptStarts,
            updates: updateCount, finalBlocks: finalBlockCount, decoding: decoding)
    }

    private func checkpoints(_ jpeg: Data) -> [Data] {
        (0..<ProgressiveJPEGPreviewDecoder.maxDecodeAttempts).map { index in
            jpeg.prefix(min(jpeg.count, ProgressiveJPEGPreviewDecoder.firstCheckpointByteCount << index))
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private func makeJPEG() throws -> Data {
        let width = 1536, height = 768
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 37 + y * 13) % 256)
                pixels[offset + 1] = UInt8((x * 11 + y * 29) % 256)
                pixels[offset + 2] = UInt8((x ^ y) % 256)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.75,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        let jpeg = data as Data
        try #require(jpeg.range(of: Data([0xff, 0xc2])) != nil)
        try #require(jpeg.count > ProgressiveJPEGPreviewDecoder.firstCheckpointByteCount << 7)
        return jpeg
    }
}

private final class PreviewMeasurements: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var maxWidth = 0
    private var maxHeight = 0

    func record(_ result: MarkdownImageResult) {
        lock.withLock {
            count += 1
            for representation in result.image.representations {
                maxWidth = max(maxWidth, representation.pixelsWide)
                maxHeight = max(maxHeight, representation.pixelsHigh)
            }
        }
    }

    func measurement(instances: Int, elapsed: Double, attempts: [Int]) -> DecoderMeasurement {
        lock.withLock {
            DecoderMeasurement(instances: instances, elapsedMilliseconds: elapsed,
                attemptsPerDecoder: attempts, previewCount: count,
                maxSnapshotWidth: maxWidth, maxSnapshotHeight: maxHeight)
        }
    }
}

private struct DecoderMeasurement: Codable {
    let instances: Int
    let elapsedMilliseconds: Double
    let attemptsPerDecoder: [Int]
    let previewCount: Int
    let maxSnapshotWidth: Int
    let maxSnapshotHeight: Int
}

private struct PipelineMeasurement: Codable {
    let round: Int
    let position: Int
    let decoderInstances: Int
    let pipelineMilliseconds: Double
    let finishMilliseconds: Double
    let feedMilliseconds: [Double]
    let feedDistribution: Distribution
    let feedsWithDecodeAttemptStarts: Int
    let updates: Int
    let finalBlocks: Int
    let decoding: DecoderMeasurement?
}

private struct Distribution: Codable {
    let count: Int
    let total: Double
    let median: Double
    let p95: Double
    let p99: Double
    let maximum: Double

    init(_ samples: [Double]) {
        let ordered = samples.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !ordered.isEmpty else { return 0 }
            return ordered[Int((Double(ordered.count - 1) * fraction).rounded(.up))]
        }
        count = samples.count
        total = samples.reduce(0, +)
        median = percentile(0.5)
        p95 = percentile(0.95)
        p99 = percentile(0.99)
        maximum = ordered.last ?? 0
    }
}

private struct PipelineSummary: Codable {
    let decoderInstances: Int
    let feedMilliseconds: Distribution
}

private struct Report: Codable {
    let date: String
    let operatingSystem: String
    let processorCount: Int
    let configuration: String
    let jpegBytes: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let markdownBytes: Int
    let chunkBytes: [Int]
    let isolatedDecoding: [DecoderMeasurement]
    let pipelineSamples: [PipelineMeasurement]
    let pipelineSummaries: [PipelineSummary]
    let notes: [String]
}
#endif
