#if os(macOS)
import Foundation
import libxml2

nonisolated struct HTMLPreviewStyle: Sendable, Equatable {
    var fontSize: Double
    var fontFamily: String
    var foregroundCSS: String
    var backgroundCSS: String
    var isDark: Bool

    static let `default` = Self(fontSize: 15, fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif",
                                foregroundCSS: "#000000", backgroundCSS: "transparent", isDark: false)
}

nonisolated struct HTMLPreviewDocument: Sendable, Equatable {
    let html: String
    let plainText: String
}

/// Sanitized, style-independent HTML. No parser or DOM object is retained or
/// transferred across actors; appearance changes only compose a new shell.
nonisolated struct HTMLPreparedContent: Sendable, Equatable {
    fileprivate let bodyHTML: String
    fileprivate let authorStylesHTML: String
    fileprivate let bodyAttributesHTML: String
    fileprivate let bodyStyleHTML: String
    fileprivate let documentAttributesHTML: String
    let plainText: String

    func document(style: HTMLPreviewStyle = .default) -> HTMLPreviewDocument {
        HTMLPreviewPolicy.document(content: self, style: style)
    }
}

nonisolated enum HTMLPreviewPolicyError: Error, Equatable {
    case sourceTooLarge
    case unsupportedDeclaration
    case invalidHTML
    case documentTooComplex
    case emptyContent
}

