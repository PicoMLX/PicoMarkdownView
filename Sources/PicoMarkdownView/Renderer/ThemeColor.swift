import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A Sendable color specification with light/dark variants.
///
/// Stores RGBA values directly (all `Sendable`) and resolves to a dynamic
/// platform color at render time. The resolved color responds to appearance
/// changes (light/dark mode) automatically.
public struct ThemeColor: Sendable, Hashable {
    public struct RGBA: Sendable, Hashable {
        public let red: CGFloat
        public let green: CGFloat
        public let blue: CGFloat
        public let alpha: CGFloat

        public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1.0) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    public let light: RGBA
    public let dark: RGBA

    public init(light: RGBA, dark: RGBA) {
        self.light = light
        self.dark = dark
    }

    /// Single-color (non-adaptive). Same in light and dark mode.
    public init(_ rgba: RGBA) {
        self.light = rgba
        self.dark = rgba
    }

    /// Resolve to a platform color that dynamically adapts to appearance.
    public func resolved() -> MarkdownColor {
        #if canImport(UIKit)
        return UIColor { [light, dark] traitCollection in
            let rgba = traitCollection.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        }
        #else
        let light = self.light
        let dark = self.dark
        return NSColor(name: nil) { appearance in
            let rgba = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        }
        #endif
    }
}

// MARK: - Convenience Initializers

extension ThemeColor {
    /// Create from platform colors by extracting RGBA components.
    public init(light: MarkdownColor, dark: MarkdownColor) {
        self.light = RGBA(platformColor: light)
        self.dark = RGBA(platformColor: dark)
    }

    /// Create a non-adaptive color from a platform color.
    public init(_ color: MarkdownColor) {
        let rgba = RGBA(platformColor: color)
        self.light = rgba
        self.dark = rgba
    }
}

extension ThemeColor.RGBA {
    init(platformColor: MarkdownColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        platformColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let converted = platformColor.usingColorSpace(.sRGB) ?? platformColor
        converted.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - Predefined System-Like Colors

extension ThemeColor {
    /// Primary label text color.
    public static let label = ThemeColor(
        light: RGBA(red: 0, green: 0, blue: 0),
        dark: RGBA(red: 1, green: 1, blue: 1)
    )

    /// Secondary label text color.
    public static let secondaryLabel = ThemeColor(
        light: RGBA(red: 0.235, green: 0.235, blue: 0.263, alpha: 0.6),
        dark: RGBA(red: 0.922, green: 0.922, blue: 0.961, alpha: 0.6)
    )

    /// System blue (link color).
    public static let link = ThemeColor(
        light: RGBA(red: 0.0, green: 0.478, blue: 1.0),
        dark: RGBA(red: 0.039, green: 0.518, blue: 1.0)
    )

    /// Separator color.
    public static let separator = ThemeColor(
        light: RGBA(red: 0.235, green: 0.235, blue: 0.263, alpha: 0.29),
        dark: RGBA(red: 0.329, green: 0.329, blue: 0.345, alpha: 0.6)
    )

    /// Secondary background.
    public static let secondaryBackground = ThemeColor(
        light: RGBA(red: 0.949, green: 0.949, blue: 0.969),
        dark: RGBA(red: 0.110, green: 0.110, blue: 0.118)
    )

    /// Primary background.
    public static let background = ThemeColor(
        light: RGBA(red: 1, green: 1, blue: 1),
        dark: RGBA(red: 0, green: 0, blue: 0)
    )

    /// Table header background.
    public static let tableHeaderBackground = ThemeColor(
        light: RGBA(red: 0.949, green: 0.949, blue: 0.969),
        dark: RGBA(red: 0.173, green: 0.173, blue: 0.180)
    )

    /// Table row background.
    public static let tableRowBackground = ThemeColor(
        light: RGBA(red: 1, green: 1, blue: 1),
        dark: RGBA(red: 0.110, green: 0.110, blue: 0.118)
    )

    /// Keyboard background.
    public static let keyboardBackground = ThemeColor(
        light: RGBA(red: 0.898, green: 0.898, blue: 0.918),
        dark: RGBA(red: 0.227, green: 0.227, blue: 0.235)
    )

    /// Blockquote accent.
    public static let blockquote = ThemeColor(
        light: RGBA(red: 0.235, green: 0.235, blue: 0.263, alpha: 0.6),
        dark: RGBA(red: 0.922, green: 0.922, blue: 0.961, alpha: 0.6)
    )

    /// Transparent.
    public static let clear = ThemeColor(RGBA(red: 0, green: 0, blue: 0, alpha: 0))
}
