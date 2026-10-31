#if os(macOS)
import AppKit

/// A loaded block image activated by the user. The app owns its presentation.
/// The original image is reused; activation never downloads or decodes it again.
@MainActor
public struct MarkdownImageActivation {
    public let image: NSImage
    public let sourceURL: URL
    public let altText: String
    public let title: String?
    public let preferredSize: CGSize
    public let markdown: String

    public init(image: NSImage, sourceURL: URL, altText: String, title: String? = nil,
                preferredSize: CGSize? = nil, markdown: String = "") {
        self.image = image
        self.sourceURL = sourceURL
        self.altText = altText
        self.title = title
        self.preferredSize = preferredSize ?? image.size
        self.markdown = markdown
    }
}

#endif
