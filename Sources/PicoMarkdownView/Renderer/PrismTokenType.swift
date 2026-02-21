import Foundation

/// Identifies a syntax token type produced by the Prism.js highlighter.
///
/// Token types are backed by a raw string matching Prism.js output.
/// Use the predefined constants for common token types or create custom ones from raw values.
public struct PrismTokenType: Hashable, RawRepresentable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }
}

// MARK: - Predefined Token Types

extension PrismTokenType {
    // General purpose
    public static let plain: Self = "plain"
    public static let keyword: Self = "keyword"
    public static let builtin: Self = "builtin"
    public static let className: Self = "class-name"
    public static let function: Self = "function"
    public static let boolean: Self = "boolean"
    public static let number: Self = "number"
    public static let string: Self = "string"
    public static let char: Self = "char"
    public static let symbol: Self = "symbol"
    public static let regex: Self = "regex"
    public static let url: Self = "url"
    public static let `operator`: Self = "operator"
    public static let variable: Self = "variable"
    public static let constant: Self = "constant"
    public static let property: Self = "property"
    public static let punctuation: Self = "punctuation"
    public static let important: Self = "important"
    public static let comment: Self = "comment"

    // Markup
    public static let tag: Self = "tag"
    public static let attributeName: Self = "attr-name"
    public static let attributeValue: Self = "attr-value"
    public static let namespace: Self = "namespace"
    public static let prolog: Self = "prolog"
    public static let doctype: Self = "doctype"
    public static let cdata: Self = "cdata"
    public static let entity: Self = "entity"

    // CSS
    public static let atrule: Self = "atrule"
    public static let selector: Self = "selector"

    // Diff
    public static let inserted: Self = "inserted"
    public static let deleted: Self = "deleted"

    // Comments (specialized)
    public static let blockComment: Self = "block-comment"
    public static let docComment: Self = "doc-comment"
    public static let mark: Self = "mark"

    // Functions (specialized)
    public static let functionName: Self = "function-name"

    // Preprocessor
    public static let preprocessor: Self = "preprocessor"

    // Swift-specific
    public static let directive: Self = "directive"
    public static let literal: Self = "literal"
    public static let attribute: Self = "attribute"
    public static let functionDefinition: Self = "function-definition"
    public static let label: Self = "label"
    public static let `nil`: Self = "nil"
    public static let shortArgument: Self = "short-argument"
    public static let interpolation: Self = "interpolation"
    public static let interpolationPunctuation: Self = "interpolation-punctuation"
}
