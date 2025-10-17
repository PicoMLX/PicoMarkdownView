import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct CodeBlockTheme: @unchecked Sendable {
    public var font: MarkdownFont
    public var foregroundColor: MarkdownColor
    public var backgroundColor: MarkdownColor

    public init(font: MarkdownFont,
                foregroundColor: MarkdownColor,
                backgroundColor: MarkdownColor) {
        self.font = font
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }

    public static func monospaced() -> CodeBlockTheme {
#if canImport(UIKit)
        let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        let foreground = UIColor.label
        let background = UIColor.secondarySystemBackground
#else
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        let foreground = NSColor.labelColor
        let background = NSColor.windowBackgroundColor
#endif
        return CodeBlockTheme(font: font,
                              foregroundColor: foreground,
                              backgroundColor: background)
    }
}
