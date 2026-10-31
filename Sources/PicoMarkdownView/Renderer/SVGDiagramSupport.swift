import Foundation

/// A closed SVG fence whose original source remains available as the native
/// code presentation until the macOS host validates its vector document.
struct RenderedSVGGraphic: Sendable, Equatable {
    var source: String
    var language: String
    var maxWidth: CGFloat? = nil
}

enum SVGDiagramSupport {
    static func isSVGLanguage(_ language: String?) -> Bool {
        language?.split(whereSeparator: \.isWhitespace).first?.lowercased() == "svg"
    }

    static func graphic(for snapshot: BlockSnapshot, enabled: Bool, maxWidth: CGFloat?) -> RenderedSVGGraphic? {
#if os(macOS)
        guard enabled, snapshot.isClosed,
              case .fencedCode(let language) = snapshot.kind,
              let language, isSVGLanguage(language), let source = snapshot.codeText,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return RenderedSVGGraphic(source: source, language: language,
                                  maxWidth: maxWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
#else
        return nil
#endif
    }
}

extension MarkdownRenderTheme {
    /// Opts in to rendering completed `svg` fences as vector graphics on macOS.
    /// While streaming, open fences remain code. Invalid SVG falls back to code.
    /// UIKit rendering and raw HTML blocks are unchanged. Like the other theme
    /// settings, this is captured when a PicoMarkdownView is constructed.
    public func withSVGRendering(_ enabled: Bool = true) -> MarkdownRenderTheme {
        MarkdownRenderTheme(bodyFont: bodyFont,
                            codeFont: codeFont,
                            blockquoteColor: blockquoteColor,
                            linkColor: linkColor,
                            headingFonts: headingFonts,
                            imageMaxWidth: imageMaxWidth,
                            codeBlockTheme: codeBlockTheme,
                            codeHighlighter: codeHighlighter,
                            mermaidRenderingMode: mermaidRenderingMode,
                            svgRenderingEnabled: enabled,
                            openUIRenderingEnabled: openUIRenderingEnabled)
    }
}
