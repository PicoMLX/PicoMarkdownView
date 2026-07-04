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
    private var cache: [URL: MarkdownImageResult] = [:]
    private var lru: [URL] = []
    private var inFlight: [URL: Task<MarkdownImageResult?, Never>] = [:]

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    public func image(for url: URL) async -> MarkdownImageResult? {
        guard Self.isSupportedRemoteURL(url) else { return nil }
        guard let cached = cache[url] else { return nil }
        touch(url)
        return cached
    }

    func prefetch(_ url: URL) async -> MarkdownImageResult? {
        guard Self.isSupportedRemoteURL(url) else { return nil }
        if let cached = cache[url] {
            touch(url)
            return cached
        }
        if let existing = inFlight[url] {
            return await existing.value
        }

        let task = Task<MarkdownImageResult?, Never> { [session] in
            do {
                let data = try await Self.download(url: url, session: session)
                return data.flatMap(Self.decodeImage(data:))
            } catch {
                return nil
            }
        }
        inFlight[url] = task

        let result = await task.value
        inFlight[url] = nil
        if let result {
            insert(result, for: url)
        }
        return result
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
    private static func download(url: URL, session: URLSession) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            let delegate = CappedDownloadDelegate(byteLimit: maxDownloadByteCount) { result in
                continuation.resume(with: result)
            }
            let task = session.dataTask(with: url)
            task.delegate = delegate
            task.resume()
        }
    }

    /// Accumulates a capped response body. URLSession serializes all delegate
    /// callbacks on its delegate queue, so the mutable state needs no locking
    /// (`@unchecked Sendable` relies on that serialization).
    private final class CappedDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let byteLimit: Int
        private var buffer = Data()
        private var completion: ((Result<Data?, Error>) -> Void)?

        init(byteLimit: Int, completion: @escaping (Result<Data?, Error>) -> Void) {
            self.byteLimit = byteLimit
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
            buffer.append(data)
            if buffer.count > byteLimit {
                finish(.success(nil))
                dataTask.cancel()
            }
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
