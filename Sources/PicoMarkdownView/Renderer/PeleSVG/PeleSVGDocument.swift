import Foundation
import CoreGraphics

// MARK: - Tree

/// One element of the SVG subset Pele emits. See `PeleSVGDocument`.
final class PeleSVGElement {
    let name: String
    let attributes: [String: String]
    var children: [PeleSVGNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// A numeric attribute such as `x`, `width` or `r`. Units other than
    /// `px` are not something Pele writes and read as absent.
    func length(_ key: String) -> CGFloat? {
        attributes[key].flatMap(PeleSVGValue.length)
    }

    func length(_ key: String, default value: CGFloat) -> CGFloat {
        length(key) ?? value
    }
}

enum PeleSVGNode {
    case element(PeleSVGElement)
    case text(String)
}

struct PeleSVGGradientStop {
    var offset: CGFloat
    var color: CGColor
}

/// A `<linearGradient>` from `<defs>`; Pele draws sankey links with them.
struct PeleSVGGradient {
    var start: CGPoint
    var end: CGPoint
    /// `gradientUnits="userSpaceOnUse"`; otherwise coordinates are fractions
    /// of the filled shape's bounding box.
    var userSpace: Bool
    var stops: [PeleSVGGradientStop]
}

// MARK: - Document

/// The SVG that `PeleRenderer` returns, parsed into a tree the rasterizer in
/// `PeleSVGRasterizer.swift` can draw with CoreGraphics on both platforms.
///
/// This is deliberately not a general SVG implementation. Pele's output is
/// produced by one code base with a small, fixed vocabulary — groups,
/// paths, basic shapes, `text`/`tspan`, links, nested `svg` icons,
/// `translate`/`rotate` transforms and linear gradients — and that is the
/// whole of what is supported. Anything else (`image`, `foreignObject`,
/// filters, CSS stylesheets) is ignored rather than drawn wrongly. macOS's
/// opt-in Vega dialect adds only the constructs its bundled runtime emits;
/// unsupported render features reject the chart so its provider can fall back.
struct PeleSVGDocument {
    enum Dialect {
        case pele
        #if os(macOS)
        /// The SVG emitted by the bundled Vega runtime, never arbitrary SVG.
        case vega
        #endif
    }

    let dialect: Dialect
    #if os(macOS)
    let vegaClipPaths: [String: CGPath]
    /// Vega's axis and mark descriptions, for the hosted canvas's VoiceOver label.
    var accessibilitySummary: String? {
        dialect == .vega ? VegaSVGCompatibility.accessibilitySummary(in: root) : nil
    }
    #endif

    let root: PeleSVGElement
    /// Intrinsic size in points, from the root `width`/`height`.
    let width: CGFloat
    let height: CGFloat
    /// User-space rectangle the drawing is laid out in (the root `viewBox`).
    let viewBox: CGRect
    let gradients: [String: PeleSVGGradient]

    /// Parses Pele's markup. Returns `nil` for markup that is not well-formed
    /// XML, lacks a root `<svg>`, or has no usable size. The opt-in Vega
    /// dialect also rejects unsupported render-critical features.
    init?(svg: String, dialect: Dialect = .pele) {
        guard let data = svg.data(using: .utf8) else { return nil }
        let builder = PeleSVGTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), let root = builder.root, root.name == "svg" else { return nil }

        let viewBoxValues = root.attributes["viewBox"].map(PeleSVGValue.numberList) ?? []
        let explicitWidth = root.length("width")
        let explicitHeight = root.length("height")

        let viewBox: CGRect
        if viewBoxValues.count == 4, viewBoxValues[2] > 0, viewBoxValues[3] > 0 {
            viewBox = CGRect(x: viewBoxValues[0], y: viewBoxValues[1], width: viewBoxValues[2], height: viewBoxValues[3])
        } else if let explicitWidth, let explicitHeight, explicitWidth > 0, explicitHeight > 0 {
            viewBox = CGRect(x: 0, y: 0, width: explicitWidth, height: explicitHeight)
        } else {
            return nil
        }

        let width = explicitWidth ?? viewBox.width
        let height = explicitHeight ?? viewBox.height
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return nil }

