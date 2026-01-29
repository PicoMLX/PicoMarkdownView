import Foundation

#if canImport(UIKit)
import UIKit
public typealias MarkdownImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias MarkdownImage = NSImage
#endif

public struct MarkdownImageResult: @unchecked Sendable {
    public var image: MarkdownImage
    public var size: CGSize?

    public init(image: MarkdownImage, size: CGSize? = nil) {
        self.image = image
        self.size = size
    }
}

public protocol MarkdownImageProvider: Sendable {
    func image(for url: URL) async -> MarkdownImageResult?
}
