import Foundation
import CoreGraphics
import CoreText

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Drawing

extension PeleSVGDocument {
    /// Largest bitmap `makeCGImage` will allocate, in pixels.
    static let maxRasterPixels = 40_000_000

    /// Rasterizes the drawing at `scale` pixels per point. The bitmap is
    /// transparent unless `background` is given.
    func makeCGImage(scale: CGFloat, background: CGColor? = nil) -> CGImage? {
        guard scale > 0, scale.isFinite else { return nil }
        // Bounds are checked in floating point first: a document can declare
        // a size whose pixel count does not fit an Int.
        let scaledWidth = (width * scale).rounded(.up)
        let scaledHeight = (height * scale).rounded(.up)
        guard scaledWidth >= 1, scaledHeight >= 1, scaledWidth.isFinite, scaledHeight.isFinite,
              scaledWidth * scaledHeight <= CGFloat(Self.maxRasterPixels) else { return nil }
        let pixelWidth = Int(scaledWidth)
        let pixelHeight = Int(scaledHeight)

        guard let context = CGContext(data: nil,
                                      width: pixelWidth,
                                      height: pixelHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: PeleSVGValue.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }

        // CoreGraphics bitmaps have their origin at the bottom left; SVG has
        // it at the top left.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: CGFloat(pixelWidth) / width, y: -CGFloat(pixelHeight) / height)
        draw(in: context)
        return context.makeImage()
    }

    /// A platform image of the drawing, sized in points, backed by a bitmap
    /// rendered at `scale` pixels per point.
    func makeImage(scale: CGFloat) -> MarkdownImage? {
        guard let cgImage = makeCGImage(scale: scale) else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        #endif
    }

    /// Draws into a context whose user space is points with the y axis
    /// pointing down and the origin at the drawing's top-left corner.
    /// `strokesAsFills` is used by the macOS hosted vector canvas to avoid
    /// QuartzCore's accelerated line-stroking backend. Outline geometry stays
    /// vector based; bitmap rendering keeps the original stroke path.
    func draw(in context: CGContext, strokesAsFills: Bool = false) {
        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(true)
        // Glyphs are flipped back upright inside the y-down user space.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.scaleBy(x: width / viewBox.width, y: height / viewBox.height)
        context.translateBy(x: -viewBox.minX, y: -viewBox.minY)

        var style = PeleSVGStyle()
        style.apply(element: root)
        drawChildren(of: root, style: style, in: context, strokesAsFills: strokesAsFills)
        context.restoreGState()
    }

    private static let skippedElements: Set<String> = [
        "defs", "title", "desc", "metadata", "linearGradient", "radialGradient", "stop",
        "image", "foreignObject", "style", "script", "clipPath", "mask", "filter", "pattern", "marker", "symbol", "use"
    ]

    private func drawChildren(of element: PeleSVGElement, style: PeleSVGStyle, in context: CGContext, strokesAsFills: Bool) {
        for case let .element(child) in element.children {
            draw(child, parentStyle: style, in: context, strokesAsFills: strokesAsFills)
        }
    }

    private func draw(_ element: PeleSVGElement, parentStyle: PeleSVGStyle, in context: CGContext, strokesAsFills: Bool) {
        guard !Self.skippedElements.contains(element.name) else { return }
        #if os(macOS)
        if dialect == .vega, VegaSVGCompatibility.isHidden(element) { return }
        #endif
        var style = parentStyle
        style.apply(element: element)

        context.saveGState()
        defer { context.restoreGState() }

        if let transform = element.attributes["transform"] {
            context.concatenate(PeleSVGValue.transform(transform))
        }

        #if os(macOS)
        if dialect == .vega, let reference = element.attributes["clip-path"],
           let id = VegaSVGCompatibility.localReference(reference), let path = vegaClipPaths[id] {
            context.addPath(path)
            context.clip()
        }
        #endif

        switch element.name {
        case "g", "a", "switch":
            withGroupOpacity(style.opacity, in: context) {
                drawChildren(of: element, style: style, in: context, strokesAsFills: strokesAsFills)
            }
        case "svg":
            applyNestedViewport(of: element, in: context)
            withGroupOpacity(style.opacity, in: context) {
                drawChildren(of: element, style: style, in: context, strokesAsFills: strokesAsFills)
            }
        case "path", "rect", "circle", "ellipse", "line", "polygon", "polyline":
            if let path = makePath(for: element, style: style) {
                // `opacity` applies to the shape as a whole, so fill and
                // stroke must be composited together, not each at half.
                withGroupOpacity(style.opacity, in: context) {
                    paint(path, style: style, in: context, strokesAsFills: strokesAsFills)
                }
            }
        case "text":
            withGroupOpacity(style.opacity, in: context) {
                drawText(element, style: style, in: context, strokesAsFills: strokesAsFills)
            }
        default:
            break
        }
    }

