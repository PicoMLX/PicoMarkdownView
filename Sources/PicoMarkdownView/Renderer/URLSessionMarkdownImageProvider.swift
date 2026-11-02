import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

protocol MarkdownImagePrefetchingProvider: MarkdownImageProvider {
    func prefetch(_ url: URL) async -> MarkdownImageResult?
}

/// Default remote image loader.
///
/// Markdown rendered by this package is typically untrusted (LLM output), so
/// the provider enforces hard limits: downloads are capped at
/// ``maxDownloadByteCount`` (checked against `Content-Length` before the body
/// is read, and streamed with an incremental cap when the header is absent),
/// requests time out, and decoded images are kept in a count-bounded LRU
/// cache instead of growing without limit.
public actor URLSessionMarkdownImageProvider: MarkdownImagePrefetchingProvider {
    public static let shared = URLSessionMarkdownImageProvider()

    /// Maximum accepted response body for a single image (8 MB).
    public static let maxDownloadByteCount = 8 * 1024 * 1024
    /// Maximum number of decoded images retained in memory.
    public static let maxCachedImages = 96

    private let session: URLSession
    #if os(macOS)
    /// Enables bounded intermediate JPEG snapshots for standalone image hosts.
    nonisolated let progressiveJPEGPreviewsEnabled: Bool
    #endif
    /// A shared download with a claim count. Concurrent prefetches of the
    /// same URL await one task; a cancelled awaiter releases its claim and
    /// the download is cancelled only when no claims remain, so one view
    /// scrolling away cannot kill a download another view is waiting on.
    /// `id` guards cleanup against racing a *newer* entry for the same URL.
    private struct InFlightDownload {
        let id: UInt64
        let task: Task<MarkdownImageResult?, Never>
        var waiters: Int
        #if os(macOS)
        var previewObservers: [UInt64: @Sendable (MarkdownImageResult) -> Void] = [:]
        var lastPreviewSequence: UInt64 = 0
        #endif
    }

    private var cache: [URL: MarkdownImageResult] = [:]
    private var lru: [URL] = []
    private var inFlight: [URL: InFlightDownload] = [:]
    private var nextDownloadID: UInt64 = 0
    #if os(macOS)
    private var nextPreviewObserverID: UInt64 = 0
    #endif

    public init(session: URLSession? = nil) {
        #if os(macOS)
        progressiveJPEGPreviewsEnabled = false
        #endif
        self.session = Self.makeSession(session)
    }

    #if os(macOS)
    /// Opts in to intermediate JPEG previews. Other formats and final images
    /// retain the same download, cache, and decoding behavior.
    public init(session: URLSession? = nil, progressiveJPEGPreviews: Bool) {
        progressiveJPEGPreviewsEnabled = progressiveJPEGPreviews
        self.session = Self.makeSession(session)
    }
    #endif

    private static func makeSession(_ session: URLSession?) -> URLSession {
        if let session {
            return session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = false
            return URLSession(configuration: configuration)
        }
    }

    public func image(for url: URL) async -> MarkdownImageResult? {
        guard Self.isSupportedRemoteURL(url) else { return nil }
        guard let cached = cache[url] else { return nil }
        touch(url)
        return cached
    }

    func prefetch(_ url: URL) async -> MarkdownImageResult? {
        await prefetchShared(url, onPreview: nil)
    }

    #if os(macOS)
    func prefetch(_ url: URL,
                  onPreview: @escaping @Sendable (MarkdownImageResult) -> Void) async -> MarkdownImageResult? {
        await prefetchShared(url, onPreview: progressiveJPEGPreviewsEnabled ? onPreview : nil)
    }
    #endif

    private func prefetchShared(_ url: URL,
                                onPreview: (@Sendable (MarkdownImageResult) -> Void)?) async -> MarkdownImageResult? {
        guard Self.isSupportedRemoteURL(url) else { return nil }
        if let cached = cache[url] {
            touch(url)
            return cached
        }

        let entryID: UInt64
        let downloadTask: Task<MarkdownImageResult?, Never>
        #if os(macOS)
        nextPreviewObserverID &+= 1
        let observerID = nextPreviewObserverID
        #endif
        if var existing = inFlight[url] {
            existing.waiters += 1
            #if os(macOS)
            existing.previewObservers[observerID] = onPreview
            #endif
            inFlight[url] = existing
            entryID = existing.id
            downloadTask = existing.task
        } else {
            nextDownloadID &+= 1
            let id = nextDownloadID
            #if os(macOS)
            let decoder: ProgressiveJPEGPreviewDecoder?
            if progressiveJPEGPreviewsEnabled, onPreview != nil {
                let sequence = PreviewSequence()
                decoder = ProgressiveJPEGPreviewDecoder { [weak self] preview in
                    let revision = sequence.next()
                    Task { await self?.publishPreview(preview, url: url, entryID: id, sequence: revision) }
                }
            } else {
                decoder = nil
            }
            let onData: (@Sendable (Data) -> Void)?
            if let decoder {
                onData = { data in decoder.submit(data) }
            } else {
                onData = nil
            }
            #else
            let onData: (@Sendable (Data) -> Void)? = nil
            #endif
            let task = Task<MarkdownImageResult?, Never> { [session] in
                #if os(macOS)
                defer { decoder?.finish() }
                #endif
                do {
                    let data = try await Self.download(url: url, session: session, onData: onData)
                    return data.flatMap(Self.decodeImage(data:))
                } catch {
                    return nil
                }
            }
            var entry = InFlightDownload(id: id, task: task, waiters: 1)
            #if os(macOS)
            entry.previewObservers[observerID] = onPreview
            #endif
            inFlight[url] = entry
            entryID = id
            downloadTask = task
        }

        // Awaiting an unstructured Task's value does not forward the caller's
        // cancellation into it; release this caller's claim explicitly so an
        // abandoned prefetch stops the network transfer once no other view is
        // waiting on the same URL.
        let result = await withTaskCancellationHandler {
            await downloadTask.value
        } onCancel: {
            Task {
                #if os(macOS)
                await self.removePreviewObserver(url: url, entryID: entryID, observerID: observerID)
                #endif
                await self.releaseWaiter(url: url, entryID: entryID)
            }
        }

        if let entry = inFlight[url], entry.id == entryID {
            inFlight[url] = nil
        }
        if let result {
            insert(result, for: url)
        }
        return result
    }

    #if os(macOS)
    func activeProgressiveSubscriberCount(for url: URL) -> Int {
        inFlight[url]?.previewObservers.count ?? 0
    }

    private func publishPreview(_ preview: MarkdownImageResult, url: URL, entryID: UInt64, sequence: UInt64) {
        guard var entry = inFlight[url], entry.id == entryID,
              sequence > entry.lastPreviewSequence else { return }
        entry.lastPreviewSequence = sequence
        inFlight[url] = entry
        for observer in entry.previewObservers.values {
            observer(preview)
        }
    }

    private func removePreviewObserver(url: URL, entryID: UInt64, observerID: UInt64) {
        guard var entry = inFlight[url], entry.id == entryID else { return }
        entry.previewObservers[observerID] = nil
        inFlight[url] = entry
    }

    /// Decoder callbacks are serial, but their actor-hop tasks may arrive out
    /// of order. A sequence prevents an older snapshot replacing a newer one.
    private final class PreviewSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func next() -> UInt64 {
            lock.withLock {
                value &+= 1
                return value
            }
        }
    }
    #endif

    private func releaseWaiter(url: URL, entryID: UInt64) {
        guard var entry = inFlight[url], entry.id == entryID else { return }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            entry.task.cancel()
            inFlight[url] = nil
        } else {
            inFlight[url] = entry
        }
    }

    private func insert(_ result: MarkdownImageResult, for url: URL) {
        cache[url] = result
        touch(url)
        while lru.count > Self.maxCachedImages {
            let victim = lru.removeFirst()
            cache[victim] = nil
        }
    }

    private func touch(_ url: URL) {
        if let index = lru.firstIndex(of: url) {
            lru.remove(at: index)
        }
        lru.append(url)
    }

    /// Downloads the response body, rejecting it as soon as either the
    /// declared `Content-Length` or the accumulated byte count exceeds the
    /// cap. Uses a `URLSessionDataDelegate` so the body arrives in
    /// transport-sized `Data` chunks — enforcing the cap incrementally
    /// without the per-byte async overhead of `URLSession.AsyncBytes`.
    ///
    /// Cancelling the surrounding Swift task (view reset, scroll-out) cancels
    /// the underlying data task too, so abandoned prefetches stop downloading
    /// instead of running to timeout or the byte cap.
    private static func download(url: URL, session: URLSession,
                                 onData: (@Sendable (Data) -> Void)?) async throws -> Data? {
        let task = session.dataTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                let delegate = CappedDownloadDelegate(byteLimit: maxDownloadByteCount, onData: onData) { result in
                    continuation.resume(with: result)
                }
                task.delegate = delegate
                task.resume()
            }
        } onCancel: {
            // Triggers didCompleteWithError(NSURLErrorCancelled) on the
            // delegate, which resumes the continuation exactly once.
            task.cancel()
        }
    }

    /// Accumulates a capped response body. URLSession serializes all delegate
    /// callbacks on its delegate queue, so the mutable state needs no locking
    /// (`@unchecked Sendable` relies on that serialization).
    private final class CappedDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let byteLimit: Int
        private var buffer = Data()
        private var completion: ((Result<Data?, Error>) -> Void)?
        private let onData: (@Sendable (Data) -> Void)?

        init(byteLimit: Int, onData: (@Sendable (Data) -> Void)?,
             completion: @escaping (Result<Data?, Error>) -> Void) {
            self.byteLimit = byteLimit
            self.onData = onData
            self.completion = completion
        }

        func urlSession(_ session: URLSession,
                        dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                finish(.success(nil))
                completionHandler(.cancel)
                return
            }
            let expected = response.expectedContentLength
            if expected != NSURLSessionTransferSizeUnknown, expected > Int64(byteLimit) {
                finish(.success(nil))
                completionHandler(.cancel)
                return
            }
            if expected > 0 {
                buffer.reserveCapacity(Int(min(expected, Int64(byteLimit))))
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard completion != nil else { return }
            // Reject before appending so a server that omits or understates
            // Content-Length cannot force even a transient allocation beyond
            // the cap.
            guard buffer.count + data.count <= byteLimit else {
                finish(.success(nil))
                dataTask.cancel()
                return
            }
            buffer.append(data)
            onData?(buffer)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                finish(.failure(error))
            } else {
                finish(.success(buffer))
            }
        }

        /// Resumes the continuation exactly once. Cancelling a task after an
        /// early rejection still triggers `didCompleteWithError`, which must
        /// not resume again.
        private func finish(_ result: Result<Data?, Error>) {
            guard let completion else { return }
            self.completion = nil
            completion(result)
        }
    }

    private static func isSupportedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func decodeImage(data: Data) -> MarkdownImageResult? {
        guard !data.isEmpty else { return nil }
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        #endif
        let size = image.size
        return MarkdownImageResult(image: image, size: size.width > 0 && size.height > 0 ? size : nil)
    }
}

#if os(macOS)
extension URLSessionMarkdownImageProvider: MarkdownProgressiveImagePrefetchingProvider {}
#endif
