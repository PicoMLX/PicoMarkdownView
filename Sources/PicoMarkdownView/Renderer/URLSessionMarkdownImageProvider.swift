import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

protocol MarkdownImagePrefetchingProvider: MarkdownImageProvider {
    func prefetch(_ url: URL) async -> MarkdownImageResult?
}

public actor URLSessionMarkdownImageProvider: MarkdownImagePrefetchingProvider {
    public static let shared = URLSessionMarkdownImageProvider()

    private let session: URLSession
    private var cache: [URL: MarkdownImageResult] = [:]
    private var inFlight: [URL: Task<MarkdownImageResult?, Never>] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func image(for url: URL) async -> MarkdownImageResult? {
        guard Self.isSupportedRemoteURL(url) else { return nil }
        return cache[url]
    }

    func prefetch(_ url: URL) async -> MarkdownImageResult? {
        guard Self.isSupportedRemoteURL(url) else { return nil }
        if let cached = cache[url] {
            return cached
        }
        if let existing = inFlight[url] {
            return await existing.value
        }

        let task = Task<MarkdownImageResult?, Never> { [session] in
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    return nil
                }
                return Self.decodeImage(data: data)
            } catch {
                return nil
            }
        }
        inFlight[url] = task

        let result = await task.value
        inFlight[url] = nil
        if let result {
            cache[url] = result
        }
        return result
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
