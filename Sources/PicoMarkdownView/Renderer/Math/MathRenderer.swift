import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

actor MathRenderer {
    private var cache: [CacheKey: MathRenderArtifact] = [:]

    func render(tex: String, display: Bool, font: MathRenderFontSpec) async -> MathRenderArtifact {
        let trimmed = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MathRenderArtifact(size: .zero, baseline: 0, commands: [])
        }

        let key = CacheKey(tex: trimmed, display: display, font: font)
        if let cached = cache[key] {
            return cached
        }

        let baseFont = font.makePlatformFont()
        let typesetter = MathTypesetter(baseFont: baseFont)
        let artifact: MathRenderArtifact
        do {
            var parser = MathParser(string: trimmed)
            let node = try parser.parse()
            artifact = typesetter.artifact(for: node, display: display)
        } catch {
            let fallbackNode = MathNode.text(trimmed)
            artifact = typesetter.artifact(for: fallbackNode, display: display)
        }

        cache[key] = artifact
        return artifact
    }
}

struct MathRenderFontSpec: Hashable {
    var postScriptName: String
    var pointSize: CGFloat
}

private struct CacheKey: Hashable {
    var tex: String
    var display: Bool
    var font: MathRenderFontSpec
}

private extension MathRenderFontSpec {
    func makePlatformFont() -> PlatformFont {
#if canImport(UIKit)
        if let font = UIFont(name: postScriptName, size: pointSize) {
            return font
        }
        return UIFont.systemFont(ofSize: pointSize)
#else
        if let font = NSFont(name: postScriptName, size: pointSize) {
            return font
        }
        return NSFont.systemFont(ofSize: pointSize)
#endif
    }
}
