import Foundation
import os

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// Options for one Pele render.
///
/// `theme` holds values for Pele's `--pele-*` CSS variables keyed without
/// the prefix (`bg`, `fg`, `muted`, `line`, `surface`, `surface-alt`,
/// `border`, `accent`, `critical`, `series-1` … `series-8`, `font`,
/// `font-mono`, `radius`, `title-weight`, `heading-weight`, `bold-weight`).
/// Every value is substituted into the SVG literally, so callers pass
/// concrete colors (`#rrggbb`), lengths (`4px`) or font names. Variables
/// that are not supplied keep Pele's own fallback.
struct PeleRenderOptions: Sendable, Hashable {
    /// Label font size in points.
    var fontSize: CGFloat = 14
    /// Family Pele measures labels in. Only a hint for its built-in metrics;
    /// the SVG itself is drawn with whatever font the host resolves.
    var fontFamily: String? = nil
    /// Width available to the diagram, in points. Diagram types that can
    /// draw themselves narrower do, and wide flowcharts may turn vertical.
    var maxWidth: CGFloat? = nil
    var theme: [String: String] = [:]

    init(fontSize: CGFloat = 14,
         fontFamily: String? = nil,
         maxWidth: CGFloat? = nil,
         theme: [String: String] = [:]) {
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.maxWidth = maxWidth
        self.theme = theme
    }
}

/// A rendered diagram: self-contained SVG markup with every CSS variable
/// already resolved, plus its intrinsic size in points.
struct PeleRenderResult: Sendable, Equatable {
    var svg: String
    var width: CGFloat
    var height: CGFloat
    /// Pele's diagram type (`flowchart`, `sequence`, `pie`, …).
    var type: String
}

/// Why Pele could not draw a source. `code` is Pele's error code
/// (`unsupported-diagram`, `parse`, `limit`, …) or `error` for anything
/// else; `message` is Pele's own description, suitable for diagnostics.
struct PeleRenderError: Error, Sendable, Equatable {
    var code: String
    var message: String
}

// MARK: - Renderer Actor

#if canImport(JavaScriptCore)
/// Runs the bundled Pele build (https://pele.run) in JavaScriptCore and turns
/// Mermaid source into SVG. Pele is synchronous, dependency-free and does not
/// touch the DOM, so a plain `JSContext` is enough — the same arrangement
/// `PrismTokenizer` uses for syntax highlighting.
///
/// One context is shared process-wide behind this actor; renders are
/// serialized on it, which is fine because a diagram takes a few
/// milliseconds. Rasterizing the SVG is a separate concern.
actor PeleRenderer {
    private let context: JSContext
    private let renderFunction: JSValue
    private static let logger = Logger(subsystem: "com.picomarkdown", category: "PeleRenderer")

    static let shared: PeleRenderer? = PeleRenderer()

    private init?() {
        guard let context = JSContext() else {
            Self.logger.error("Diagram rendering unavailable: JavaScriptCore initialization failed")
            return nil
        }

        guard
            let bundleURL = Bundle.module.url(forResource: "pele-bundle", withExtension: "js"),
            let script = try? String(contentsOf: bundleURL, encoding: .utf8)
        else {
            Self.logger.error("Diagram rendering unavailable: Pele JavaScript bundle could not be loaded")
            return nil
        }

        context.exceptionHandler = { _, exception in
            let description = exception?.toString() ?? "unknown"
            Self.logger.error("Pele JavaScript exception: \(description, privacy: .public)")
        }
        context.evaluateScript(script)

        guard
            let renderFunction = context.objectForKeyedSubscript("renderDiagram"),
            !renderFunction.isUndefined
        else {
            Self.logger.error("Diagram rendering unavailable: Pele bundle did not define renderDiagram")
            return nil
        }

        self.context = context
        self.renderFunction = renderFunction
    }

    /// Renders Mermaid `source` to SVG. Throws `PeleRenderError` when Pele
    /// rejects the source (unknown diagram type, syntax error, size limit).
    func render(_ source: String, options: PeleRenderOptions = PeleRenderOptions()) throws(PeleRenderError) -> PeleRenderResult {
        var jsOptions: [String: Any] = ["theme": options.theme, "fontSize": options.fontSize]
        if let fontFamily = options.fontFamily {
            jsOptions["fontFamily"] = fontFamily
        }
        if let maxWidth = options.maxWidth, maxWidth > 0 {
            jsOptions["maxWidth"] = maxWidth
        }

        guard
            let value = renderFunction.call(withArguments: [source, jsOptions]),
            let result = value.toDictionary() as? [String: Any]
        else {
            throw PeleRenderError(code: "error", message: "Pele returned no result")
        }

        guard result["ok"] as? Bool == true else {
            throw PeleRenderError(code: result["code"] as? String ?? "error",
                                  message: result["message"] as? String ?? "Pele could not render the diagram")
        }

        guard
            let svg = result["svg"] as? String,
            let width = result["width"] as? NSNumber,
            let height = result["height"] as? NSNumber
        else {
            throw PeleRenderError(code: "error", message: "Pele returned an incomplete result")
        }

        return PeleRenderResult(svg: svg,
                                width: CGFloat(width.doubleValue),
                                height: CGFloat(height.doubleValue),
                                type: result["type"] as? String ?? "")
    }
}
#else
actor PeleRenderer {
    static let shared: PeleRenderer? = nil

    func render(_ source: String, options: PeleRenderOptions = PeleRenderOptions()) throws(PeleRenderError) -> PeleRenderResult {
        throw PeleRenderError(code: "error", message: "JavaScriptCore is unavailable on this platform")
    }
}
#endif