        #if os(macOS)
        if dialect == .vega {
            guard VegaSVGCompatibility.isSupported(root),
                  let clips = VegaSVGCompatibility.clipPaths(in: root) else { return nil }
            self.vegaClipPaths = clips
        } else {
            self.vegaClipPaths = [:]
        }
        #endif
        self.dialect = dialect
        self.root = root
        self.width = width
        self.height = height
        self.viewBox = viewBox
        #if os(macOS)
        self.gradients = dialect == .vega
            ? VegaSVGCompatibility.gradients(in: root)
            : Self.collectGradients(in: root)
        #else
        self.gradients = Self.collectGradients(in: root)
        #endif
    }

    private static func collectGradients(in element: PeleSVGElement) -> [String: PeleSVGGradient] {
        var found: [String: PeleSVGGradient] = [:]
        func visit(_ element: PeleSVGElement) {
            if element.name == "linearGradient", let id = element.attributes["id"] {
                var stops: [PeleSVGGradientStop] = []
                for case let .element(stop) in element.children where stop.name == "stop" {
                    var style = PeleSVGStyle()
                    style.apply(element: stop)
                    guard let color = style.stopColor else { continue }
                    let offset = stop.attributes["offset"].flatMap(PeleSVGValue.fraction) ?? 0
                    stops.append(PeleSVGGradientStop(offset: min(max(offset, 0), 1), color: color))
                }
                guard !stops.isEmpty else { return }
                let userSpace = element.attributes["gradientUnits"] == "userSpaceOnUse"
                let fallbackEndX: CGFloat = userSpace ? 0 : 1
                found[id] = PeleSVGGradient(
                    start: CGPoint(x: element.length("x1", default: 0), y: element.length("y1", default: 0)),
                    end: CGPoint(x: element.length("x2", default: fallbackEndX), y: element.length("y2", default: 0)),
                    userSpace: userSpace,
                    stops: stops
                )
                return
            }
            for case let .element(child) in element.children {
                visit(child)
            }
        }
        visit(element)
        return found
    }
}

// MARK: - XML tree builder

private final class PeleSVGTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root: PeleSVGElement?
    private var stack: [PeleSVGElement] = []

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let element = PeleSVGElement(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(.element(element))
        } else if root == nil {
            root = element
        }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let current = stack.last else { return }
        // Entities arrive as separate callbacks; merge adjacent text.
        if case let .text(previous)? = current.children.last {
            current.children[current.children.count - 1] = .text(previous + string)
        } else {
            current.children.append(.text(string))
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        self.parser(parser, foundCharacters: string)
    }
}

// MARK: - Style cascade

enum PeleSVGPaint: Equatable {
    case none
    case color(CGColor)
    case currentColor
    /// `url(#id) fallback` — the fallback is used when the gradient is unknown.
    case gradient(id: String, fallback: CGColor?)

    static func parse(_ value: String) -> PeleSVGPaint? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed == "none" { return PeleSVGPaint.none }
        if trimmed == "currentColor" || trimmed == "currentcolor" { return .currentColor }
        if trimmed.hasPrefix("url(") {
            guard let close = trimmed.firstIndex(of: ")") else { return nil }
            var reference = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<close]
                .trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            if reference.hasPrefix("#") { reference.removeFirst() }
            let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
            let fallback = rest.isEmpty || rest == "none" ? nil : PeleSVGValue.color(rest)
            return .gradient(id: reference, fallback: fallback)
        }
        return PeleSVGValue.color(trimmed).map(PeleSVGPaint.color)
    }
}

enum PeleSVGTextAnchor {
    case start, middle, end
}

/// The presentation properties that matter for Pele's output, resolved
/// through the element tree the way CSS inheritance would resolve them.
struct PeleSVGStyle {
    // Inherited.
    var fill: PeleSVGPaint = .color(PeleSVGValue.black)
    var stroke: PeleSVGPaint = .none
    var strokeWidth: CGFloat = 1
    var dashes: [CGFloat] = []
    var dashOffset: CGFloat = 0
    var lineCap: CGLineCap = .butt
    var lineJoin: CGLineJoin = .miter
    var fillOpacity: CGFloat = 1
    var strokeOpacity: CGFloat = 1
    var color: CGColor = PeleSVGValue.black
    var fontFamily: String = "sans-serif"
    var fontSize: CGFloat = 16
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var textAnchor: PeleSVGTextAnchor = .start
    var letterSpacing: CGFloat = 0
    var wordSpacing: CGFloat = 0
    var preserveSpace = false

    // Not inherited; reset for every element.
    var opacity: CGFloat = 1
    /// Baseline shift as a fraction of the parent font size (`sub`/`super`).
    var baselineShift: CGFloat = 0
    var rx: CGFloat?
    var ry: CGFloat?
    var stopColor: CGColor?
    var stopOpacity: CGFloat = 1

