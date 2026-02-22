import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(BeautifulMermaid)
import BeautifulMermaid
#endif

public enum MermaidRenderingMode: Sendable, Equatable {
    case disabled
    case onFenceClose
    case bestEffortDebounced(milliseconds: Int)

    var isEnabled: Bool {
        switch self {
        case .disabled:
            return false
        case .onFenceClose, .bestEffortDebounced:
            return true
        }
    }
}

struct MermaidRenderRequest: Sendable {
    var source: String
    var targetWidth: CGFloat?
    var scale: CGFloat
}

struct MermaidRenderResult: @unchecked Sendable {
    var image: MarkdownImage
    var intrinsicSize: CGSize
    var diagnostics: String?
}

protocol MermaidDiagramProvider: Sendable {
    func render(_ request: MermaidRenderRequest) async -> MermaidRenderResult?
}

enum MermaidDiagramProviders {
    static func makeDefaultProvider(theme: MarkdownRenderTheme) -> (any MermaidDiagramProvider)? {
        guard theme.mermaidRenderingMode.isEnabled else { return nil }
        return BeautifulMermaidProvider(theme: theme)
    }
}

private enum MermaidAppearance: String, Sendable {
    case light
    case dark

    @MainActor
    static func current() -> MermaidAppearance {
        #if canImport(UIKit)
        let style = UIScreen.main.traitCollection.userInterfaceStyle
        return style == .dark ? .dark : .light
        #elseif canImport(AppKit)
        guard let app = NSApp else { return .light }
        let best = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return best == .darkAqua ? .dark : .light
        #else
        return .light
        #endif
    }
}

private struct MermaidThemeDescriptor: Sendable, Hashable {
    var background: ThemeColor
    var foreground: ThemeColor
    var line: ThemeColor
    var accent: ThemeColor
    var muted: ThemeColor
    var fontSize: CGFloat
    var widthBucket: Int?

    init(theme: MarkdownRenderTheme) {
        let codeTheme = theme.codeBlockTheme
        self.background = codeTheme?.backgroundColor ?? .secondaryBackground
        self.foreground = codeTheme?.foregroundColor ?? .label
        self.line = .separator
        self.accent = theme.linkColor
        self.muted = .secondaryLabel
        self.fontSize = theme.bodyFont.pointSize
        if let maxWidth = theme.imageMaxWidth, maxWidth > 0 {
            self.widthBucket = Int((maxWidth / 8).rounded(.toNearestOrAwayFromZero))
        } else {
            self.widthBucket = nil
        }
    }
}

private struct MermaidCacheKey: Hashable {
    var source: String
    var widthBucket: Int?
    var scaleBucket: Int
    var appearance: MermaidAppearance
    var themeDescriptor: MermaidThemeDescriptor
    var backendVersion: String
}

private actor BeautifulMermaidProvider: MermaidDiagramProvider {
    private let themeDescriptor: MermaidThemeDescriptor
    private let maxEntries: Int
    private let maxSourceLength: Int
    private let maxLineCount: Int
    private var cache: [MermaidCacheKey: MermaidRenderResult] = [:]
    private var lru: [MermaidCacheKey] = []

    init(theme: MarkdownRenderTheme,
         maxEntries: Int = 64,
         maxSourceLength: Int = 32_768,
         maxLineCount: Int = 1_024) {
        self.themeDescriptor = MermaidThemeDescriptor(theme: theme)
        self.maxEntries = maxEntries
        self.maxSourceLength = maxSourceLength
        self.maxLineCount = maxLineCount
    }

    func render(_ request: MermaidRenderRequest) async -> MermaidRenderResult? {
        let normalized = normalize(request.source)
        guard !normalized.isEmpty else { return nil }
        guard normalized.utf8.count <= maxSourceLength else { return nil }
        guard normalized.split(separator: "\n", omittingEmptySubsequences: false).count <= maxLineCount else { return nil }

        let appearance = await MainActor.run { MermaidAppearance.current() }
        let widthBucket = bucketWidth(request.targetWidth)
        let scaleBucket = Int((request.scale * 100).rounded(.toNearestOrAwayFromZero))
        let key = MermaidCacheKey(source: normalized,
                                  widthBucket: widthBucket,
                                  scaleBucket: scaleBucket,
                                  appearance: appearance,
                                  themeDescriptor: themeDescriptor,
                                  backendVersion: mermaidBackendVersion)

        if let cached = cache[key] {
            touch(key)
            return cached
        }

        #if canImport(BeautifulMermaid)
        do {
            let theme = makeDiagramTheme(for: appearance)
            guard let image = try MermaidRenderer.renderImage(source: normalized,
                                                             theme: theme,
                                                             scale: max(request.scale, 1.0)) else {
                return nil
            }
            let result = MermaidRenderResult(image: image,
                                             intrinsicSize: image.size,
                                             diagnostics: nil)
            insert(result, for: key)
            return result
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private func normalize(_ source: String) -> String {
        source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private func bucketWidth(_ width: CGFloat?) -> Int? {
        guard let width, width > 0 else { return nil }
        return Int((width / 8).rounded(.toNearestOrAwayFromZero))
    }

    private func touch(_ key: MermaidCacheKey) {
        if let idx = lru.firstIndex(of: key) {
            lru.remove(at: idx)
        }
        lru.append(key)
    }

    private func insert(_ value: MermaidRenderResult, for key: MermaidCacheKey) {
        cache[key] = value
        touch(key)
        while lru.count > maxEntries {
            let victim = lru.removeFirst()
            cache[victim] = nil
        }
    }

    #if canImport(BeautifulMermaid)
    private func makeDiagramTheme(for appearance: MermaidAppearance) -> DiagramTheme {
        var theme = appearance == .dark ? DiagramTheme.githubDark : DiagramTheme.githubLight
        theme.background = bmColor(themeDescriptor.background, appearance: appearance)
        theme.foreground = bmColor(themeDescriptor.foreground, appearance: appearance)
        theme.line = bmColor(themeDescriptor.line, appearance: appearance)
        theme.accent = bmColor(themeDescriptor.accent, appearance: appearance)
        theme.muted = bmColor(themeDescriptor.muted, appearance: appearance)
        theme.font = BMFont.systemFont(ofSize: themeDescriptor.fontSize)
        return theme
    }

    private func bmColor(_ color: ThemeColor, appearance: MermaidAppearance) -> BMColor {
        let rgba = appearance == .dark ? color.dark : color.light
        return BMColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
    #endif

    private var mermaidBackendVersion: String {
        #if canImport(BeautifulMermaid)
        return MermaidRenderer.version
        #else
        return "none"
        #endif
    }
}

extension MarkdownRenderTheme {
    public func withMermaidRendering(_ mode: MermaidRenderingMode) -> MarkdownRenderTheme {
        MarkdownRenderTheme(bodyFont: bodyFont,
                            codeFont: codeFont,
                            blockquoteColor: blockquoteColor,
                            linkColor: linkColor,
                            headingFonts: headingFonts,
                            imageMaxWidth: imageMaxWidth,
                            codeBlockTheme: codeBlockTheme,
                            codeHighlighter: codeHighlighter,
                            mermaidRenderingMode: mode)
    }
}