/// Builds an offline, static preview. The caller retains the original source
/// for selection/copying and falls back to that source when preparation fails.
/// WebKit's script, navigation and network restrictions remain independent
/// defenses; this policy never forwards the author's document shell.
nonisolated enum HTMLPreviewPolicy {
    static let maximumSourceBytes = 128 * 1024
    static let maximumNodeCount = 4_096
    static let maximumDepth = 64
    static let minimumHeight: CGFloat = 1
    static let maximumHeight: CGFloat = 4_096
    static let contentSecurityPolicy = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src 'none'; font-src 'none'; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"

    static func prepare(source: String) throws -> HTMLPreparedContent {
        guard source.utf8.count <= maximumSourceBytes else { throw HTMLPreviewPolicyError.sourceTooLarge }
        // An HTML preview has no use for entity declarations. Reject them
        // before parsing so even internal expansion cannot amplify the input.
        guard !source.contains("\0"), source.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            throw HTMLPreviewPolicyError.unsupportedDeclaration
        }
        let document = try parseHTML(source)
        guard let root = document.rootElement() else { throw HTMLPreviewPolicyError.invalidHTML }
        var nodeCount = 0
        try validateComplexity(root, depth: 0, count: &nodeCount)
        var builder = Builder()
        let body = try builder.render(root)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HTMLPreviewPolicyError.emptyContent
        }
        let bodyAttributes = builder.bodyAttributes.filter { $0.0 != "style" }
        let authorBodyStyle = builder.bodyAttributes.first { $0.0 == "style" }?.1 ?? ""
        // The outer HTML viewport clips the measured preview. Forcing body
        // clipping would hide valid overflow when the author fixes its height.
        let bodyStyle = authorBodyStyle + ";margin:0!important"
        let styles = builder.styles.map { stylesheet in
            let media = stylesheet.media.map { attributesHTML([("media", $0)]) } ?? ""
            return "<style" + media + ">" + escapeCSSRawText(stylesheet.css) + "</style>"
        }.joined()
        return HTMLPreparedContent(
            bodyHTML: body,
            authorStylesHTML: styles,
            bodyAttributesHTML: attributesHTML(bodyAttributes),
            bodyStyleHTML: escapeAttribute(bodyStyle),
            documentAttributesHTML: attributesHTML(builder.documentAttributes),
            plainText: String(builder.plainText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16_384))
        )
    }

    @concurrent
    static func prepareOffMainActor(source: String,
                                    onPreparationStarted: (@Sendable () -> Void)? = nil) async throws -> HTMLPreparedContent {
        try Task.checkCancellation()
        onPreparationStarted?()
        let content = try prepare(source: source)
        try Task.checkCancellation()
        return content
    }

    fileprivate static func document(content: HTMLPreparedContent, style: HTMLPreviewStyle) -> HTMLPreviewDocument {
        let fontSize = style.fontSize.isFinite ? min(96, max(8, style.fontSize)) : 15
        let family = safeFontFamily(style.fontFamily)
        let foreground = safeColor(style.foregroundCSS, fallback: style.isDark ? "#ffffff" : "#000000")
        let background = safeColor(style.backgroundCSS, fallback: "transparent")
        // Contain ordinary block margins without overriding author flex/grid.
        let baseCSS = """
        html { color-scheme: \(style.isDark ? "dark" : "light"); }
        body { display: flow-root; margin: 0; font: \(fontSize)px \(family); color: \(foreground); background-color: \(background); overflow-wrap: anywhere; }
        pre { white-space: pre-wrap; } table { max-width: 100%; } th, td { overflow-wrap: anywhere; }
        """
        let staticCSS = "*, *::before, *::after { animation: none !important; transition: none !important; scroll-behavior: auto !important; }"
        let html = """
        <!doctype html><html\(content.documentAttributesHTML) style="margin:0!important;overflow:hidden!important"><head><meta http-equiv="Content-Security-Policy" content="\(escapeAttribute(contentSecurityPolicy))"><meta charset="utf-8"><title>HTML preview</title><style>\(baseCSS)</style>\(content.authorStylesHTML)<style data-pico-static-motion="">\(staticCSS)</style></head><body\(content.bodyAttributesHTML) style="\(content.bodyStyleHTML)">\(content.bodyHTML)</body></html>
        """
        return HTMLPreviewDocument(html: html, plainText: content.plainText)
    }

    private static func parseHTML(_ source: String) throws -> XMLDocument {
        // Foundation's TidyHTML drops HTML5 containers and their attributes.
        // The platform HTML parser preserves them, repairs malformed markup,
        // and does not load external DTDs. NONET additionally forbids network IO.
        let options = Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue)
        guard let parsed = source.withCString({ htmlReadMemory($0, Int32(source.utf8.count), nil, "UTF-8", options) }) else {
            throw HTMLPreviewPolicyError.invalidHTML
        }
        defer { xmlFreeDoc(parsed) }
        guard let buffer = xmlBufferCreate() else { throw HTMLPreviewPolicyError.invalidHTML }
        defer { xmlBufferFree(buffer) }
        let saveOptions = Int32(XML_SAVE_AS_XML.rawValue | XML_SAVE_NO_DECL.rawValue)
        guard let writer = xmlSaveToBuffer(buffer, "UTF-8", saveOptions) else { throw HTMLPreviewPolicyError.invalidHTML }
        // Serialize only the element tree, discarding the author's DTD before
        // Foundation sees it. The buffer owns its bytes and frees them with
        // libxml's matching allocator, without reading its mutable xmlFree hook.
        let written = xmlSaveTree(writer, xmlDocGetRootElement(parsed))
        let closed = xmlSaveClose(writer)
        guard written >= 0, closed >= 0, let bytes = xmlBufferContent(buffer), xmlBufferLength(buffer) > 0 else {
            throw HTMLPreviewPolicyError.invalidHTML
        }
        let count = Int(xmlBufferLength(buffer))
        do {
            // This second parse only reads the repaired, escaped XML tree;
            // never loading external entities also excludes local DTD files.
            let xml = String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
            return try XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever])
        } catch {
            throw HTMLPreviewPolicyError.invalidHTML
        }
    }

    private static func validateComplexity(_ node: XMLNode, depth: Int, count: inout Int) throws {
        count += 1
        guard depth <= maximumDepth, count <= maximumNodeCount else { throw HTMLPreviewPolicyError.documentTooComplex }
        for child in node.children ?? [] { try validateComplexity(child, depth: depth + 1, count: &count) }
    }

    private static func safeFontFamily(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: ";{}<>\\\r\n\0")
        guard value.utf8.count <= 256, !value.isEmpty, value.rangeOfCharacter(from: forbidden) == nil else {
            return HTMLPreviewStyle.default.fontFamily
        }
        return value
    }

    private static func safeColor(_ value: String, fallback: String) -> String {
        let color = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if color.hasPrefix("#") {
            let digits = color.dropFirst()
            if [3, 4, 6, 8].contains(digits.count), digits.allSatisfy({ $0.isHexDigit && $0.isASCII }) { return color }
        }
        if ["transparent", "currentcolor", "black", "white", "canvas", "canvastext"].contains(color) { return color }
        if ["rgb(", "rgba(", "hsl(", "hsla("].contains(where: color.hasPrefix), color.hasSuffix(")"), color.utf8.count <= 128,
           let opening = color.firstIndex(of: "(") {
            let components = color[color.index(after: opening)..<color.index(before: color.endIndex)]
            let allowed = CharacterSet(charactersIn: "0123456789.,% /+-")
            if !components.isEmpty, components.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return color }
        }
        return fallback
    }

    private static func escapeText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeText(value).replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func escapeCSSRawText(_ value: String) -> String {
        // Only an appropriate HTML end tag can terminate style raw text.
        // Escaping every '<' would instead turn CSS range operators into
        // identifiers. A CSS escape keeps string/comment content inert while
        // preserving ordinary comparisons and the matched tag's original case.
        value.replacingOccurrences(
            of: #"<(?=/style(?:[\t\n\f\r />]|$))"#,
            with: NSRegularExpression.escapedTemplate(for: #"\3C "#),
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func attributesHTML(_ attributes: [(String, String)]) -> String {
        attributes.map { " " + $0.0 + "=\"" + escapeAttribute($0.1) + "\"" }.joined()
    }

    private struct Builder {
        private static let allowedTags: Set<String> = [
            "a", "abbr", "address", "article", "aside", "b", "bdi", "bdo", "blockquote", "br", "caption", "cite",
            "code", "col", "colgroup", "dd", "del", "dfn", "div", "dl", "dt", "em", "figcaption", "figure", "footer",
            "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "i", "ins", "kbd", "li", "main", "mark", "nav",
            "ol", "p", "pre", "q", "s", "samp", "section", "small", "span", "strong", "sub", "sup", "table",
            "tbody", "td", "tfoot", "th", "thead", "time", "tr", "u", "ul", "var", "wbr"
        ]
        private static let blockTags: Set<String> = [
            "address", "article", "aside", "blockquote", "caption", "dd", "div", "dl", "dt", "figcaption", "figure", "footer",
            "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section",
            "table", "tbody", "tfoot", "thead", "tr", "ul"
        ]
        private static let voidTags: Set<String> = ["br", "col", "hr", "wbr"]
        private static let globalAttributes: Set<String> = ["class", "id", "title", "lang", "dir", "style", "role", "aria-label"]
        struct Stylesheet {
            let css: String
            let media: String?
        }
        var styles: [Stylesheet] = []
        var plainText = ""
        var bodyAttributes: [(String, String)] = []
        var documentAttributes: [(String, String)] = []

        mutating func render(_ node: XMLNode) throws -> String {
            if node.kind == .text {
                let text = node.stringValue ?? ""
                plainText += text
                return escapeText(text)
            }
            guard let element = node as? XMLElement, let name = element.name?.lowercased() else { return "" }
            if name == "style" {
                collectStyle(element)
                return ""
            }
            if name == "head" {
                collectHeadStyles(element)
                return ""
            }
            // Hidden visual subtrees must stay absent from both the preview
            // and its cached readable placeholder. Styles still participate
            // in the cascade even when their containing content is hidden.
            if element.attribute(forName: "hidden") != nil {
                collectHiddenStyles(element)
                return ""
            }
            if name == "html" || name == "body" {
                if name == "html" {
                    // Keep selector/language semantics in the app-owned shell;
                    // author root styles, events and resource attributes stay out.
                    documentAttributes = safeAttributes(of: element, name: name).filter {
                        ["class", "id", "lang", "dir"].contains($0.0)
                    }
                } else {
                    bodyAttributes = safeAttributes(of: element, name: name)
                }
                return try (element.children ?? []).map { try render($0) }.joined()
            }
            if name == "img" {
                let alt = element.attribute(forName: "alt")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let placeholder = alt.isEmpty ? "[Image omitted]" : "[Image: \(alt)]"
                plainText += placeholder
                return "<span>" + escapeText(placeholder) + "</span>"
            }
            // Dropping unknown and active subtrees also excludes SVG/MathML
            // foreign-content parsing, templates, forms and raw-text elements.
            guard Self.allowedTags.contains(name) else { return "" }
            if Self.blockTags.contains(name) || name == "br" { plainText += "\n" }
            let attributes = safeAttributes(of: element, name: name)
            let opening = "<" + name + attributesHTML(attributes) + ">"
            let children = try (element.children ?? []).map { try render($0) }.joined()
            if Self.blockTags.contains(name) { plainText += "\n" }
            if name == "td" || name == "th" { plainText += "\t" }
            return opening + children + (Self.voidTags.contains(name) ? "" : "</\(name)>")
        }

        private mutating func collectStyle(_ element: XMLElement) {
            // HTML's style-block algorithm uses an exact ASCII-insensitive
            // match, not MIME parsing or whitespace trimming. Inert data must
            // not become active CSS when composed into our document shell.
            if let type = element.attribute(forName: "type")?.stringValue,
               !type.isEmpty,
               !(type.utf8.allSatisfy { $0 < 0x80 } && type.lowercased() == "text/css") {
                return
            }
            let media = element.attribute(forName: "media")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            styles.append(Stylesheet(css: element.stringValue ?? "", media: media.flatMap { $0.isEmpty ? nil : $0 }))
        }

        private mutating func collectHeadStyles(_ element: XMLElement) {
            for child in element.children ?? [] {
                guard let child = child as? XMLElement else { continue }
                if child.name?.lowercased() == "style" { collectStyle(child) }
            }
        }

        private mutating func collectHiddenStyles(_ element: XMLElement) {
            guard let name = element.name?.lowercased() else { return }
            if name == "style" {
                collectStyle(element)
                return
            }
            if name == "head" {
                collectHeadStyles(element)
                return
            }
            // Match normal rendering's subtree boundary: active, foreign,
            // template and unknown containers never contribute styles.
            guard name == "html" || name == "body" || Self.allowedTags.contains(name) else { return }
            for child in element.children ?? [] {
                if let child = child as? XMLElement { collectHiddenStyles(child) }
            }
        }

        private func safeAttributes(of element: XMLElement, name: String) -> [(String, String)] {
            (element.attributes ?? []).compactMap { attribute -> (String, String)? in
                guard let key = attribute.name?.lowercased(), let value = attribute.stringValue else { return nil }
                if Self.globalAttributes.contains(key) {
                    if key == "dir", !["ltr", "rtl", "auto"].contains(value.lowercased()) { return nil }
                    return (key, value)
                }
                // Boolean attributes depend on presence, including values
                // such as reversed="false". Keep this scoped to ordered lists.
                if name == "ol", key == "reversed" { return (key, "") }
                if ["td", "th"].contains(name), ["colspan", "rowspan"].contains(key), let number = Int(value), (1...100).contains(number) {
                    return (key, String(number))
                }
                if name == "th", key == "scope", ["row", "col", "rowgroup", "colgroup"].contains(value.lowercased()) { return (key, value) }
                if (name == "ol" && key == "start") || (name == "li" && key == "value"), let number = Int(value), (-10_000...10_000).contains(number) {
                    return (key, String(number))
                }
                return nil
            }.sorted { $0.0 < $1.0 }
        }
    }
}
#endif