    private static let presentationAttributes: Set<String> = [
        "fill", "fill-opacity", "stroke", "stroke-width", "stroke-dasharray", "stroke-dashoffset",
        "stroke-linecap", "stroke-linejoin", "stroke-opacity", "opacity", "color",
        "font-family", "font-size", "font-weight", "font-style", "font", "text-decoration",
        "text-anchor", "letter-spacing", "word-spacing", "baseline-shift", "rx", "ry", "stop-color", "stop-opacity"
    ]

    /// Layers `element`'s presentation attributes and `style` declarations
    /// over the inherited values in `self`.
    mutating func apply(element: PeleSVGElement) {
        let parentFontSize = fontSize
        opacity = 1
        baselineShift = 0
        rx = nil
        ry = nil
        stopColor = nil
        stopOpacity = 1

        if let space = element.attributes["xml:space"] {
            preserveSpace = space == "preserve"
        }
        for (key, value) in element.attributes where Self.presentationAttributes.contains(key) {
            apply(property: key, value: value, parentFontSize: parentFontSize)
        }
        if let style = element.attributes["style"] {
            for declaration in style.split(separator: ";") {
                guard let colon = declaration.firstIndex(of: ":") else { continue }
                let property = declaration[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                apply(property: property, value: value, parentFontSize: parentFontSize)
            }
        }
    }

    private mutating func apply(property: String, value rawValue: String, parentFontSize: CGFloat) {
        let value = rawValue.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        switch property {
        case "fill":
            if let paint = PeleSVGPaint.parse(value) { fill = paint }
        case "stroke":
            if let paint = PeleSVGPaint.parse(value) { stroke = paint }
        case "stroke-width":
            if let width = PeleSVGValue.length(value), width >= 0 { strokeWidth = width }
        case "stroke-dasharray":
            if value == "none" {
                dashes = []
            } else {
                // Mermaid styles pass `5px 2px` through; lengths, not bare numbers.
                let list = value.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                    .compactMap { PeleSVGValue.length(String($0)) }
                    .filter { $0 >= 0 }
                dashes = list.allSatisfy({ $0 == 0 }) ? [] : list
            }
        case "stroke-dashoffset":
            if let offset = PeleSVGValue.length(value) { dashOffset = offset }
        case "stroke-linecap":
            switch value {
            case "round": lineCap = .round
            case "square": lineCap = .square
            default: lineCap = .butt
            }
        case "stroke-linejoin":
            switch value {
            case "round": lineJoin = .round
            case "bevel": lineJoin = .bevel
            default: lineJoin = .miter
            }
        case "fill-opacity":
            if let alpha = PeleSVGValue.fraction(value) { fillOpacity = min(max(alpha, 0), 1) }
        case "stroke-opacity":
            if let alpha = PeleSVGValue.fraction(value) { strokeOpacity = min(max(alpha, 0), 1) }
        case "opacity":
            if let alpha = PeleSVGValue.fraction(value) { opacity = min(max(alpha, 0), 1) }
        case "color":
            if let parsed = PeleSVGValue.color(value) { color = parsed }
        case "font-family":
            fontFamily = value
        case "font-size":
            applyFontSize(value, parentFontSize: parentFontSize)
        case "font-weight":
            applyFontWeight(value)
        case "font-style":
            italic = value == "italic" || value == "oblique"
        case "font":
            applyFontShorthand(value, parentFontSize: parentFontSize)
        case "text-decoration":
            underline = value.contains("underline")
            strikethrough = value.contains("line-through")
        case "text-anchor":
            switch value {
            case "middle": textAnchor = .middle
            case "end": textAnchor = .end
            default: textAnchor = .start
            }
        case "letter-spacing":
            letterSpacing = value == "normal" ? 0 : (PeleSVGValue.length(value) ?? 0)
        case "word-spacing":
            wordSpacing = value == "normal" ? 0 : (PeleSVGValue.length(value) ?? 0)
        case "baseline-shift":
            switch value {
            case "sub": baselineShift = -0.2
            case "super": baselineShift = 0.35
            default:
                if let shift = PeleSVGValue.length(value), parentFontSize > 0 { baselineShift = shift / parentFontSize }
            }
        case "rx":
            if let radius = PeleSVGValue.length(value), radius >= 0 { rx = radius }
        case "ry":
            if let radius = PeleSVGValue.length(value), radius >= 0 { ry = radius }
        case "stop-color":
            stopColor = PeleSVGValue.color(value)
        case "stop-opacity":
            if let alpha = PeleSVGValue.fraction(value) { stopOpacity = min(max(alpha, 0), 1) }
        default:
            break
        }
    }

    private mutating func applyFontSize(_ value: String, parentFontSize: CGFloat) {
        switch value {
        case "smaller": fontSize = parentFontSize / 1.2
        case "larger": fontSize = parentFontSize * 1.2
        default:
            if value.hasSuffix("em"), let factor = PeleSVGValue.length(String(value.dropLast(2))) {
                fontSize = parentFontSize * factor
            } else if value.hasSuffix("%"), let percent = PeleSVGValue.length(String(value.dropLast())), percent > 0 {
                fontSize = parentFontSize * percent / 100
            } else if let size = PeleSVGValue.length(value), size > 0 {
                fontSize = size
            }
        }
    }

    private mutating func applyFontWeight(_ value: String) {
        switch value {
        case "bold", "bolder": bold = true
        case "normal", "lighter": bold = false
        default:
            if let weight = Double(value) { bold = weight >= 600 }
        }
    }

    /// `font: [style] [weight] size[/line-height] family` — Pele writes
    /// `font:14px sans-serif` on the root element.
    private mutating func applyFontShorthand(_ value: String, parentFontSize: CGFloat) {
        let tokens = value.split(separator: " ").map(String.init)
        guard let sizeIndex = tokens.firstIndex(where: { token in
            let base = token.split(separator: "/").first.map(String.init) ?? token
            return PeleSVGValue.length(base) != nil || base == "smaller" || base == "larger"
        }) else { return }
        for token in tokens[..<sizeIndex] {
            switch token {
            case "italic", "oblique": italic = true
            case "normal": break
            default: applyFontWeight(token)
            }
        }
        let sizeToken = tokens[sizeIndex].split(separator: "/").first.map(String.init) ?? tokens[sizeIndex]
        applyFontSize(sizeToken, parentFontSize: parentFontSize)
        let family = tokens[(sizeIndex + 1)...].joined(separator: " ")
        if !family.isEmpty { fontFamily = family }
    }

    /// The color to paint with, or `nil` for `none`/unknown gradients, with
    /// opacity folded in.
    func resolvedColor(_ paint: PeleSVGPaint, opacity: CGFloat) -> CGColor? {
        let base: CGColor?
        switch paint {
        case .none: base = nil
        case let .color(color): base = color
        case .currentColor: base = color
        case let .gradient(_, fallback): base = fallback
        }
        guard let base else { return nil }
        let alpha = base.alpha * opacity
        return alpha >= 1 ? base : (base.copy(alpha: alpha) ?? base)
    }
}

// MARK: - Value parsing

enum PeleSVGValue {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let black = CGColor(colorSpace: colorSpace, components: [0, 0, 0, 1])!

