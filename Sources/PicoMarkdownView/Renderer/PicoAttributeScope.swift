import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Typed keys for PicoMarkdownView's custom attributes.
///
/// `AttributedString`'s plain conversion initializers silently drop any
/// `NSAttributedString.Key` that isn't part of a registered attribute scope.
/// The rendering pipeline converts between `NSAttributedString` and
/// `AttributedString` at its seams, so every conversion that must keep these
/// attributes goes through the `picoConverted(from:)` helpers below.

/// 1-based blockquote nesting level (see `BlockquoteBarDecoration`).
enum PicoBlockquoteLevelAttribute: ObjectiveCConvertibleAttributedStringKey {
    typealias Value = Int
    typealias ObjectiveCValue = NSNumber
    static let name = NSAttributedString.Key.picoBlockquoteLevel.rawValue

    static func objectiveCValue(for value: Int) throws -> NSNumber {
        NSNumber(value: value)
    }

    static func value(for object: NSNumber) throws -> Int {
        object.intValue
    }
}

/// Platform color for drawn blockquote bars.
enum PicoBlockquoteBarColorAttribute: ObjectiveCConvertibleAttributedStringKey {
    typealias Value = MarkdownColor
    typealias ObjectiveCValue = MarkdownColor
    static let name = NSAttributedString.Key.picoBlockquoteBarColor.rawValue

    static func objectiveCValue(for value: MarkdownColor) throws -> MarkdownColor {
        value
    }

    static func value(for object: MarkdownColor) throws -> MarkdownColor {
        object
    }
}

extension AttributeScopes {
    /// PicoMarkdownView's attribute scope: the custom keys plus the platform
    /// and Foundation scopes, so scoped conversions keep standard attributes
    /// (fonts, colors, paragraph styles, links, attachments) as well.
    struct PicoMarkdownAttributes: AttributeScope {
        let blockquoteLevel: PicoBlockquoteLevelAttribute
        let blockquoteBarColor: PicoBlockquoteBarColorAttribute
        #if canImport(UIKit)
        let uiKit: UIKitAttributes
        #elseif canImport(AppKit)
        let appKit: AppKitAttributes
        #endif
        let foundation: FoundationAttributes
    }

    var picoMarkdown: PicoMarkdownAttributes.Type { PicoMarkdownAttributes.self }
}

extension AttributedString {
    /// Conversion that preserves PicoMarkdownView's custom attributes.
    static func picoConverted(from attributed: NSAttributedString) -> AttributedString {
        (try? AttributedString(attributed, including: \.picoMarkdown)) ?? AttributedString(attributed)
    }
}

extension NSAttributedString {
    /// Conversion that preserves PicoMarkdownView's custom attributes.
    static func picoConverted(from content: AttributedString) -> NSAttributedString {
        (try? NSAttributedString(content, including: \.picoMarkdown)) ?? NSAttributedString(content)
    }
}
