import Foundation
@preconcurrency import Splash

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct CodeBlockPalette: Sendable {
    public var foregroundColor: MarkdownColor
    public var backgroundColor: MarkdownColor

    public init(foregroundColor: MarkdownColor, backgroundColor: MarkdownColor) {
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }
}

public struct CodeBlockThemeProvider {
    public typealias ThemeFactory = (_ codeFont: MarkdownFont) -> Theme

    private let lightFactory: ThemeFactory
    private let darkFactory: ThemeFactory

    public init(light: @escaping ThemeFactory, dark: @escaping ThemeFactory) {
        self.lightFactory = light
        self.darkFactory = dark
    }

    public init(lightTheme: Theme, darkTheme: Theme) {
        self.init(light: { _ in lightTheme }, dark: { _ in darkTheme })
    }

    public static func system() -> CodeBlockThemeProvider {
        CodeBlockThemeProvider { codeFont in
            Theme.presentation(withFont: Splash.Font.fromMarkdownFont(codeFont))
        } dark: { codeFont in
            Theme.midnight(withFont: Splash.Font.fromMarkdownFont(codeFont))
        }
    }

    public func makePalette(codeFont: MarkdownFont) -> CodeBlockPalette {
        let lightTheme = lightFactory(codeFont)
        let darkTheme = darkFactory(codeFont)

        let foreground = dynamicPlatformColor(light: lightTheme.plainTextColor, dark: darkTheme.plainTextColor)
        let background = dynamicPlatformColor(light: lightTheme.backgroundColor, dark: darkTheme.backgroundColor)

        return CodeBlockPalette(foregroundColor: foreground, backgroundColor: background)
    }
}

private func dynamicPlatformColor(light: MarkdownColor, dark: MarkdownColor) -> MarkdownColor {
#if canImport(UIKit)
    return MarkdownColor { traits in
        traits.userInterfaceStyle == .dark ? dark : light
    }
#elseif canImport(AppKit)
    if #available(macOS 10.15, *) {
        return MarkdownColor(name: nil) { appearance in
            let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
            return bestMatch == .darkAqua ? dark : light
        }
    } else {
        return light
    }
#else
    return light
#endif
}

private extension Splash.Font {
    static func fromMarkdownFont(_ font: MarkdownFont) -> Splash.Font {
        var splashFont = Splash.Font(size: Double(font.pointSize))
        splashFont.resource = .preloaded(font)
        return splashFont
    }
}
