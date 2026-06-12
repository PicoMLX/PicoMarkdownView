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

    /// Streams the response body, rejecting it as soon as either the declared
    /// `Content-Length` or the accumulated byte count exceeds the cap.
    private static func download(url: URL, session: URLSession) async throws -> Data? {
        let (bytes, response) = try await session.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        let expected = response.expectedContentLength
        if expected != NSURLSessionTransferSizeUnknown, expected > Int64(maxDownloadByteCount) {
            return nil
        }

        var data = Data()
        if expected > 0, expected <= Int64(maxDownloadByteCount) {
            data.reserveCapacity(Int(expected))
        }
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxDownloadByteCount {
                return nil
            }
        }
        return data
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
