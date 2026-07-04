import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Styling for a single syntax token type: color, bold, and italic.
public struct TokenStyle: Sendable, Hashable {
    public let color: ThemeColor?
    public let bold: Bool
    public let italic: Bool

    public init(color: ThemeColor? = nil, bold: Bool = false, italic: Bool = false) {
        self.color = color
        self.bold = bold
        self.italic = italic
    }
}

/// Appearance settings for fenced code blocks.
///
/// All properties are `Sendable` value types. Call `resolvedFont()`,
/// `resolvedForegroundColor()`, etc. to get platform types at render time.
public struct CodeBlockTheme: Sendable, Hashable {
    public let font: FontSpec
    public let foregroundColor: ThemeColor
    public let backgroundColor: ThemeColor
    /// Per-token-type styling for syntax highlighting.
    public let tokenColors: [PrismTokenType: TokenStyle]

    public init(font: FontSpec,
                foregroundColor: ThemeColor,
                backgroundColor: ThemeColor,
                tokenColors: [PrismTokenType: TokenStyle] = [:]) {
        self.font = font
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.tokenColors = tokenColors
    }

    // MARK: - Resolution

    public func resolvedFont() -> MarkdownFont {
        font.resolved()
    }

    public func resolvedForegroundColor() -> MarkdownColor {
        foregroundColor.resolved()
    }

    public func resolvedBackgroundColor() -> MarkdownColor {
        backgroundColor.resolved()
    }

    // MARK: - Presets

    /// Plain monospaced theme with no syntax coloring.
    public static func monospaced() -> CodeBlockTheme {
        let bodySize: CGFloat
        #if canImport(UIKit)
        bodySize = UIFont.preferredFont(forTextStyle: .body).pointSize
        #else
        bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
        #endif

        return CodeBlockTheme(
            font: FontSpec(size: bodySize, design: .monospaced),
            foregroundColor: .label,
            backgroundColor: .secondaryBackground
        )
    }

    /// Default theme with Prism.js-style syntax coloring.
    /// Colors adapt to light/dark mode.
    public static func prismDefault() -> CodeBlockTheme {
        let bodySize: CGFloat
        #if canImport(UIKit)
        bodySize = UIFont.preferredFont(forTextStyle: .body).pointSize
        #else
        bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
        #endif

        return CodeBlockTheme(
            font: FontSpec(size: bodySize, design: .monospaced),
            foregroundColor: .label,
            backgroundColor: .secondaryBackground,
            tokenColors: defaultTokenColors
        )
    }

    /// GitHub-flavored theme using Primer syntax colors, adapting to
    /// light/dark mode. Matches how github.com renders code blocks.
    public static func gitHub() -> CodeBlockTheme {
        let bodySize: CGFloat
        #if canImport(UIKit)
        bodySize = UIFont.preferredFont(forTextStyle: .body).pointSize
        #else
        bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
        #endif

        return CodeBlockTheme(
            font: FontSpec(size: bodySize, design: .monospaced),
            foregroundColor: hex(0x1F2328, 0xF0F6FC),
            backgroundColor: hex(0xF6F8FA, 0x151B23),
            tokenColors: gitHubTokenColors
        )
    }

    // MARK: - GitHub (Primer) Token Colors

    private static var gitHubTokenColors: [PrismTokenType: TokenStyle] {
        // Primer scale: keyword red, string dark blue, constant blue,
        // function purple, type orange, tag green. Punctuation and operators'
        // neighbors inherit the plain foreground where GitHub leaves them
        // uncolored.
        let keyword = hex(0xCF222E, 0xFF7B72)
        let string = hex(0x0A3069, 0xA5D6FF)
        let comment = hex(0x59636E, 0x9198A1)
        let function = hex(0x8250DF, 0xD2A8FF)
        let constant = hex(0x0550AE, 0x79C0FF)
        let type = hex(0x953800, 0xFFA657)
        let tag = hex(0x116329, 0x7EE787)
        let inserted = hex(0x1A7F37, 0x3FB950)
        let deleted = hex(0x82071E, 0xF85149)

        return [
            // Keywords and keyword-like
            .keyword: TokenStyle(color: keyword),
            .literal: TokenStyle(color: keyword),
            .boolean: TokenStyle(color: keyword),
            .nil: TokenStyle(color: keyword),
            .operator: TokenStyle(color: keyword),
            .important: TokenStyle(color: keyword),
            .atrule: TokenStyle(color: keyword),
            .rule: TokenStyle(color: keyword),
            .preprocessor: TokenStyle(color: keyword),
            .directive: TokenStyle(color: keyword),
            .attribute: TokenStyle(color: keyword),
            .label: TokenStyle(color: keyword),
            .entity: TokenStyle(color: keyword),

            // Strings
            .string: TokenStyle(color: string),
            .char: TokenStyle(color: string),
            .regex: TokenStyle(color: string),
            .url: TokenStyle(color: string),
            .attributeValue: TokenStyle(color: string),

            // Comments
            .comment: TokenStyle(color: comment),
            .blockComment: TokenStyle(color: comment),
            .docComment: TokenStyle(color: comment),
            .prolog: TokenStyle(color: comment),
            .doctype: TokenStyle(color: comment),
            .cdata: TokenStyle(color: comment),

            // Functions
            .function: TokenStyle(color: function),
            .functionName: TokenStyle(color: function),
            .functionDefinition: TokenStyle(color: function),

            // Constants, variables, numbers
            .variable: TokenStyle(color: constant),
            .constant: TokenStyle(color: constant),
            .number: TokenStyle(color: constant),
            .property: TokenStyle(color: constant),
            .symbol: TokenStyle(color: constant),
            .builtin: TokenStyle(color: constant),
            .attributeName: TokenStyle(color: constant),
            .parameter: TokenStyle(color: constant),

            // Types
            .className: TokenStyle(color: type),
            .namespace: TokenStyle(color: type),

            // Markup
            .tag: TokenStyle(color: tag),
            .selector: TokenStyle(color: tag),
            .section: TokenStyle(color: tag),

            // Diff
            .inserted: TokenStyle(color: inserted),
            .deleted: TokenStyle(color: deleted),
        ]
    }

