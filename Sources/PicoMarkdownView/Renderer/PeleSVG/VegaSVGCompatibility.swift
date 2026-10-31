#if os(macOS)
import Foundation
import CoreGraphics

/// The additional vocabulary emitted by the bundled Vega SVG renderer. This
/// remains opt-in so Mermaid/Pele and the iOS renderer keep their existing rules.
enum VegaSVGCompatibility {
    private static let elements: Set<String> = [
        "svg", "g", "a", "path", "rect", "circle", "ellipse", "line", "polygon", "polyline",
        "text", "tspan", "defs", "clipPath", "linearGradient", "stop", "title", "desc", "metadata"
    ]
    private static let styleProperties: Set<String> = [
        "fill", "fill-opacity", "stroke", "stroke-width", "stroke-dasharray", "stroke-dashoffset",
        "stroke-linecap", "stroke-linejoin", "stroke-opacity", "opacity", "color",
        "font-family", "font-size", "font-weight", "font-style", "font", "text-decoration",
        "text-anchor", "letter-spacing", "word-spacing", "baseline-shift", "rx", "ry",
        "stop-color", "stop-opacity", "display", "visibility"
    ]

    /// Refuse render-critical features we cannot paint, so the chart provider
    /// can show its normal code fallback instead of a misleading partial chart.
    static func isSupported(_ element: PeleSVGElement) -> Bool {
        if isHidden(element) { return true }
        guard elements.contains(element.name) else { return false }
        for key in ["filter", "mask", "marker-start", "marker-mid", "marker-end"] {
            if let value = element.attributes[key], value != "none" { return false }
        }
        if let rule = element.attributes["fill-rule"], rule != "nonzero" { return false }
        if let rule = element.attributes["clip-rule"], rule != "nonzero" { return false }
        for key in ["dx", "dy"] {
            if let value = element.attributes[key], PeleSVGValue.length(value) == nil { return false }
        }
        if element.attributes["gradientTransform"] != nil { return false }
        if element.attributes["stroke"]?.hasPrefix("url(") == true { return false }
        if ["text", "tspan"].contains(element.name), element.attributes["fill"]?.hasPrefix("url(") == true { return false }
        if let mode = element.attributes["spreadMethod"], mode != "pad" { return false }
        if let limit = element.attributes["stroke-miterlimit"], PeleSVGValue.length(limit) != 10 { return false }
        if let style = element.attributes["style"] {
            for declaration in style.split(separator: ";") {
                guard let colon = declaration.firstIndex(of: ":") else { continue }
                let property = declaration[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                guard styleProperties.contains(property) else { return false }
            }
        }
        for case let .element(child) in element.children {
            guard isSupported(child) else { return false }
        }
        return true
    }

    static func isHidden(_ element: PeleSVGElement) -> Bool {
        var display = element.attributes["display"]
        var visibility = element.attributes["visibility"]
        if let style = element.attributes["style"] {
            for declaration in style.split(separator: ";") {
                guard let colon = declaration.firstIndex(of: ":") else { continue }
                let key = declaration[..<colon].trimmingCharacters(in: .whitespaces)
                let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if key == "display" { display = value }
                if key == "visibility" { visibility = value }
            }
        }
        return display == "none" || visibility == "hidden" || visibility == "collapse"
    }

    static func localReference(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("url(#"), value.hasSuffix(")") else { return nil }
        let id = String(value.dropFirst(5).dropLast())
        return id.isEmpty ? nil : id
    }

    /// Vega emits user-space clips with one rectangle or rounded path.
    static func clipPaths(in root: PeleSVGElement) -> [String: CGPath]? {
        var paths: [String: CGPath] = [:]
        var references: [String] = []
        func visit(_ element: PeleSVGElement) -> Bool {
            if isHidden(element) { return true }
            if let reference = element.attributes["clip-path"], reference != "none" {
                guard let id = localReference(reference) else { return false }
                references.append(id)
            }
            if element.name == "clipPath" {
                guard let id = element.attributes["id"], paths[id] == nil,
                      element.attributes["clipPathUnits"] == nil || element.attributes["clipPathUnits"] == "userSpaceOnUse" else { return false }
                let children = element.children.compactMap { node -> PeleSVGElement? in
                    if case let .element(child) = node { return child }
                    return nil
                }
                guard children.count == 1, let child = children.first else { return false }
                let path: CGPath
                switch child.name {
                case "rect":
                    guard let width = child.length("width"), let height = child.length("height"), width >= 0, height >= 0,
                          child.attributes["rx"] == nil, child.attributes["ry"] == nil else { return false }
                    path = CGPath(rect: CGRect(x: child.length("x", default: 0), y: child.length("y", default: 0),
                                              width: width, height: height), transform: nil)
                case "path":
                    guard let data = child.attributes["d"], let parsed = PeleSVGPath.parse(data) else { return false }
                    path = parsed
                default:
                    return false
                }
                var transform = child.attributes["transform"].map(PeleSVGValue.transform) ?? .identity
                if let value = element.attributes["transform"] {
                    transform = transform.concatenating(PeleSVGValue.transform(value))
                }
                guard let transformed = path.copy(using: &transform) else { return false }
                paths[id] = transformed
                return true
            }
            for case let .element(child) in element.children {
                guard visit(child) else { return false }
            }
            return true
        }
        guard visit(root), references.allSatisfy({ paths[$0] != nil }) else { return nil }
        return paths
    }

    /// Unlike Pele's user-space gradients, Vega serializes bounding-box
    /// coordinates as percentages and may give individual stops opacity.
    static func gradients(in root: PeleSVGElement) -> [String: PeleSVGGradient] {
        var found: [String: PeleSVGGradient] = [:]
        func visit(_ element: PeleSVGElement) {
            if element.name == "linearGradient", let id = element.attributes["id"] {
                let userSpace = element.attributes["gradientUnits"] == "userSpaceOnUse"
                func coordinate(_ key: String, default value: CGFloat) -> CGFloat {
                    guard let text = element.attributes[key] else { return value }
                    return (userSpace ? PeleSVGValue.length(text) : PeleSVGValue.fraction(text)) ?? value
                }
                let stops = element.children.compactMap { node -> PeleSVGGradientStop? in
                    guard case let .element(stop) = node, stop.name == "stop" else { return nil }
                    var style = PeleSVGStyle()
                    style.apply(element: stop)
                    guard let color = style.stopColor else { return nil }
                    return PeleSVGGradientStop(offset: min(max(stop.attributes["offset"].flatMap(PeleSVGValue.fraction) ?? 0, 0), 1),
                                               color: color.copy(alpha: color.alpha * style.stopOpacity) ?? color)
                }
                found[id] = PeleSVGGradient(start: CGPoint(x: coordinate("x1", default: 0), y: coordinate("y1", default: 0)),
                                            end: CGPoint(x: coordinate("x2", default: 1), y: coordinate("y2", default: 0)),
                                            userSpace: userSpace, stops: stops)
                return
            }
            for case let .element(child) in element.children { visit(child) }
        }
        visit(root)
        return found
    }

    static func fontFamily(_ family: String) -> String {
        family.split(separator: ",").map { candidate in
            switch candidate.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")).lowercased() {
            case "sans-serif": return "Arial"
            case "serif": return "Times"
            case "monospace": return "Courier"
            default: return String(candidate)
            }
        }.joined(separator: ",")
    }

    static func accessibilitySummary(in root: PeleSVGElement) -> String? {
        var labels: [String] = []
        var seen: Set<String> = []
        func visit(_ element: PeleSVGElement) {
            guard labels.count < 100, !isHidden(element), element.attributes["aria-hidden"] != "true",
                  element.name != "defs" else { return }
            if let label = element.attributes["aria-label"], !label.isEmpty, seen.insert(label).inserted {
                labels.append(label)
            }
            for case let .element(child) in element.children { visit(child) }
        }
        visit(root)
        return labels.isEmpty ? nil : labels.joined(separator: ". ")
    }
}
#endif
