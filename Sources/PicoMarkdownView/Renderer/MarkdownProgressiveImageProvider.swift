#if os(macOS)
import Foundation

/// Optional image-delivery capability used by the macOS standalone image host.
/// The awaited result remains the final image; callbacks contain only previews.
protocol MarkdownProgressiveImagePrefetchingProvider: MarkdownImagePrefetchingProvider {
    var progressiveJPEGPreviewsEnabled: Bool { get }

    func prefetch(
        _ url: URL,
        onPreview: @escaping @Sendable (MarkdownImageResult) -> Void
    ) async -> MarkdownImageResult?
}
#endif
