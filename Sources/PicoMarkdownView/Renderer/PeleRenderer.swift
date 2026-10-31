import CoreText
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
    /// CSS family labels are measured in and, unless the theme sets `font`,
    /// drawn in. Generic families (`sans-serif`, `monospace`) map to the
    /// system fonts; see `PeleSVGFonts`.
    var fontFamily: String? = nil
    /// Width available to the diagram, in points. Diagram types that can
    /// draw themselves narrower do, and wide flowcharts may turn vertical.
    var maxWidth: CGFloat? = nil
    var theme: [String: String] = [:]
    /// Overrides applied after Pele identifies a diagram's type, so styling
    /// one family does not affect other diagrams or require source parsing.
    var diagramThemeOverrides: [String: [String: String]] = [:]
    /// Stable namespace for SVG definitions such as Sankey gradients.
    /// Omit it to retain Pele's legacy output.
    var idPrefix: String? = nil

    init(fontSize: CGFloat = 14,
         fontFamily: String? = nil,
         maxWidth: CGFloat? = nil,
         theme: [String: String] = [:],
         diagramThemeOverrides: [String: [String: String]] = [:],
         idPrefix: String? = nil) {
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.maxWidth = maxWidth
        self.theme = theme
        self.diagramThemeOverrides = diagramThemeOverrides
        self.idPrefix = idPrefix
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

// MARK: - Text measurement

/// Measures label text the way `PeleSVGDocument` will draw it, so Pele lays
/// nodes out around the real glyph widths instead of its built-in Arial
/// metrics. `style` is Pele's bit set (1 bold, 2 italic, 4 monospace,
/// 8 subscript, 16 superscript, 32 underline).
enum PeleTextMeasurer {
    static func width(of text: String, size: CGFloat, style: Int, family: String, monoFamily: String) -> CGFloat {
        guard !text.isEmpty, size > 0 else { return 0 }
        let bold = style & 1 != 0
        let italic = style & 2 != 0
        let mono = style & 4 != 0
        // Pele renders sub- and superscripts at `font-size="smaller"`.
        let effectiveSize = style & (8 | 16) != 0 ? size / 1.2 : size
        let font = PeleSVGFonts.font(family: mono ? monoFamily : family, size: effectiveSize, bold: bold, italic: italic)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
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
/// milliseconds. Rasterizing the SVG is a separate concern
/// (`PeleSVGDocument`).
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

        // Labels are measured in the fonts the rasterizer draws with. Pele
        // calls this once per word piece while wrapping; the cache keeps
        // repeat renders of the same diagram (width or appearance changes)
        // from re-shaping every label. It is only ever touched from the
        // actor's render calls, which JavaScriptCore runs synchronously.
        var cache: [MeasureKey: Double] = [:]
        let measure: @convention(block) (String, Double, Int, String, String) -> Double = { text, size, style, family, monoFamily in
            let key = MeasureKey(text: text, size: size, style: style, family: family, monoFamily: monoFamily)
            if let cached = cache[key] { return cached }
            let width = Double(PeleTextMeasurer.width(of: text, size: CGFloat(size), style: style, family: family, monoFamily: monoFamily))
            if cache.count >= Self.measureCacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = width
            return width
        }
        context.setObject(measure, forKeyedSubscript: "peleMeasureText" as NSString)

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

    private static let measureCacheLimit = 20_000

    private struct MeasureKey: Hashable {
        var text: String
        var size: Double
        var style: Int
        var family: String
        var monoFamily: String
    }

    /// Renders Mermaid `source` to SVG. Throws `PeleRenderError` when Pele
    /// rejects the source (unknown diagram type, syntax error, size limit).
    func render(_ source: String, options: PeleRenderOptions = PeleRenderOptions()) throws(PeleRenderError) -> PeleRenderResult {
        var jsOptions: [String: Any] = ["theme": options.theme, "fontSize": options.fontSize]
        if !options.diagramThemeOverrides.isEmpty {
            jsOptions["diagramThemeOverrides"] = options.diagramThemeOverrides
        }
        if let idPrefix = options.idPrefix {
            jsOptions["idPrefix"] = idPrefix
        }
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
