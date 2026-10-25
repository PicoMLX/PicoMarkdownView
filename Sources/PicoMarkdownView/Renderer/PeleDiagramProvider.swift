import Foundation
import os

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The default `MermaidDiagramProvider`: Pele (via `PeleRenderer`) lays the
/// diagram out and `PeleSVGDocument` rasterizes it, both off the main actor.
///
/// Colors come from the `MarkdownRenderTheme` the view was given, resolved
/// for the current light/dark appearance, so diagrams match the surrounding
/// text and code blocks. Labels are measured and drawn in the system font.
/// Results are cached per source, available width, display scale,
/// appearance and theme, because the renderer re-requests closed fences
/// when the view's width bucket changes.
actor PeleDiagramProvider: MermaidDiagramProvider {
    private struct CacheKey: Hashable {
        var source: String
        var widthBucket: Int?
        var scaleBucket: Int
        var appearance: PeleAppearance
    }

    private let theme: MarkdownRenderTheme
    private let maxEntries: Int
    private let maxSourceLength: Int
    private let maxLineCount: Int
    private var cache: [CacheKey: MermaidRenderResult] = [:]
    private var lru: [CacheKey] = []
    private static let logger = Logger(subsystem: "com.picomarkdown", category: "PeleDiagramProvider")

    init(theme: MarkdownRenderTheme,
         maxEntries: Int = 64,
         maxSourceLength: Int = 32_768,
         maxLineCount: Int = 1_024) {
        self.theme = theme
        self.maxEntries = maxEntries
        self.maxSourceLength = maxSourceLength
        self.maxLineCount = maxLineCount
    }

    func render(_ request: MermaidRenderRequest) async -> MermaidRenderResult? {
        let source = request.source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard source.utf8.count <= maxSourceLength else { return nil }
        guard source.split(separator: "\n", omittingEmptySubsequences: false).count <= maxLineCount else { return nil }
        guard let renderer = PeleRenderer.shared else { return nil }

        let appearance = await MainActor.run { PeleAppearance.current() }
        let scale = max(request.scale, 1)
        let targetWidth = request.targetWidth.flatMap { $0 > 0 ? $0 : nil }
        let key = CacheKey(source: source,
                           widthBucket: targetWidth.map { Int(($0 / 8).rounded(.toNearestOrAwayFromZero)) },
                           scaleBucket: Int((scale * 100).rounded(.toNearestOrAwayFromZero)),
                           appearance: appearance)
        if let cached = cache[key] {
            touch(key)
            return cached
        }

        let options = PeleRenderOptions(fontSize: theme.bodyFont.pointSize,
                                        fontFamily: "sans-serif",
                                        maxWidth: targetWidth,
                                        theme: Self.peleTheme(for: theme, appearance: appearance))
        let rendered: PeleRenderResult
        do {
            rendered = try await renderer.render(source, options: options)
        } catch {
            // The message quotes the offending source line, which is chat
            // content; only the code is safe to log unredacted.
            Self.logger.debug("Pele could not render a fence (\(error.code, privacy: .public)): \(error.message, privacy: .private)")
            return nil
        }

        guard
            let document = PeleSVGDocument(svg: rendered.svg),
            let image = document.makeImage(scale: scale)
        else {
            Self.logger.error("Pele output for a \(rendered.type, privacy: .public) diagram could not be rasterized")
            return nil
        }

        let result = MermaidRenderResult(image: image,
                                         intrinsicSize: CGSize(width: document.width, height: document.height),
                                         diagnostics: nil)
        insert(result, for: key)
        return result
    }

    // MARK: Theme

    /// Pele's `--pele-*` variables for the theme in the given appearance.
    /// Keys are documented on `PeleRenderOptions.theme`.
    static func peleTheme(for theme: MarkdownRenderTheme, appearance: PeleAppearance) -> [String: String] {
        let code = theme.codeBlockTheme
        let foreground = code?.foregroundColor ?? .label
        func css(_ color: ThemeColor) -> String {
            let rgba = appearance == .dark ? color.dark : color.light
            func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            if rgba.alpha >= 1 {
                return String(format: "#%02x%02x%02x", channel(rgba.red), channel(rgba.green), channel(rgba.blue))
            }
            return "rgba(\(channel(rgba.red)),\(channel(rgba.green)),\(channel(rgba.blue)),\(String(format: "%.3f", Double(rgba.alpha))))"
        }
        return [
            "bg": css(.background),
            "fg": css(foreground),
            "line": css(foreground),
            "muted": css(.secondaryLabel),
            "surface": css(code?.backgroundColor ?? .secondaryBackground),
            "surface-alt": css(.tableHeaderBackground),
            "border": css(.separator),
            "accent": css(theme.linkColor),
            "font": "sans-serif",
            "font-mono": "monospace"
        ]
    }

    // MARK: Cache

    private func touch(_ key: CacheKey) {
        if let index = lru.firstIndex(of: key) {
            lru.remove(at: index)
        }
        lru.append(key)
    }

    private func insert(_ value: MermaidRenderResult, for key: CacheKey) {
        cache[key] = value
        touch(key)
        while lru.count > maxEntries {
            let victim = lru.removeFirst()
            cache[victim] = nil
        }
    }
}

enum PeleAppearance: Sendable, Hashable {
    case light
    case dark

    @MainActor
    static func current() -> PeleAppearance {
        #if canImport(UIKit)
        return UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        #elseif canImport(AppKit)
        guard let app = NSApp else { return .light }
        return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        #else
        return .light
        #endif
    }
}