    /// Build a light/dark ThemeColor pair from 0xRRGGBB values.
    private static func hex(_ light: UInt32, _ dark: UInt32) -> ThemeColor {
        func rgba(_ value: UInt32) -> ThemeColor.RGBA {
            ThemeColor.RGBA(
                red: CGFloat((value >> 16) & 0xFF) / 255.0,
                green: CGFloat((value >> 8) & 0xFF) / 255.0,
                blue: CGFloat(value & 0xFF) / 255.0
            )
        }
        return ThemeColor(light: rgba(light), dark: rgba(dark))
    }

    // MARK: - Default Token Colors

    private static var defaultTokenColors: [PrismTokenType: TokenStyle] {
        [
            // Keywords
            .keyword: TokenStyle(color: tc(l: (0.608, 0.138, 0.576), d: (0.988, 0.374, 0.638)), bold: true),
            .builtin: TokenStyle(color: tc(l: (0.225, 0.0, 0.628), d: (0.632, 0.402, 0.901))),
            .literal: TokenStyle(color: tc(l: (0.608, 0.138, 0.576), d: (0.988, 0.374, 0.638)), bold: true),
            .boolean: TokenStyle(color: tc(l: (0.608, 0.138, 0.576), d: (0.988, 0.374, 0.638)), bold: true),

            // Strings and characters
            .string: TokenStyle(color: tc(l: (0.77, 0.102, 0.086), d: (0.989, 0.416, 0.366))),
            .char: TokenStyle(color: tc(l: (0.11, 0.0, 0.81), d: (0.816, 0.749, 0.412))),
            .regex: TokenStyle(color: tc(l: (0.77, 0.102, 0.086), d: (0.989, 0.416, 0.366))),
            .url: TokenStyle(color: tc(l: (0.055, 0.055, 1.0), d: (0.330, 0.511, 0.999))),

            // Numbers
            .number: TokenStyle(color: tc(l: (0.11, 0.0, 0.81), d: (0.815, 0.749, 0.412))),

            // Types and classes
            .className: TokenStyle(color: tc(l: (0.110, 0.273, 0.289), d: (0.620, 0.945, 0.867))),

            // Functions
            .function: TokenStyle(color: tc(l: (0.194, 0.429, 0.455), d: (0.404, 0.718, 0.643))),
            .functionName: TokenStyle(color: tc(l: (0.194, 0.429, 0.455), d: (0.404, 0.718, 0.643))),

            // Variables and properties
            .variable: TokenStyle(color: tc(l: (0.194, 0.429, 0.455), d: (0.405, 0.717, 0.642))),
            .constant: TokenStyle(color: tc(l: (0.194, 0.429, 0.455), d: (0.405, 0.717, 0.642))),
            .property: TokenStyle(color: tc(l: (0.194, 0.429, 0.455), d: (0.405, 0.717, 0.642))),

            // Comments
            .comment: TokenStyle(color: tc(l: (0.365, 0.422, 0.475), d: (0.424, 0.475, 0.525))),
            .blockComment: TokenStyle(color: tc(l: (0.365, 0.422, 0.475), d: (0.424, 0.475, 0.525))),
            .docComment: TokenStyle(color: tc(l: (0.365, 0.422, 0.475), d: (0.424, 0.475, 0.525))),
            .mark: TokenStyle(color: tc(l: (0.290, 0.333, 0.376), d: (0.573, 0.631, 0.694)), bold: true),

            // Preprocessor
            .preprocessor: TokenStyle(color: tc(l: (0.391, 0.220, 0.124), d: (0.991, 0.561, 0.246))),
            .directive: TokenStyle(color: tc(l: (0.391, 0.220, 0.124), d: (0.991, 0.561, 0.246))),

            // Attributes
            .attribute: TokenStyle(color: tc(l: (0.506, 0.371, 0.012), d: (0.749, 0.522, 0.333))),
            .attributeName: TokenStyle(color: tc(l: (0.506, 0.371, 0.012), d: (0.749, 0.522, 0.333))),

            // Markup
            .tag: TokenStyle(color: tc(l: (0.11, 0.0, 0.81), d: (0.816, 0.749, 0.412))),

            // Operators and punctuation
            .operator: TokenStyle(color: tc(l: (0.365, 0.422, 0.475), d: (0.573, 0.631, 0.694))),
            .punctuation: TokenStyle(color: tc(l: (0.365, 0.422, 0.475), d: (0.573, 0.631, 0.694))),

            // Diff
            .inserted: TokenStyle(color: tc(l: (0.204, 0.780, 0.349), d: (0.188, 0.820, 0.345))),
            .deleted: TokenStyle(color: tc(l: (1.0, 0.220, 0.235), d: (1.0, 0.259, 0.271))),
        ]
    }

    /// Short helper to build a ThemeColor from light/dark RGB tuples.
    private static func tc(l: (CGFloat, CGFloat, CGFloat), d: (CGFloat, CGFloat, CGFloat)) -> ThemeColor {
        ThemeColor(
            light: .init(red: l.0, green: l.1, blue: l.2),
            dark: .init(red: d.0, green: d.1, blue: d.2)
        )
    }
}
