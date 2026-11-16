import Foundation
import PicoMarkdownView
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The offline Images sample resolves only its three bundled PngSuite assets.
nonisolated struct ExampleImageProvider: MarkdownImageProvider {
    func image(for url: URL) async -> MarkdownImageResult? {
        guard url.scheme == "example-image", url.host?.isEmpty != false,
              url.query == nil, url.fragment == nil else { return nil }
        let name = String(url.path.dropFirst())
        guard ["basn2c08.png", "basn3p08.png", "basn6a08.png"].contains(name),
              let resource = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "ExampleImages")
                ?? Bundle.main.url(forResource: name, withExtension: nil),
              let data = try? Data(contentsOf: resource),
              let image = MarkdownImage(data: data) else { return nil }
        return MarkdownImageResult(image: image)
    }
}
