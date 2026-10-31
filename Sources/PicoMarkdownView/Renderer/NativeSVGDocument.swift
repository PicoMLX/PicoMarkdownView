#if os(macOS)
import AppKit
import Foundation

/// A self-contained, static SVG decoded by AppKit's vector image renderer.
/// This deliberately excludes browser content, filters and external resources;
/// callers keep those blocks as source instead of displaying an incomplete image.
@MainActor
final class NativeSVGDocument {
    let width: CGFloat
    let height: CGFloat
    let accessibilityDescription: String?
    private let image: NSImage

    init?(svg: String) {
        guard svg.utf8.count <= 1_048_576,
              !svg.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !svg.localizedCaseInsensitiveContains("<!ENTITY") else { return nil }
        let data = Data(svg.utf8)
        let validation = StaticSVGValidation()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = validation
        guard parser.parse(), validation.isValid,
              let imageData = Self.normalizedImageData(data),
              let image = NSImage(data: imageData),
              Self.validDimension(image.size.width), Self.validDimension(image.size.height) else { return nil }
        // Replay the vector representation at the current zoom instead of
        // caching a bitmap at the SVG's original dimensions.
        image.cacheMode = .never
        self.image = image
        width = image.size.width
        height = image.size.height
        accessibilityDescription = validation.accessibilityDescription
    }

    /// Uses the canvas's existing top-left coordinate system at intrinsic size.
    func draw(in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private static func normalizedImageData(_ data: Data) -> Data? {
        // CoreSVG on macOS 27 misreads valid quoted fragment URLs as black.
        // Normalize only CSS/attribute values in the display representation;
        // the caller's source and visible text nodes remain untouched.
        guard let regex = try? NSRegularExpression(pattern: #"(?i)url\s*\(\s*(['"])\s*(#[^'"()\s]+)\s*\1\s*\)"#),
              let source = String(data: data, encoding: .utf8) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard regex.numberOfMatches(in: source, range: range) > 0 else { return data }
        guard let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace]),
              let root = document.rootElement() else { return nil }
        func normalized(_ value: String) -> String {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.stringByReplacingMatches(in: value, range: range, withTemplate: "url($2)")
        }
        func visit(_ element: XMLElement) {
            for attribute in element.attributes ?? [] {
                if let value = attribute.stringValue { attribute.stringValue = normalized(value) }
            }
            if element.localName == "style", let value = element.stringValue {
                element.stringValue = normalized(value)
            } else {
                for child in element.children ?? [] {
                    if let child = child as? XMLElement { visit(child) }
                }
            }
        }
        visit(root)
        return document.xmlData
    }

    private static func validDimension(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0 && value <= 1_000_000
    }
}

