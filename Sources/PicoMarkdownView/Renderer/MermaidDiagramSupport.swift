import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
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

/// Turns the source of a closed ```` ```mermaid ```` fence into an image for
/// the text attachment that replaces the code block. `PeleDiagramProvider`
/// is the default; tests inject their own.
protocol MermaidDiagramProvider: Sendable {
    func render(_ request: MermaidRenderRequest) async -> MermaidRenderResult?
}

enum MermaidDiagramProviders {
    static func makeDefaultProvider(theme: MarkdownRenderTheme) -> (any MermaidDiagramProvider)? {
        guard theme.mermaidRenderingMode.isEnabled else { return nil }
        return PeleDiagramProvider(theme: theme)
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
