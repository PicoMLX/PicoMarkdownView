#if os(macOS)
import Foundation
import CoreGraphics

struct VegaLiteRenderResult: Sendable, Equatable {
    var svg: String
    var intrinsicSize: CGSize
}

/// Completed, static, inline-data Vega-Lite charts. No work is requested for
/// streaming prefixes; the host retains a loading attachment until closure.
actor VegaLiteChartProvider {
    private struct Key: Hashable {
        var source: String
        var width: CGFloat?
        var appearance: PeleAppearance
    }

    private let theme: MarkdownRenderTheme
    private var cache: [Key: VegaLiteRenderResult] = [:]
    private var lru: [Key] = []
    private var cachedBytes = 0
    private var failed: Key?

    init(theme: MarkdownRenderTheme) { self.theme = theme }

    func render(source: String, targetWidth: CGFloat?) async -> VegaLiteRenderResult? {
        guard !Task.isCancelled,
              targetWidth.map({ $0.isFinite && $0 > 0 && $0 <= 16_384 }) ?? true,
              VegaLiteSpecPolicy.accepts(source) else { return nil }
        let width = targetWidth.map { min(max(($0 / 8).rounded() * 8, 64), 2_048) }
        let appearance = await MainActor.run { PeleAppearance.current() }
        let key = Key(source: source, width: width, appearance: appearance)
        if let cached = cache[key] { touch(key); return cached }
        guard failed != key, !Task.isCancelled, let runtime = VegaLiteRuntime.shared else { return nil }
        let palette = PeleDiagramProvider.peleTheme(for: theme, appearance: appearance)
        let rendered = await runtime.render(source: source, targetWidth: width,
                                               foreground: palette["fg"] ?? "#111111",
                                               grid: palette["border"] ?? "#dddddd",
                                               fontSize: theme.bodyFont.pointSize,
                                               markColor: appearance == .dark ? "#3987e5" : "#2a78d6")
        guard !Task.isCancelled else { return nil }
        guard let result = rendered else { failed = key; return nil }
        failed = nil
        if let old = cache.updateValue(result, forKey: key) { cachedBytes -= old.svg.utf8.count }
        cachedBytes += result.svg.utf8.count
        touch(key)
        while lru.count > 32 || cachedBytes > 8_388_608 {
            let victim = lru.removeFirst()
            if let removed = cache.removeValue(forKey: victim) { cachedBytes -= removed.svg.utf8.count }
        }
        return result
    }

    private func touch(_ key: Key) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }
}

/// A deliberately bounded static profile, checked before entering JavaScript.
/// Resource URLs, generators and interactive bindings are outside this profile.
/// Bounded expressions are checked against Vega's AST before compilation and
/// evaluated by the official interpreter, without dynamic code generation.
enum VegaLiteSpecPolicy {
    static let maxSourceBytes = 2_097_152
    private static let transforms: Set<String> = [
        "aggregate", "joinaggregate", "bin", "timeUnit", "filter", "calculate", "window", "fold", "stack", "sample"
    ]
    private static let forbidden: Set<String> = [
        "url", "href", "expr", "signal", "labelExpr", "bind", "select",
        "sequence", "density", "loess", "regression", "graticule", "sphere", "lookup",
        "impute", "pivot", "flatten", "projection", "__proto__", "constructor", "prototype"
    ]

    static func accepts(_ source: String) -> Bool {
        guard source.utf8.count <= maxSourceBytes,
              let data = source.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["mark"] != nil || root["layer"] != nil || root["facet"] != nil ||
                root["repeat"] != nil || root["hconcat"] != nil || root["vconcat"] != nil || root["concat"] != nil
        else { return false }
        var policy = Inspection()
        return policy.visit(root, depth: 0) &&
            policy.tuples <= 4_096 && policy.compositions <= 32 &&
            max(policy.tuples, 1) * max(policy.compositions, 1) * policy.expansion <= 20_000 &&
            (!policy.faceted || policy.tuples <= 128)
    }

    private static func isDeclarativePredicate(_ value: Any, depth: Int = 0) -> Bool {
        guard depth <= 32 else { return false }
        if let expression = value as? String { return !expression.isEmpty && expression.utf8.count <= 8_192 }
        guard let object = value as? [String: Any], !object.isEmpty else { return false }
        for key in ["and", "or"] {
            if let children = object[key] {
                guard let children = children as? [Any], !children.isEmpty,
                      children.allSatisfy({ isDeclarativePredicate($0, depth: depth + 1) }) else { return false }
            }
        }
        if let child = object["not"], !isDeclarativePredicate(child, depth: depth + 1) { return false }
        return object["field"] is String || object["param"] is String ||
            object["and"] != nil || object["or"] != nil || object["not"] != nil
    }

    private struct Inspection {
        var nodes = 0
        var tuples = 0
        var compositions = 1
        var expansion = 1
        var faceted = false

        mutating func multiplyCompositions(by count: Int) -> Bool {
            guard count > 0, compositions <= 32 / count else { return false }
            compositions *= count
            return true
        }

