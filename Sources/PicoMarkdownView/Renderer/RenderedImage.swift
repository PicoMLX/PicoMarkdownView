import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

struct RenderedImage: Sendable, Equatable, Identifiable {
    struct Identifier: Sendable, Equatable, Hashable {
        let rawValue: String
    }

    var id: Identifier
    var source: String
    var url: URL?
    var altText: String
    var title: String?
    var suggestedSize: CGSize?

    init(id: Identifier,
         source: String,
         url: URL?,
         altText: String,
         title: String?,
         suggestedSize: CGSize? = nil) {
        self.id = id
        self.source = source
        self.url = url
        self.altText = altText
        self.title = title
        self.suggestedSize = suggestedSize
    }
}

extension RenderedImage.Identifier {
    static func make(blockID: BlockID, index: Int) -> Self {
        Self(rawValue: "\(blockID)-image-\(index)")
    }
}
