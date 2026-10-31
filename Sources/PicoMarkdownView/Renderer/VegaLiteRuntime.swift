#if os(macOS)
import Foundation
import JavaScriptCore
import CoreText

/// A serial owner for all JSContext/JSValue state. The only values crossing
/// actor boundaries are strings, numbers and the completed SVG result.
actor VegaLiteRuntime {
    static let shared: VegaLiteRuntime? = VegaLiteRuntime()
    private let context: JSContext
    private let renderFunction: JSValue

    private init?() {
        guard let context = JSContext() else { return nil }
        // Do not log JavaScript exceptions: compiler messages can quote chat
        // data. Failures simply retain the source code presentation.
        context.exceptionHandler = { context, exception in context?.exception = exception }
        var measurements: [MeasureKey: Double] = [:]
        let measure: @convention(block) (String, Double, String, String, String) -> Double = { text, size, family, weight, style in
            guard text.utf8.count <= 8_192, size.isFinite, size > 0, size <= 512 else { return 0 }
            let key = MeasureKey(text: text, size: size, family: family, weight: weight, style: style)
            if let cached = measurements[key] { return cached }
            let bold = weight == "bold" || (Double(weight) ?? 0) >= 600
            let font = PeleSVGFonts.font(family: family, size: CGFloat(size), bold: bold,
                                         italic: style == "italic" || style == "oblique", dialect: .vega)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            if measurements.count >= 4_096 { measurements.removeAll(keepingCapacity: true) }
            measurements[key] = width
            return width
        }
        context.setObject(measure, forKeyedSubscript: "picoVegaMeasureText" as NSString)
        context.evaluateScript("""
        var structuredClone = function(value) { return value === undefined ? undefined : JSON.parse(JSON.stringify(value)); };
        var setTimeout = function() { throw new Error('Asynchronous resources are unsupported'); };
        var setInterval = setTimeout, clearTimeout = function() {}, clearInterval = clearTimeout;
        var console = {log:function(){},warn:function(){},error:function(){},debug:function(){},info:function(){}};
        """)
        for name in ["vega-6.2.0.min", "vega-lite-6.5.0.min", "vega-interpreter-1.2.1", "pico-vega-lite"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "js"),
                  let script = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            context.exception = nil
            context.evaluateScript(script, withSourceURL: url)
            guard context.exception == nil else { return nil }
        }
        guard let render = context.objectForKeyedSubscript("picoRenderVegaLite"), !render.isUndefined else { return nil }
        self.context = context
        self.renderFunction = render
    }

    private struct MeasureKey: Hashable {
        var text: String
        var size: Double
        var family: String
        var weight: String
        var style: String
    }

    func render(source: String, targetWidth: CGFloat?, foreground: String, grid: String, fontSize: CGFloat, markColor: String) -> VegaLiteRenderResult? {
        guard !Task.isCancelled, fontSize.isFinite, fontSize > 0, VegaLiteSpecPolicy.accepts(source) else { return nil }
        var options: [String: Any] = ["foreground": foreground, "grid": grid, "markColor": markColor, "fontSize": min(fontSize, 256)]
        if let width = targetWidth {
            guard width.isFinite, width > 0, width <= 2_048 else { return nil }
            options["width"] = width
        }
        context.exception = nil
        // JavaScriptCore drains native Promise jobs before this call returns.
        // The supported inline-only profile completes here, without timers,
        // polling, a run loop, or any thread blocking. Pending jobs fail closed.
        guard let value = renderFunction.call(withArguments: [source, options]),
              context.exception == nil,
              let result = value.toDictionary() as? [String: Any],
              result["status"] as? String == "done",
              let svg = result["svg"] as? String, svg.utf8.count <= 2_097_152,
              let document = PeleSVGDocument(svg: svg, dialect: .vega),
              document.width <= 4_096, document.height <= 4_096,
              document.width * document.height <= 8_388_608
        else { return nil }
        return VegaLiteRenderResult(svg: svg, intrinsicSize: CGSize(width: document.width, height: document.height))
    }
}
#endif