        mutating func visit(_ value: Any, depth: Int, dataValue: Bool = false, dataDefinition: Bool = false) -> Bool {
            nodes += 1
            guard nodes <= 400_000, depth <= 32 else { return false }
            if let string = value as? String { return string.utf8.count <= 8_192 }
            if let number = value as? NSNumber {
                let n = number.doubleValue
                return n.isFinite && abs(n) <= 1_000_000_000_000
            }
            if value is NSNull { return true }
            if let array = value as? [Any] {
                guard array.count <= 4_096 else { return false }
                for element in array where !visit(element, depth: depth + 1, dataValue: dataValue) { return false }
                return true
            }
            guard let object = value as? [String: Any] else { return false }
            // Inline records are plain JSON values, never interpreted as spec
            // keys (a column called "url" is perfectly valid data).
            if !dataValue {
                guard forbidden.isDisjoint(with: object.keys) else { return false }
                // `values` can repeat a whole group in every joined/windowed
                // row, allocating quadratic SVG text before output-size checks.
                guard object["op"] as? String != "values",
                      object["aggregate"] as? String != "values" else { return false }
                if object["facet"] != nil { faceted = true }
                if let mark = object["mark"] as? String, ["image", "geoshape"].contains(mark) { return false }
                if let mark = object["mark"] as? [String: Any], ["image", "geoshape"].contains(mark["type"] as? String ?? "") { return false }
                if let type = object["type"] as? String, ["image", "geoshape"].contains(type) { return false }
                for key in ["width", "height"] {
                    if let size = object[key] as? NSNumber, !(1...2_048).contains(size.doubleValue) { return false }
                    if let size = object[key] as? String, size != "container" { return false }
                }
                if let step = object["step"] as? NSNumber, !(1...2_048).contains(step.doubleValue) { return false }
                if let count = object["tickCount"] {
                    guard let count = count as? NSNumber, (1...100).contains(count.doubleValue) else { return false }
                }
                for (key, value) in object {
                    let lower = key.lowercased()
                    if lower.hasSuffix("fontsize") || lower.hasSuffix("lineheight") {
                        guard let size = value as? NSNumber, (1...256).contains(size.doubleValue) else { return false }
                    }
                    if ["padding", "offset", "titlePadding", "labelPadding", "tickSize", "spacing"].contains(key),
                       let size = value as? NSNumber, abs(size.doubleValue) > 256 { return false }
                    if key == "format", let format = value as? String {
                        guard format.utf8.count <= 128,
                              format.range(of: "[0-9]{4,}", options: .regularExpression) == nil else { return false }
                    }
                }
                if let count = object["count"] {
                    guard let count = count as? NSNumber, (1...256).contains(count.doubleValue) else { return false }
                }
                if let bins = object["bins"] {
                    guard let bins = bins as? [NSNumber], bins.count <= 256 else { return false }
                }
                if let bin = object["bin"] {
                    if let options = bin as? [String: Any] {
                        guard Set(options.keys).isSubset(of: ["maxbins"]) else { return false }
                    } else if let mode = bin as? String {
                        guard mode == "binned" else { return false }
                    } else if let flag = bin as? NSNumber {
                        guard CFGetTypeID(flag) == CFBooleanGetTypeID() else { return false }
                    } else { return false }
                }
                if let count = object["maxbins"] {
                    guard let count = count as? NSNumber, (1...256).contains(count.doubleValue) else { return false }
                }
                if let data = object["data"] {
                    guard let definition = data as? [String: Any],
                          definition["values"] is [Any] || definition["name"] is String else { return false }
                }
                if let expression = object["calculate"] {
                    guard let expression = expression as? String, !expression.isEmpty,
                          expression.utf8.count <= 8_192 else { return false }
                }
                for key in ["filter", "test"] {
                    if let predicate = object[key], !VegaLiteSpecPolicy.isDeclarativePredicate(predicate) { return false }
                }
                if let fold = object["fold"] as? [Any] {
                    guard !fold.isEmpty, fold.count <= 32, expansion <= 32 / fold.count else { return false }
                    expansion *= fold.count
                }
                if let transforms = object["transform"] as? [[String: Any]] {
                    guard transforms.count <= 32,
                          transforms.allSatisfy({ !Set($0.keys).isDisjoint(with: VegaLiteSpecPolicy.transforms) }) else { return false }
                } else if object["transform"] != nil { return false }
                for key in ["layer", "hconcat", "vconcat", "concat"] {
                    if let array = object[key] as? [Any] {
                        guard !array.isEmpty, array.count <= 16 else { return false }
                        guard multiplyCompositions(by: array.count) else { return false }
                    }
                }
                if let reference = object["repeat"] as? String {
                    // Encoding field references select an enclosing repeat;
                    // they do not introduce another composition.
                    guard ["row", "column", "layer"].contains(reference) else { return false }
                } else if let repeatSpec = object["repeat"] {
                    let repeats: Int
                    if let array = repeatSpec as? [Any] { repeats = array.count }
                    else if let repeatObject = repeatSpec as? [String: [Any]] {
                        guard !repeatObject.isEmpty, Set(repeatObject.keys).isSubset(of: ["row", "column", "layer"]) else { return false }
                        var product = 1
                        for values in repeatObject.values {
                            guard !values.isEmpty, values.count <= 16, product <= 16 / values.count else { return false }
                            product *= values.count
                        }
                        repeats = product
                    } else { return false }
                    guard repeats > 0, repeats <= 16 else { return false }
                    guard multiplyCompositions(by: repeats) else { return false }
                }
            }
            for (key, child) in object {
                guard key.utf8.count <= 256 else { return false }
                if !dataValue && key == "datasets" {
                    guard let datasets = child as? [String: [Any]] else { return false }
                    for rows in datasets.values {
                        tuples += rows.count
                        guard visit(rows, depth: depth + 1, dataValue: true) else { return false }
                    }
                } else if !dataValue && dataDefinition && key == "values", let rows = child as? [Any] {
                    tuples += rows.count
                    guard visit(rows, depth: depth + 1, dataValue: true) else { return false }
                } else if !visit(child, depth: depth + 1, dataValue: dataValue,
                                 dataDefinition: !dataValue && key == "data") { return false }
            }
            return true
        }
    }
}
#endif
