import Foundation
import os

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Token

struct PrismToken: Hashable, Sendable {
    let content: String
    let type: PrismTokenType
    /// Prism's standardized alias for grammar-specific types (e.g. INI `key`
    /// aliases `attr-name`), used as a theme-color fallback.
    let alias: PrismTokenType?

    init(content: String, type: PrismTokenType, alias: PrismTokenType? = nil) {
        self.content = content
        self.type = type
        self.alias = alias
    }
}

// MARK: - Tokenizer Actor

#if canImport(JavaScriptCore)
actor PrismTokenizer {
    private struct CacheKey: Hashable {
        let language: String
        let code: String
    }

    private let context: JSContext
    /// Closed blocks re-render verbatim on width changes and out-of-band
    /// refreshes (e.g. image prefetch); a small LRU avoids re-tokenizing
    /// identical (language, code) pairs. Keys share storage with the
    /// caller's strings (copy-on-write), so the footprint is the map itself.
    private var cache: [CacheKey: [PrismToken]] = [:]
    private var cacheOrder: [CacheKey] = []
    private let cacheLimit = 16
    private static let logger = Logger(
        subsystem: "com.picomarkdown",
        category: "PrismTokenizer"
    )

    static let shared: PrismTokenizer? = PrismTokenizer()

    private init?() {
        guard let context = JSContext() else {
            Self.logger.error("JavaScriptCore is not available.")
            return nil
        }

        guard
            let bundleURL = Bundle.module.url(
                forResource: "prism-bundle",
                withExtension: "js"
            ),
            let script = try? String(contentsOf: bundleURL, encoding: .utf8)
        else {
            Self.logger.error("Prism JavaScript bundle is missing.")
            return nil
        }

        context.evaluateScript(script)
        self.context = context
    }

    func tokenize(code: String, language: String) -> [PrismToken] {
        let key = CacheKey(language: language, code: code)
        if let cached = cache[key] {
            if let index = cacheOrder.firstIndex(of: key) {
                cacheOrder.remove(at: index)
                cacheOrder.append(key)
            }
            return cached
        }

        guard
            let tokenizeCode = context.objectForKeyedSubscript("tokenizeCode"),
            let result = tokenizeCode.call(withArguments: [code, language]),
            let array = result.toArray() as? [[String: String]]
        else {
            Self.logger.error("Tokenization failed for language: \(language)")
            return [PrismToken(content: code, type: .plain)]
        }

        let tokens = parseTokens(array)
        cache[key] = tokens
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return tokens
    }

    private func parseTokens(_ array: [[String: String]]) -> [PrismToken] {
        array.compactMap { token in
            guard
                let content = token["content"],
                let type = token["type"]
            else {
                return nil
            }
            return PrismToken(content: content,
                              type: .init(rawValue: type),
                              alias: token["alias"].map { .init(rawValue: $0) })
        }
    }
}
#else
actor PrismTokenizer {
    static let shared: PrismTokenizer? = nil

    func tokenize(code: String, language: String) -> [PrismToken] {
        [PrismToken(content: code, type: .plain)]
    }
}
#endif

// MARK: - CodeSyntaxHighlighter Implementation

/// A syntax highlighter that uses Prism.js via JavaScriptCore to tokenize code
/// and applies per-token-type colors from the `CodeBlockTheme`.
///
/// The fence info string is normalized before grammar lookup (first word,
/// lowercased, common aliases such as `c++` → `cpp` — see
/// `PrismLanguageNormalizer`); unknown languages render as plain text.
///
/// Thread-safe: tokenization runs on the `PrismTokenizer` actor, off the
/// main actor. Tokenization re-runs as a streaming block grows;
/// `MarkdownAttributeBuilder` defers oversized blocks to a single pass when
/// the fence closes (see `CodeHighlightingPolicy`).
public struct PrismCodeHighlighter: CodeSyntaxHighlighter {
    public init() {}

    public func highlight(_ code: String, language: String?, theme: CodeBlockTheme) async -> AttributedString {
        guard let language = PrismLanguageNormalizer.normalize(language) else {
            return plainHighlight(code, theme: theme)
        }

        guard let tokenizer = PrismTokenizer.shared else {
            return plainHighlight(code, theme: theme)
        }

        let tokens = await tokenizer.tokenize(code: code, language: language)

        guard !tokens.isEmpty else {
            return plainHighlight(code, theme: theme)
        }

        return applyTokenColors(tokens: tokens, theme: theme)
    }

    private func plainHighlight(_ code: String, theme: CodeBlockTheme) -> AttributedString {
        let resolvedFont = theme.resolvedFont()
        let resolvedColor = theme.resolvedForegroundColor()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: resolvedFont,
            .foregroundColor: resolvedColor
        ]
        let nsString = NSAttributedString(string: code, attributes: attributes)
        return AttributedString(nsString)
    }

    private func applyTokenColors(tokens: [PrismToken], theme: CodeBlockTheme) -> AttributedString {
        let result = NSMutableAttributedString()
        let tokenColors = theme.tokenColors
        let resolvedFont = theme.resolvedFont()
        let resolvedFg = theme.resolvedForegroundColor()

        for token in tokens {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: resolvedFont,
                .foregroundColor: resolvedFg
            ]

            if let tokenStyle = tokenColors[token.type] ?? token.alias.flatMap({ tokenColors[$0] }) {
                if let color = tokenStyle.color {
                    attributes[.foregroundColor] = color.resolved()
                }
                if tokenStyle.bold {
                    attributes[.font] = boldVariant(of: resolvedFont)
                }
                if tokenStyle.italic {
                    attributes[.font] = italicVariant(of: (attributes[.font] as? MarkdownFont) ?? resolvedFont)
                }
            }

            result.append(NSAttributedString(string: token.content, attributes: attributes))
        }

        return AttributedString(result)
    }

    private func boldVariant(of font: MarkdownFont) -> MarkdownFont {
        #if canImport(UIKit)
        if let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        return UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
        #else
        var traits = font.fontDescriptor.symbolicTraits
        traits.insert(.bold)
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #endif
    }

    private func italicVariant(of font: MarkdownFont) -> MarkdownFont {
        #if canImport(UIKit)
        if let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        return font
        #else
        var traits = font.fontDescriptor.symbolicTraits
        traits.insert(.italic)
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #endif
    }
}
