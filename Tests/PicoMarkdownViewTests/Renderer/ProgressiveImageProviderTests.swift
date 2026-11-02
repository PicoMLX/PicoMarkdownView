#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import PicoMarkdownView

@Suite("Progressive image downloads", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ProgressiveImageProviderTests {
    @Test("A gated real JPEG produces a bounded preview before completion and caches only the final image")
    func previewBeforeFinalAndExactCache() async throws {
        let fixture = try ProgressiveImageFixture.jpeg.get()
        let transfer = ControlledProgressiveImageTransfer(fixture: fixture)
        defer { transfer.unregister() }
        let session = progressiveImageSession()
        defer { session.invalidateAndCancel() }
        let provider = URLSessionMarkdownImageProvider(session: session, progressiveJPEGPreviews: true)
        #expect(provider.progressiveJPEGPreviewsEnabled)
        let previews = ProgressivePreviewCollector()
        let completion = ProgressiveCompletionFlag()
        let download = Task {
            let result = await provider.prefetch(transfer.url) { previews.append($0) }
            completion.finish()
            return result
        }
        defer { download.cancel() }
        try await transfer.waitForStart()
        let split = fixture.data.count / 2
        await transfer.send(fixture.data.prefix(split))
        try await previews.waitForCount(1)
        let preview = try #require(previews.results.first)
        #expect(!transfer.hasCompleted && !completion.value, "The final network response is still gated")
        #expect(await provider.image(for: transfer.url) == nil, "A preview must not enter the final cache")
        #expect(preview.size == fixture.size)
        #expect(max(preview.image.size.width, preview.image.size.height) <= 1024)

        await transfer.send(fixture.data.suffix(from: split))
        await transfer.finish()
        let final = try #require(await download.value)
        let cached = try #require(await provider.image(for: transfer.url))
        let reference = try #require(NSImage(data: fixture.data))
        #expect(final.size == fixture.size)
        #expect(final.image.size == fixture.size)
        #expect(cached.image === final.image)
        #expect(final.image !== preview.image)
        #expect(try pixels(final.image) == pixels(reference), "Final presentation must retain the complete JPEG decode")
        let another = try #require(await provider.prefetch(transfer.url))
        #expect(another.image === final.image)
        #expect(transfer.requestCount == 1)
    }

    @Test("The old default initializer, PNG and baseline JPEG remain final-only", arguments: ["disabled", "png", "baseline"])
    func finalOnlyFallback(kind: String) async throws {
        let fixture = try (kind == "png" ? ProgressiveImageFixture.png :
            kind == "baseline" ? ProgressiveImageFixture.baseline : ProgressiveImageFixture.jpeg).get()
        let transfer = ControlledProgressiveImageTransfer(fixture: fixture)
        defer { transfer.unregister() }
        let session = progressiveImageSession()
        defer { session.invalidateAndCancel() }
        let provider = kind == "disabled" ? URLSessionMarkdownImageProvider(session: session)
            : URLSessionMarkdownImageProvider(session: session, progressiveJPEGPreviews: true)
        #expect(provider.progressiveJPEGPreviewsEnabled == (kind != "disabled"))
        let previews = ProgressivePreviewCollector()
        let download = Task { await provider.prefetch(transfer.url) { previews.append($0) } }
        defer { download.cancel() }
        try await transfer.waitForStart()
        let split = fixture.data.count / 2
        await transfer.send(fixture.data.prefix(split))
        await transfer.send(fixture.data.suffix(from: split))
        await transfer.finish()
        let final = try #require(await download.value)
        #expect(final.size == fixture.size)
        #expect(previews.results.isEmpty)
        #expect(transfer.requestCount == 1)
    }

    @Test("Duplicate URLs share one transfer while canceling one subscriber stops only its previews")
    func duplicateURLAndSubscriberCancellation() async throws {
        let fixture = try ProgressiveImageFixture.jpeg.get()
        let transfer = ControlledProgressiveImageTransfer(fixture: fixture)
        defer { transfer.unregister() }
        let session = progressiveImageSession()
        defer { session.invalidateAndCancel() }
        let provider = URLSessionMarkdownImageProvider(session: session, progressiveJPEGPreviews: true)
        let canceledPreviews = ProgressivePreviewCollector()
        let survivingPreviews = ProgressivePreviewCollector()
        let first = Task { await provider.prefetch(transfer.url) { canceledPreviews.append($0) } }
        let second = Task { await provider.prefetch(transfer.url) { survivingPreviews.append($0) } }
        defer { first.cancel(); second.cancel() }
        try await transfer.waitForStart()
        try await awaitProgressiveSubscribers(2, provider: provider, url: transfer.url)
        let firstSplit = fixture.data.count / 4
        let secondSplit = fixture.data.count * 3 / 4
        await transfer.send(fixture.data.prefix(firstSplit))
        try await canceledPreviews.waitForCount(1)
        try await survivingPreviews.waitForCount(1)
        first.cancel()
        try await awaitProgressiveSubscribers(1, provider: provider, url: transfer.url)
        let canceledCount = canceledPreviews.results.count
        let survivorCount = survivingPreviews.results.count
        await transfer.send(fixture.data[firstSplit..<secondSplit])
        try await survivingPreviews.waitForCount(survivorCount + 1)
        #expect(canceledPreviews.results.count == canceledCount)
        #expect(transfer.stoppedCount == 0, "A remaining subscriber retains the shared network request")
        await transfer.send(fixture.data.suffix(from: secondSplit))
        await transfer.finish()
        _ = await first.value // Compatibility: a canceled waiter may still receive the shared final value.
        let final = try #require(await second.value)
        #expect(final.size == fixture.size)
        #expect(canceledPreviews.results.count == canceledCount)
        #expect(transfer.requestCount == 1)
    }

    @Test("Canceling the last waiter retires the transfer and cannot publish into a replacement request")
    func canceledTransferDoesNotPublishStalePreview() async throws {
        let fixture = try ProgressiveImageFixture.jpeg.get()
        let original = ControlledProgressiveImageTransfer(fixture: fixture)
        defer { original.unregister() }
        let session = progressiveImageSession()
        defer { session.invalidateAndCancel() }
        let provider = URLSessionMarkdownImageProvider(session: session, progressiveJPEGPreviews: true)
        let stale = ProgressivePreviewCollector()
        let first = Task { await provider.prefetch(original.url) { stale.append($0) } }
        defer { first.cancel() }
        try await original.waitForStart()
        await original.send(fixture.data.prefix(fixture.data.count / 4))
        try await stale.waitForCount(1)
        first.cancel()
        try await original.waitForStop()
        _ = await first.value
        #expect(await provider.image(for: original.url) == nil)
        let oldCount = stale.results.count

        let replacement = ControlledProgressiveImageTransfer(fixture: fixture, url: original.url)
        defer { replacement.unregister() }
        let fresh = ProgressivePreviewCollector()
        let second = Task { await provider.prefetch(replacement.url) { fresh.append($0) } }
        defer { second.cancel() }
        try await replacement.waitForStart()
        let split = fixture.data.count / 2
        await replacement.send(fixture.data.prefix(split))
        try await fresh.waitForCount(1)
        #expect(stale.results.count == oldCount)
        await replacement.send(fixture.data.suffix(from: split))
        await replacement.finish()
        #expect(await second.value != nil)
        #expect(stale.results.count == oldCount)
        #expect(original.requestCount == 1 && replacement.requestCount == 1)
    }

    private func pixels(_ image: NSImage) throws -> Data {
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Data(bytes)
    }
}
#endif