    private func withGroupOpacity(_ opacity: CGFloat, in context: CGContext, _ body: () -> Void) {
        guard opacity < 1 else {
            body()
            return
        }
        context.saveGState()
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Nested `<svg x y width height viewBox>` (Pele's icons): translate to
    /// the viewport and fit the view box inside it, centered, as
    /// `preserveAspectRatio="xMidYMid meet"` would.
    private func applyNestedViewport(of element: PeleSVGElement, in context: CGContext) {
        context.translateBy(x: element.length("x", default: 0), y: element.length("y", default: 0))
        let box = element.attributes["viewBox"].map(PeleSVGValue.numberList) ?? []
        guard box.count == 4, box[2] > 0, box[3] > 0 else { return }
        let viewportWidth = element.length("width", default: box[2])
        let viewportHeight = element.length("height", default: box[3])
        let scale = min(viewportWidth / box[2], viewportHeight / box[3])
        context.translateBy(x: (viewportWidth - box[2] * scale) / 2, y: (viewportHeight - box[3] * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box[0], y: -box[1])
    }

    // MARK: Shapes

    private func makePath(for element: PeleSVGElement, style: PeleSVGStyle) -> CGPath? {
        switch element.name {
        case "path":
            return element.attributes["d"].flatMap(PeleSVGPath.parse)
        case "rect":
            let rect = CGRect(x: element.length("x", default: 0),
                              y: element.length("y", default: 0),
                              width: element.length("width", default: 0),
                              height: element.length("height", default: 0))
            guard rect.width > 0, rect.height > 0 else { return nil }
            // `style.rx`/`ry` already resolve the attribute and any `style`
            // declaration in the right precedence.
            var rx = style.rx
            var ry = style.ry
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let cornerWidth = min(max(rx ?? 0, 0), rect.width / 2)
            let cornerHeight = min(max(ry ?? 0, 0), rect.height / 2)
            if cornerWidth > 0, cornerHeight > 0 {
                return CGPath(roundedRect: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight, transform: nil)
            }
            return CGPath(rect: rect, transform: nil)
        case "circle":
            let radius = element.length("r", default: 0)
            guard radius > 0 else { return nil }
            let center = CGPoint(x: element.length("cx", default: 0), y: element.length("cy", default: 0))
            return CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        case "ellipse":
            let rx = element.length("rx", default: 0)
            let ry = element.length("ry", default: 0)
            guard rx > 0, ry > 0 else { return nil }
            let center = CGPoint(x: element.length("cx", default: 0), y: element.length("cy", default: 0))
            return CGPath(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2), transform: nil)
        case "line":
            let path = CGMutablePath()
            path.move(to: CGPoint(x: element.length("x1", default: 0), y: element.length("y1", default: 0)))
            path.addLine(to: CGPoint(x: element.length("x2", default: 0), y: element.length("y2", default: 0)))
            return path
        case "polygon", "polyline":
            let numbers = element.attributes["points"].map(PeleSVGValue.numberList) ?? []
            guard numbers.count >= 4 else { return nil }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            var index = 2
            while index + 1 < numbers.count {
                path.addLine(to: CGPoint(x: numbers[index], y: numbers[index + 1]))
                index += 2
            }
            if element.name == "polygon" { path.closeSubpath() }
            return path
        default:
            return nil
        }
    }

    private func paint(_ path: CGPath, style: PeleSVGStyle, in context: CGContext, strokesAsFills: Bool) {
        if case let .gradient(id, _) = style.fill, let gradient = gradients[id] {
            fill(path, with: gradient, opacity: style.fillOpacity, in: context)
        } else if let color = style.resolvedColor(style.fill, opacity: style.fillOpacity) {
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
        }

        if style.strokeWidth > 0, let color = style.resolvedColor(style.stroke, opacity: style.strokeOpacity) {
            context.setStrokeColor(color)
            context.setLineWidth(style.strokeWidth)
            context.setLineCap(style.lineCap)
            context.setLineJoin(style.lineJoin)
            context.setLineDash(phase: style.dashOffset, lengths: style.dashes)
            context.addPath(path)
            strokeCurrentPath(in: context, color: color, strokesAsFills: strokesAsFills)
        }
    }

    private func strokeCurrentPath(in context: CGContext, color: CGColor, strokesAsFills: Bool) {
        #if os(macOS)
        if strokesAsFills {
            // CoreGraphics expands with the current width, dash, cap, join
            // and transform. Filling the result preserves the stroke without
            // submitting line primitives when scrolling clips the drawing.
            context.replacePathWithStrokedPath()
            if !context.isPathEmpty {
                context.setFillColor(color)
                context.fillPath()
            }
            return
        }
        #endif
        context.strokePath()
    }

    private func fill(_ path: CGPath, with gradient: PeleSVGGradient, opacity: CGFloat, in context: CGContext) {
        let colors = gradient.stops.map { stop -> CGColor in
            let alpha = stop.color.alpha * opacity
            return alpha >= 1 ? stop.color : (stop.color.copy(alpha: alpha) ?? stop.color)
        }
        guard let cgGradient = CGGradient(colorsSpace: PeleSVGValue.colorSpace,
                                          colors: colors as CFArray,
                                          locations: gradient.stops.map(\.offset)) else { return }
        context.saveGState()
        context.addPath(path)
        context.clip()
        var start = gradient.start
        var end = gradient.end
        if !gradient.userSpace {
            let box = path.boundingBoxOfPath
            start = CGPoint(x: box.minX + start.x * box.width, y: box.minY + start.y * box.height)
            end = CGPoint(x: box.minX + end.x * box.width, y: box.minY + end.y * box.height)
        }
        context.drawLinearGradient(cgGradient, start: start, end: end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    // MARK: Text

    private struct TextRun {
        var text: String
        var style: PeleSVGStyle
        var x: CGFloat?
        var y: CGFloat?
        var dx: CGFloat = 0
        var dy: CGFloat = 0
    }

    /// Draws `<text>` with its `<tspan>` children. Runs are grouped into
    /// chunks at every absolute `x`/`y` (or Vega relative `dx`/`dy`);
    /// `text-anchor` aligns a whole chunk,
    /// so a line made of differently styled spans stays centered as one.
    private func drawText(_ element: PeleSVGElement, style: PeleSVGStyle, in context: CGContext, strokesAsFills: Bool) {
        var runs: [TextRun] = []
        var pending = (x: element.length("x"), y: element.length("y"))
        collectRuns(of: element, style: style, pending: &pending, into: &runs)
        #if os(macOS)
        if dialect == .vega, !runs.isEmpty {
            runs[0].dx += element.length("dx", default: 0)
            runs[0].dy += element.length("dy", default: 0)
        }
        #endif
        runs = normalizeWhitespace(runs, preserve: style.preserveSpace)
        guard !runs.isEmpty else { return }

        var pen = CGPoint.zero
        var index = 0
        while index < runs.count {
            var next = index + 1
            while next < runs.count, runs[next].x == nil, runs[next].y == nil,
                  runs[next].dx == 0, runs[next].dy == 0 { next += 1 }
            let chunk = runs[index..<next]

            if let x = chunk.first?.x { pen.x = x }
            if let y = chunk.first?.y { pen.y = y }
            pen.x += chunk.first?.dx ?? 0
            pen.y += chunk.first?.dy ?? 0

            let lines = chunk.map(makeLine)
            let total = lines.reduce(CGFloat(0)) { $0 + $1.width }
            var x = pen.x
            switch chunk.first?.style.textAnchor ?? .start {
            case .start: break
            case .middle: x -= total / 2
            case .end: x -= total
            }

            for (run, line) in zip(chunk, lines) {
                let shift = run.style.baselineShift * style.fontSize
                let baseline = pen.y - shift
                context.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(line.line, context)
                if run.style.strikethrough, line.width > 0,
                   let color = run.style.resolvedColor(run.style.fill, opacity: run.style.fillOpacity) {
                    // CoreText draws underlines but not strike-throughs.
                    let font = line.font
                    let y = baseline - CTFontGetXHeight(font) / 2
                    context.setStrokeColor(color)
                    context.setLineWidth(max(CTFontGetUnderlineThickness(font), 1))
                    context.setLineDash(phase: 0, lengths: [])
                    context.move(to: CGPoint(x: x, y: y))
                    context.addLine(to: CGPoint(x: x + line.width, y: y))
                    strokeCurrentPath(in: context, color: color, strokesAsFills: strokesAsFills)
                }
                x += line.width
            }
            pen.x = x
            index = next
        }
    }

    private func collectRuns(of element: PeleSVGElement,
                             style: PeleSVGStyle,
                             pending: inout (x: CGFloat?, y: CGFloat?),
                             into runs: inout [TextRun]) {
        for child in element.children {
            switch child {
            case let .text(text):
                runs.append(TextRun(text: text, style: style, x: pending.x, y: pending.y))
                pending = (nil, nil)
            case let .element(span) where span.name == "tspan" || span.name == "a":
                var spanStyle = style
                spanStyle.apply(element: span)
                var spanPending = (x: span.length("x") ?? pending.x, y: span.length("y") ?? pending.y)
                #if os(macOS)
                let start = runs.count
                #endif
                collectRuns(of: span, style: spanStyle, pending: &spanPending, into: &runs)
                #if os(macOS)
                if dialect == .vega, start < runs.count {
                    runs[start].dx += span.length("dx", default: 0)
                    runs[start].dy += span.length("dy", default: 0)
                }
                #endif
                if spanPending.x == nil, spanPending.y == nil {
                    // The span emitted a run that consumed the position.
                    pending = (nil, nil)
                }
            default:
                continue
            }
        }
    }

    /// Without `xml:space="preserve"`, SVG collapses runs of XML whitespace
    /// (space, tab, newline, return — not non-breaking spaces) to one space
    /// and trims the ends of the whole text element.
    private func normalizeWhitespace(_ runs: [TextRun], preserve: Bool) -> [TextRun] {
        var result = runs
        if !preserve {
            for index in result.indices {
                var collapsed = ""
                var previousWasSpace = false
                for character in result[index].text {
                    if character == " " || character == "\t" || character == "\n" || character == "\r" {
                        if !previousWasSpace { collapsed.append(" ") }
                        previousWasSpace = true
                    } else {
                        collapsed.append(character)
                        previousWasSpace = false
                    }
                }
                result[index].text = collapsed
            }
            if !result.isEmpty {
                result[0].text = String(result[0].text.drop(while: { $0 == " " }))
                let last = result.count - 1
                while result[last].text.hasSuffix(" ") { result[last].text.removeLast() }
            }
        }
        return result.filter { !$0.text.isEmpty }
    }

    private struct MeasuredLine {
        var line: CTLine
        var width: CGFloat
        var font: CTFont
    }

    private func makeLine(for run: TextRun) -> MeasuredLine {
        let font = PeleSVGFonts.font(family: run.style.fontFamily,
                                     size: run.style.fontSize,
                                     bold: run.style.bold,
                                     italic: run.style.italic,
                                     dialect: dialect)
        let color = run.style.resolvedColor(run.style.fill, opacity: run.style.fillOpacity)
            ?? PeleSVGValue.rgba(0, 0, 0, 0)
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        if run.style.letterSpacing != 0 {
            attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = run.style.letterSpacing
        }
        if run.style.underline {
            attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue
            attributes[NSAttributedString.Key(kCTUnderlineColorAttributeName as String)] = color
        }
        // Outlined labels (sankey `labelStyle: outlined`) are a stroked,
        // unfilled text pass behind the filled one. CoreText takes the
        // stroke width as a percentage of the font size; a negative value
        // strokes and fills, a positive one strokes only.
        if run.style.strokeWidth > 0, run.style.fontSize > 0,
           let strokeColor = run.style.resolvedColor(run.style.stroke, opacity: run.style.strokeOpacity) {
            let percent = run.style.strokeWidth / run.style.fontSize * 100
            let hasFill = run.style.resolvedColor(run.style.fill, opacity: run.style.fillOpacity) != nil
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = strokeColor
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = hasFill ? -percent : percent
        }
        let attributed = NSMutableAttributedString(string: run.text, attributes: attributes)
        if run.style.wordSpacing != 0 {
            // CoreText has no word-spacing; widen the advance of each space.
            let text = run.text as NSString
            var search = NSRange(location: 0, length: text.length)
            while search.length > 0 {
                let found = text.rangeOfCharacter(from: .whitespaces, range: search)
                guard found.location != NSNotFound else { break }
                attributed.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String),
                                        value: run.style.letterSpacing + run.style.wordSpacing,
                                        range: found)
                search = NSRange(location: found.upperBound, length: text.length - found.upperBound)
            }
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return MeasuredLine(line: line, width: width, font: font)
    }
}

// MARK: - Fonts

/// Maps the CSS font families in Pele's output to platform fonts. Generic
/// families become the system fonts, so diagrams match the surrounding
/// text; named families are used when installed.
enum PeleSVGFonts {
    static func font(family: String, size: CGFloat, bold: Bool, italic: Bool,
                     dialect: PeleSVGDocument.Dialect = .pele) -> CTFont {
        #if os(macOS)
        let family = dialect == .vega ? VegaSVGCompatibility.fontFamily(family) : family
        #endif
        let platformFont = platformFont(family: family, size: max(size, 1), bold: bold, italic: italic)
        return platformFont as CTFont
    }

    static func platformFont(family: String, size: CGFloat, bold: Bool, italic: Bool) -> MarkdownFont {
        let weight: MarkdownFont.Weight = bold ? .bold : .regular
        var base: MarkdownFont?
        for candidate in family.split(separator: ",") {
            let name = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")).lowercased()
            switch name {
            case "sans-serif", "system-ui", "-apple-system", "ui-sans-serif", "blinkmacsystemfont", "":
                base = MarkdownFont.systemFont(ofSize: size, weight: weight)
            case "monospace", "ui-monospace":
                base = MarkdownFont.monospacedSystemFont(ofSize: size, weight: weight)
            case "serif", "ui-serif":
                base = MarkdownFont.systemFont(ofSize: size, weight: weight)
                #if canImport(UIKit)
                if let descriptor = base?.fontDescriptor.withDesign(.serif) {
                    base = MarkdownFont(descriptor: descriptor, size: size)
                }
                #else
                if let descriptor = base?.fontDescriptor.withDesign(.serif) {
                    base = MarkdownFont(descriptor: descriptor, size: size) ?? base
                }
                #endif
            default:
                base = MarkdownFont(name: candidate.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")), size: size)
                if base != nil, bold {
                    base = applyTraits(to: base!, bold: true, italic: false, size: size)
                }
            }
            if base != nil { break }
        }
        let resolved = base ?? MarkdownFont.systemFont(ofSize: size, weight: weight)
        return italic ? applyTraits(to: resolved, bold: false, italic: true, size: size) : resolved
    }

    private static func applyTraits(to font: MarkdownFont, bold: Bool, italic: Bool, size: CGFloat) -> MarkdownFont {
        #if canImport(UIKit)
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return MarkdownFont(descriptor: descriptor, size: size)
        #else
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return MarkdownFont(descriptor: descriptor, size: size) ?? font
        #endif
    }
}