    static func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha]) ?? black
    }

    /// `12`, `12.5px`, `-3`, `1e2`. Returns `nil` for percentages and units
    /// that need a context Pele never relies on.
    static func length(_ string: String) -> CGFloat? {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("px") { text = String(text.dropLast(2)) }
        guard let value = Double(text), value.isFinite else { return nil }
        return CGFloat(value)
    }

    /// `0.5` or `50%` as a fraction.
    static func fraction(_ string: String) -> CGFloat? {
        let text = string.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("%"), let percent = Double(text.dropLast()) { return CGFloat(percent / 100) }
        guard let value = Double(text), value.isFinite else { return nil }
        return CGFloat(value)
    }

    /// Numbers separated by commas and/or whitespace (`points`, `viewBox`,
    /// `stroke-dasharray`).
    static func numberList(_ string: String) -> [CGFloat] {
        var numbers: [CGFloat] = []
        var token = ""
        func flush() {
            if !token.isEmpty, let value = Double(token), value.isFinite { numbers.append(CGFloat(value)) }
            token = ""
        }
        for character in string {
            if character == "," || character.isWhitespace {
                flush()
            } else {
                token.append(character)
            }
        }
        flush()
        return numbers
    }

    /// `translate(x[,y])`, `rotate(a[,cx,cy])`, `scale(sx[,sy])`,
    /// `matrix(a,b,c,d,e,f)`, applied left to right.
    static func transform(_ string: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        var cursor = string.startIndex
        while let open = string[cursor...].firstIndex(of: "("), let close = string[open...].firstIndex(of: ")") {
            let name = string[cursor..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\t"))
            let arguments = numberList(String(string[string.index(after: open)..<close]))
            cursor = string.index(after: close)
            var transform = CGAffineTransform.identity
            switch (name, arguments.count) {
            case ("translate", 1): transform = CGAffineTransform(translationX: arguments[0], y: 0)
            case ("translate", 2...): transform = CGAffineTransform(translationX: arguments[0], y: arguments[1])
            case ("scale", 1): transform = CGAffineTransform(scaleX: arguments[0], y: arguments[0])
            case ("scale", 2...): transform = CGAffineTransform(scaleX: arguments[0], y: arguments[1])
            case ("rotate", 1): transform = CGAffineTransform(rotationAngle: arguments[0] * .pi / 180)
            case ("rotate", 3...):
                transform = CGAffineTransform(translationX: arguments[1], y: arguments[2])
                    .rotated(by: arguments[0] * .pi / 180)
                    .translatedBy(x: -arguments[1], y: -arguments[2])
            case ("matrix", 6...):
                transform = CGAffineTransform(a: arguments[0], b: arguments[1], c: arguments[2],
                                              d: arguments[3], tx: arguments[4], ty: arguments[5])
            default: continue
            }
            result = transform.concatenating(result)
        }
        return result
    }

    /// `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()`, CSS color
    /// names and `transparent`.
    static func color(_ string: String) -> CGColor? {
        let text = string.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") {
            return hexColor(String(text.dropFirst()))
        }
        if text.hasPrefix("rgb") {
            guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") else { return nil }
            let parts = text[text.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            func channel(_ part: String) -> CGFloat? {
                if part.hasSuffix("%"), let percent = Double(part.dropLast()) { return CGFloat(percent / 100) }
                guard let value = Double(part) else { return nil }
                return CGFloat(value / 255)
            }
            guard let red = channel(parts[0]), let green = channel(parts[1]), let blue = channel(parts[2]) else { return nil }
            let alpha = parts.count > 3 ? (fraction(parts[3]) ?? 1) : 1
            return rgba(min(max(red, 0), 1), min(max(green, 0), 1), min(max(blue, 0), 1), min(max(alpha, 0), 1))
        }
        if text.hasPrefix("hsl") {
            return hslColor(text)
        }
        if text == "transparent" { return rgba(0, 0, 0, 0) }
        return namedColors[text].flatMap(hexColor)
    }

    /// `hsl(120, 100%, 50%)`, `hsla(240 100% 50% / 0.5)`; Mermaid sequence
    /// diagrams pass `rect hsl(...)` highlights straight through.
    private static func hslColor(_ text: String) -> CGColor? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") else { return nil }
        let parts = text[text.index(after: open)..<close]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        var hueText = parts[0]
        if hueText.hasSuffix("deg") { hueText = String(hueText.dropLast(3)) }
        guard let hueDegrees = Double(hueText),
              let saturation = fraction(parts[1]),
              let lightness = fraction(parts[2]) else { return nil }
        let alpha = parts.count > 3 ? (fraction(parts[3]) ?? 1) : 1

        let hue = CGFloat((hueDegrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)) / 360
        let s = min(max(saturation, 0), 1)
        let l = min(max(lightness, 0), 1)
        let chroma = (1 - abs(2 * l - 1)) * s
        let x = chroma * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - chroma / 2
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch hue * 6 {
        case ..<1: (r, g, b) = (chroma, x, 0)
        case ..<2: (r, g, b) = (x, chroma, 0)
        case ..<3: (r, g, b) = (0, chroma, x)
        case ..<4: (r, g, b) = (0, x, chroma)
        case ..<5: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        return rgba(r + m, g + m, b + m, min(max(alpha, 0), 1))
    }

    private static func hexColor(_ hex: String) -> CGColor? {
        let digits = Array(hex)
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        func value(_ characters: [Character]) -> CGFloat? {
            guard let parsed = Int(String(characters), radix: 16) else { return nil }
            return CGFloat(parsed) / 255
        }
        switch digits.count {
        case 3, 4:
            let expanded = digits.map { [$0, $0] }
            guard let red = value(expanded[0]), let green = value(expanded[1]), let blue = value(expanded[2]) else { return nil }
            let alpha = digits.count == 4 ? (value(expanded[3]) ?? 1) : 1
            return rgba(red, green, blue, alpha)
        case 6, 8:
            guard let red = value(Array(digits[0..<2])), let green = value(Array(digits[2..<4])), let blue = value(Array(digits[4..<6])) else { return nil }
            let alpha = digits.count == 8 ? (value(Array(digits[6..<8])) ?? 1) : 1
            return rgba(red, green, blue, alpha)
        default:
            return nil
        }
    }

    /// CSS Color Module Level 4 named colors. Mermaid `style`/`classDef`
    /// directives pass these through to the SVG.
    static let namedColors: [String: String] = {
        let table = """
        aliceblue:f0f8ff antiquewhite:faebd7 aqua:00ffff aquamarine:7fffd4 azure:f0ffff beige:f5f5dc bisque:ffe4c4 \
        black:000000 blanchedalmond:ffebcd blue:0000ff blueviolet:8a2be2 brown:a52a2a burlywood:deb887 cadetblue:5f9ea0 \
        chartreuse:7fff00 chocolate:d2691e coral:ff7f50 cornflowerblue:6495ed cornsilk:fff8dc crimson:dc143c cyan:00ffff \
        darkblue:00008b darkcyan:008b8b darkgoldenrod:b8860b darkgray:a9a9a9 darkgreen:006400 darkgrey:a9a9a9 \
        darkkhaki:bdb76b darkmagenta:8b008b darkolivegreen:556b2f darkorange:ff8c00 darkorchid:9932cc darkred:8b0000 \
        darksalmon:e9967a darkseagreen:8fbc8f darkslateblue:483d8b darkslategray:2f4f4f darkslategrey:2f4f4f \
        darkturquoise:00ced1 darkviolet:9400d3 deeppink:ff1493 deepskyblue:00bfff dimgray:696969 dimgrey:696969 \
        dodgerblue:1e90ff firebrick:b22222 floralwhite:fffaf0 forestgreen:228b22 fuchsia:ff00ff gainsboro:dcdcdc \
        ghostwhite:f8f8ff gold:ffd700 goldenrod:daa520 gray:808080 green:008000 greenyellow:adff2f grey:808080 \
        honeydew:f0fff0 hotpink:ff69b4 indianred:cd5c5c indigo:4b0082 ivory:fffff0 khaki:f0e68c lavender:e6e6fa \
        lavenderblush:fff0f5 lawngreen:7cfc00 lemonchiffon:fffacd lightblue:add8e6 lightcoral:f08080 lightcyan:e0ffff \
        lightgoldenrodyellow:fafad2 lightgray:d3d3d3 lightgreen:90ee90 lightgrey:d3d3d3 lightpink:ffb6c1 \
        lightsalmon:ffa07a lightseagreen:20b2aa lightskyblue:87cefa lightslategray:778899 lightslategrey:778899 \
        lightsteelblue:b0c4de lightyellow:ffffe0 lime:00ff00 limegreen:32cd32 linen:faf0e6 magenta:ff00ff maroon:800000 \
        mediumaquamarine:66cdaa mediumblue:0000cd mediumorchid:ba55d3 mediumpurple:9370db mediumseagreen:3cb371 \
        mediumslateblue:7b68ee mediumspringgreen:00fa9a mediumturquoise:48d1cc mediumvioletred:c71585 midnightblue:191970 \
        mintcream:f5fffa mistyrose:ffe4e1 moccasin:ffe4b5 navajowhite:ffdead navy:000080 oldlace:fdf5e6 olive:808000 \
        olivedrab:6b8e23 orange:ffa500 orangered:ff4500 orchid:da70d6 palegoldenrod:eee8aa palegreen:98fb98 \
        paleturquoise:afeeee palevioletred:db7093 papayawhip:ffefd5 peachpuff:ffdab9 peru:cd853f pink:ffc0cb plum:dda0dd \
        powderblue:b0e0e6 purple:800080 rebeccapurple:663399 red:ff0000 rosybrown:bc8f8f royalblue:4169e1 \
        saddlebrown:8b4513 salmon:fa8072 sandybrown:f4a460 seagreen:2e8b57 seashell:fff5ee sienna:a0522d silver:c0c0c0 \
        skyblue:87ceeb slateblue:6a5acd slategray:708090 slategrey:708090 snow:fffafa springgreen:00ff7f steelblue:4682b4 \
        tan:d2b48c teal:008080 thistle:d8bfd8 tomato:ff6347 turquoise:40e0d0 violet:ee82ee wheat:f5deb3 white:ffffff \
        whitesmoke:f5f5f5 yellow:ffff00 yellowgreen:9acd32
        """
        var colors: [String: String] = [:]
        for entry in table.split(whereSeparator: \.isWhitespace) {
            let pair = entry.split(separator: ":")
            guard pair.count == 2 else { continue }
            colors[String(pair[0])] = String(pair[1])
        }
        return colors
    }()
}
