#if os(macOS)
import AppKit
import Foundation
import ImageIO
import Testing
@testable import PicoMarkdownView

@Suite("Bounded incremental JPEG previews", .timeLimit(.minutes(1)))
@MainActor
struct ProgressiveJPEGPreviewDecoderTests {
    @Test("Real progressive JPEG prefixes preserve source geometry and bound decoded snapshots", arguments: [false, true])
    func progressivePixelsAndOrientation(rotated: Bool) async throws {
        let fixture = try (rotated ? ProgressiveImageFixture.rotated : ProgressiveImageFixture.jpeg).get()
        let previews = ProgressivePreviewCollector()
        let decoder = ProgressiveJPEGPreviewDecoder { previews.append($0) }
        defer { decoder.finish() }
        decoder.submit(fixture.data.prefix(fixture.data.count / 2))
        await decoder.waitUntilIdle()
        let preview = try #require(previews.results.first)
        #expect(preview.size == fixture.size)
        let image = try #require(preview.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(max(image.width, image.height) <= ProgressiveJPEGPreviewDecoder.maxPreviewPixelSize)
        #expect(max(image.width, image.height) < Int(max(fixture.size.width, fixture.size.height)))
        #expect(abs(CGFloat(image.width) / CGFloat(image.height) - fixture.size.width / fixture.size.height) < 0.01)
    }

    @Test("PNG and baseline JPEG do not produce progressive previews", arguments: [false, true])
    func otherFormatsRemainFinalOnly(png: Bool) async throws {
        let fixture = try (png ? ProgressiveImageFixture.png : ProgressiveImageFixture.baseline).get()
        let previews = ProgressivePreviewCollector()
        let decoder = ProgressiveJPEGPreviewDecoder { previews.append($0) }
        decoder.submit(fixture.data.prefix(fixture.data.count / 2))
        await decoder.waitUntilIdle()
        decoder.submit(fixture.data)
        await decoder.waitUntilIdle()
        decoder.finish()
        #expect(previews.results.isEmpty)
        #expect(decoder.decodeAttemptCount == (png ? 0 : 1),
                "Non-JPEG bytes skip Image I/O; baseline JPEG retires after reading its metadata")
    }

    @Test("Tiny chunks do not trigger decoding and geometric checkpoints have a finite budget")
    func decodingBudgetAndFinish() async throws {
        let fixture = try ProgressiveImageFixture.jpeg.get()
        let previews = ProgressivePreviewCollector()
        let decoder = ProgressiveJPEGPreviewDecoder { previews.append($0) }
        let threshold = ProgressiveJPEGPreviewDecoder.firstCheckpointByteCount
        for count in stride(from: 1, to: threshold, by: 31) { decoder.submit(fixture.data.prefix(count)) }
        await decoder.waitUntilIdle()
        #expect(decoder.decodeAttemptCount == 0)
        var checkpoint = threshold
        for _ in 0..<12 {
            decoder.submit(fixture.data.prefix(min(checkpoint, fixture.data.count)))
            await decoder.waitUntilIdle()
            checkpoint *= 2
        }
        #expect(decoder.decodeAttemptCount > 0)
        #expect(decoder.decodeAttemptCount <= ProgressiveJPEGPreviewDecoder.maxDecodeAttempts)
        #expect(!previews.results.isEmpty)
        decoder.finish()
        await decoder.waitUntilIdle()
        let attempts = decoder.decodeAttemptCount
        let delivered = previews.results.count
        decoder.submit(fixture.data)
        await decoder.waitUntilIdle()
        #expect(decoder.decodeAttemptCount == attempts)
        #expect(previews.results.count == delivered, "A retired decoder cannot overwrite final content")
    }

    @Test("Finishing a queued decoder discards its pending snapshot before the worker runs")
    func finishDiscardsPendingWork() async throws {
        let fixture = try ProgressiveImageFixture.jpeg.get()
        let entered = ProgressivePreviewCollector()
        let gate = DispatchSemaphore(value: 0)
        let blocker = ProgressiveJPEGPreviewDecoder {
            entered.append($0)
            gate.wait() // Only the decoder's utility worker is gated, never the UI actor.
        }
        defer { gate.signal(); blocker.finish() }
        blocker.submit(fixture.data.prefix(fixture.data.count / 2))
        try await entered.waitForCount(1)
        let previews = ProgressivePreviewCollector()
        let retired = ProgressiveJPEGPreviewDecoder { previews.append($0) }
        retired.submit(fixture.data.prefix(fixture.data.count / 2))
        retired.finish()
        gate.signal()
        await retired.waitUntilIdle()
        #expect(retired.decodeAttemptCount == 0)
        #expect(previews.results.isEmpty, "A pending preview cannot appear after final delivery or cancellation")
    }

    @Test("Advertised dimensions beyond the pixel budget are rejected before thumbnail creation")
    func oversizedPixelMetadata() async throws {
        var data = try ProgressiveImageFixture.jpeg.get().data
        let frame = try #require(data.range(of: Data([0xff, 0xc2])))
        let position = frame.lowerBound
        // SOF2: marker, segment length, precision, height, width. Alter metadata
        // instead of allocating or encoding a sixty-four-million-pixel fixture.
        for offset in [5, 7] {
            data[position + offset] = 0x1f
            data[position + offset + 1] = 0x40 // 8000
        }
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let metadata = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((metadata[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 8000)
        #expect((metadata[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 8000)
        let previews = ProgressivePreviewCollector()
        let decoder = ProgressiveJPEGPreviewDecoder { previews.append($0) }
        decoder.submit(data.prefix(data.count / 2))
        await decoder.waitUntilIdle()
        decoder.finish()
        #expect(decoder.decodeAttemptCount == 1)
        #expect(previews.results.isEmpty)
    }
}
#endif
