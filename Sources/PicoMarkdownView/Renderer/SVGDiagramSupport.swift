import Foundation

/// An opted-in SVG fence. Open fences reserve a hosted loading row; closed
/// fences keep native code available until the host validates the drawing.
struct RenderedSVGGraphic: Sendable, Equatable {
    var source: String
    var language: String
    var maxWidth: CGFloat? = nil
    var isClosed = true
}

enum SVGDiagramSupport {
    static func isSVGLanguage(_ language: String?) -> Bool {
        language?.split(whereSeparator: \.isWhitespace).first?.lowercased() == "svg"
    }

    static func graphic(for snapshot: BlockSnapshot, enabled: Bool, maxWidth: CGFloat?) -> RenderedSVGGraphic? {
#if os(macOS)
        guard enabled, case .fencedCode(let language) = snapshot.kind,
              let language, isSVGLanguage(language) else { return nil }
        return RenderedSVGGraphic(source: snapshot.codeText ?? "", language: language,
                                  maxWidth: maxWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                                  isClosed: snapshot.isClosed)
#else
        return nil
#endif
    }
}

extension MarkdownRenderTheme {
    /// Opts in to rendering `svg` fences as vector graphics on macOS.
    /// While streaming, open fences show a delayed loading row instead of XML.
    /// The SVG is decoded on closure. Invalid final SVG falls back to code.
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