/// Validates the document envelope, not SVG geometry or CSS layout. AppKit owns
/// those grammars. Only fragment references are permitted, including in CSS.
private final class StaticSVGValidation: NSObject, XMLParserDelegate {
    private static let elements: Set<String> = [
        "svg", "g", "defs", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
        "text", "tspan", "textPath", "title", "desc", "style", "linearGradient", "radialGradient",
        "stop", "clipPath", "mask", "pattern", "marker", "symbol", "use"
    ]
    private static let svgNamespace = "http://www.w3.org/2000/svg"
    private static let comments = try? NSRegularExpression(pattern: #"/\*[\s\S]*?\*/"#)
    private static let urls = try? NSRegularExpression(pattern: #"(?i)url\s*\(([^)]*)\)"#)
    private static let urlStarts = try? NSRegularExpression(pattern: #"(?i)url\s*\("#)
    private static let filters = try? NSRegularExpression(pattern: #"(?i)(?:^|[;{])\s*(?:-webkit-)?(?:backdrop-)?filter\s*:"#)
    private var stack: [String] = []
    private var elementCount = 0
    private var title = ""
    private var descriptionText = ""
    private var style = ""
    private(set) var isValid = true

    var accessibilityDescription: String? {
        let parts = [title, descriptionText].map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elementCount += 1
        guard elementCount <= 20_000, stack.count < 128,
              Self.elements.contains(elementName),
              namespaceURI == nil || namespaceURI == "" || namespaceURI == Self.svgNamespace,
              !stack.isEmpty || elementName == "svg" else { reject(parser); return }
        if stack.isEmpty {
            for name in ["width", "height"] {
                if let value = attributeDict[name], !Self.validLength(value) { reject(parser); return }
            }
            if let viewBox = attributeDict["viewBox"], !Self.validViewBox(viewBox) { reject(parser); return }
        }
        for (name, value) in attributeDict {
            let lower = name.lowercased()
            guard !lower.hasPrefix("on"), lower != "xml:base", lower != "base",
                  lower != "src", lower != "filter" else { reject(parser); return }
            if lower == "href" || lower.hasSuffix(":href") {
                guard Self.isFragment(value) else { reject(parser); return }
            }
            if lower == "style" {
                guard Self.validCSS(value) else { reject(parser); return }
            } else if !Self.validReferences(value) {
                reject(parser); return
            }
        }
        stack.append(elementName)
        if elementName == "style" { style = "" }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "style", !Self.validCSS(style) { reject(parser); return }
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { reject(parser); return }
        append(string)
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }

    private func append(_ string: String) {
        switch stack.last {
        case "style": style += string
        case "title" where stack.count == 2: title += string
        case "desc" where stack.count == 2: descriptionText += string
        default: break
        }
    }

    private func reject(_ parser: XMLParser) {
        isValid = false
        parser.abortParsing()
    }

    private static func isFragment(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("#") && trimmed.count > 1
            && !trimmed.contains(where: {
                $0.isWhitespace || $0.isNewline || $0 == "\\" || $0 == "'" || $0 == "\"" || $0 == "(" || $0 == ")"
            })
    }

    private static func validCSS(_ value: String) -> Bool {
        // Escaped CSS tokens and at-rules can conceal resource references.
        // Unsupported syntax falls back to source rather than being rewritten.
        guard !value.contains("\\") else { return false }
        let css = withoutComments(value)
        let range = NSRange(css.startIndex..<css.endIndex, in: css)
        guard !css.contains("@"), let filters,
              filters.numberOfMatches(in: css, range: range) == 0 else { return false }
        return validReferences(css)
    }

    private static func validReferences(_ value: String) -> Bool {
        guard !value.contains("\\") else { return false }
        // Strip comments before inspecting URL tokens. AppKit, rather than
        // this validator, interprets all remaining styling.
        let css = withoutComments(value)
        guard css.range(of: "url", options: .caseInsensitive) != nil else { return true }
        guard let urls, let urlStarts else { return false }
        let range = NSRange(css.startIndex..<css.endIndex, in: css)
        let matches = urls.matches(in: css, range: range)
        guard matches.count == urlStarts.numberOfMatches(in: css, range: range) else { return false }
        for match in matches {
            guard let tokenRange = Range(match.range(at: 1), in: css) else { return false }
            var token = String(css[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = token.first, first == "\"" || first == "'" {
                guard token.last == first, token.count >= 2 else { return false }
                token.removeFirst(); token.removeLast()
            }
            guard isFragment(token) else { return false }
        }
        return true
    }

    private static func withoutComments(_ value: String) -> String {
        guard value.contains("/*"), let comments else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return comments.stringByReplacingMatches(in: value, range: range, withTemplate: "")
    }

    private static func validLength(_ value: String) -> Bool {
        let scanner = Scanner(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let number = scanner.scanDouble(), number.isFinite, number > 0, number <= 1_000_000 else { return false }
        let unit = String(scanner.string[scanner.currentIndex...]).lowercased()
        return ["", "px", "pt", "pc", "cm", "mm", "in", "em", "ex", "%"].contains(unit)
    }

    private static func validViewBox(_ value: String) -> Bool {
        let tokens = value.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        guard tokens.count == 4 else { return false }
        let numbers = tokens.compactMap { Double($0) }
        return numbers.count == 4 && numbers.allSatisfy(\.isFinite)
            && numbers[2] > 0 && numbers[2] <= 1_000_000 && numbers[3] > 0 && numbers[3] <= 1_000_000
    }
}
#endif
