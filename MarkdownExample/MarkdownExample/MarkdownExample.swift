import Foundation
import PicoMarkdownView

/// One bundled document. Static page definitions keep its streaming identity stable.
nonisolated struct MarkdownExample: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let localFilename: String
    let referenceURL: URL?
    let tagPrefixes: Set<TagPrefix>
    let htmlPreviewsEnabled: Bool
    let isLargeFixture: Bool
    let svgRenderingEnabled: Bool
    let usesBundledImages: Bool

    init(_ localFilename: String,
         name: String? = nil,
         reference: String? = nil,
         tagPrefixes: Set<TagPrefix> = [],
         htmlPreviewsEnabled: Bool = false,
         isLargeFixture: Bool = false,
         svgRenderingEnabled: Bool = false,
         usesBundledImages: Bool = false) {
        self.name = name ?? localFilename
        self.localFilename = localFilename
        self.referenceURL = reference.flatMap(URL.init(string:))
        self.tagPrefixes = tagPrefixes
        self.htmlPreviewsEnabled = htmlPreviewsEnabled
        self.isLargeFixture = isLargeFixture
        self.svgRenderingEnabled = svgRenderingEnabled
        self.usesBundledImages = usesBundledImages
    }

    func loadMarkdown() throws -> String {
        guard let url = Bundle.main.url(forResource: localFilename, withExtension: "md")
            ?? Bundle.main.url(forResource: localFilename, withExtension: "md.deflate") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        let decoded = url.pathExtension == "deflate"
            ? try (data as NSData).decompressed(using: .zlib) as Data : data
        return String(decoding: decoded, as: UTF8.self)
    }
}
