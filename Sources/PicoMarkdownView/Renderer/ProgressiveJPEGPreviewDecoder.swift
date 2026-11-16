#if os(macOS)
import AppKit
import Foundation
import ImageIO

/// A bounded preview decoder. The lock protects scheduling and cancellation;
/// Image I/O state is used only on the shared serial utility queue.
final class ProgressiveJPEGPreviewDecoder: @unchecked Sendable {
    static let firstCheckpointByteCount = 4 * 1024
    static let maxDecodeAttempts = 8
    static let maxPreviewPixelSize = 1024
    static let maxPreviewPixelCount = 40_000_000

    private static let decodeQueue = DispatchQueue(
        label: "PicoMarkdownView.progressive-jpeg", qos: .utility
    )

    private let lock = NSLock()
    private let onPreview: @Sendable (MarkdownImageResult) -> Void
    private var pendingData: Data?
    private var workerScheduled = false
    private var finished = false
    private var nextCheckpoint = firstCheckpointByteCount
    private var acceptedCheckpoints = 0
    private var attempts = 0
    private var jpegSignatureConfirmed = false

    // Confined to decodeQueue, including updates to the incremental source.
    private let source = CGImageSourceCreateIncremental(nil)

    init(onPreview: @escaping @Sendable (MarkdownImageResult) -> Void) {
        self.onPreview = onPreview
    }

    var decodeAttemptCount: Int {
        lock.withLock { attempts }
    }

    /// Image I/O requires the complete accumulated prefix, rather than a delta.
    /// Retain at most one pending prefix, and only at geometric checkpoints.
    func submit(_ accumulatedData: Data) {
        let shouldSchedule = lock.withLock {
            guard !finished else { return false }
            if !jpegSignatureConfirmed {
                guard accumulatedData.count >= 3 else { return false }
                guard accumulatedData.prefix(3).elementsEqual([0xff, 0xd8, 0xff]) else {
                    finished = true
                    pendingData = nil
                    return false
                }
                jpegSignatureConfirmed = true
            }
            guard acceptedCheckpoints < Self.maxDecodeAttempts,
                  accumulatedData.count >= nextCheckpoint else { return false }
            acceptedCheckpoints += 1
            nextCheckpoint = accumulatedData.count * 2
            pendingData = accumulatedData
            guard !workerScheduled else { return false }
            workerScheduled = true
            return true
        }
        if shouldSchedule {
            Self.decodeQueue.async { [self] in drainPendingData() }
        }
    }

    /// Final delivery uses the provider's existing full-image decode. Retire any
    /// queued preview work so it cannot supersede that final presentation.
    func finish() {
        lock.withLock {
            finished = true
            pendingData = nil
        }
    }

    /// Also lets callers deterministically wait for cancellation to drain.
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            Self.decodeQueue.async { continuation.resume() }
        }
    }

    private func drainPendingData() {
        while let data = takePendingData() {
            guard let preview = decode(data) else { continue }
            if lock.withLock({ !finished }) {
                onPreview(preview)
            }
        }
    }

    private func takePendingData() -> Data? {
        lock.withLock {
            guard !finished, let data = pendingData else {
                workerScheduled = false
                return nil
            }
            pendingData = nil
            attempts += 1
            return data
        }
    }

    private func decode(_ data: Data) -> MarkdownImageResult? {
        CGImageSourceUpdateData(source, data as CFData, false)
        guard CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let jfif = properties[kCGImagePropertyJFIFDictionary] as? [CFString: Any]
        // Image I/O can omit IsProgressive for baseline JPEG. Dimensions mean
        // its frame header is available, so an absent flag is now conclusive.
        guard jfif?[kCGImagePropertyJFIFIsProgressive] as? Bool == true else {
            finish()
            return nil
        }

        let sourceWidth = width.doubleValue
        let sourceHeight = height.doubleValue
        guard sourceWidth.isFinite, sourceHeight.isFinite,
              sourceWidth > 0, sourceHeight > 0,
              sourceWidth * sourceHeight <= Double(Self.maxPreviewPixelCount) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPreviewPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width <= Self.maxPreviewPixelSize,
              image.height <= Self.maxPreviewPixelSize else { return nil }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let isRotated = (5...8).contains(orientation)
        let logicalSize = CGSize(width: isRotated ? sourceHeight : sourceWidth,
                                 height: isRotated ? sourceWidth : sourceHeight)
        let snapshot = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        return MarkdownImageResult(image: snapshot, size: logicalSize)
    }
}
#endif
