import CoreGraphics
import Foundation
import Testing
@testable import PicoMarkdownView

@Suite
struct PeleSVGRasterizerTests {
    // MARK: Helpers

    private struct Pixel: Equatable {
        var red: Int
        var green: Int
        var blue: Int
        var alpha: Int

        static let transparent = Pixel(red: 0, green: 0, blue: 0, alpha: 0)
        var isOpaqueRed: Bool { red > 200 && green < 50 && blue < 50 && alpha > 200 }
        var isOpaqueBlue: Bool { blue > 200 && red < 50 && green < 50 && alpha > 200 }
    }

    private struct Bitmap {
        let image: CGImage
        let bytes: [UInt8]

        init?(_ image: CGImage?) {
            guard let image, let data = image.dataProvider?.data as Data? else { return nil }
            self.image = image
            self.bytes = [UInt8](data)
        }

        /// Un-premultiplied RGBA at a pixel.
        func pixel(_ x: Int, _ y: Int) -> Pixel {
            let offset = y * image.bytesPerRow + x * 4
            let alpha = Int(bytes[offset + 3])
            guard alpha > 0 else { return .transparent }
            func channel(_ value: UInt8) -> Int { min(255, Int(value) * 255 / alpha) }
            return Pixel(red: channel(bytes[offset]), green: channel(bytes[offset + 1]), blue: channel(bytes[offset + 2]), alpha: alpha)
        }

        /// Horizontal extent of pixels in `row` that satisfy `predicate`.
        func columns(inRow row: Int, where predicate: (Pixel) -> Bool) -> ClosedRange<Int>? {
            var first: Int?
            var last: Int?
            for x in 0..<image.width where predicate(pixel(x, row)) {
                if first == nil { first = x }
                last = x
            }
            guard let first, let last else { return nil }
            return first...last
        }

        func count(where predicate: (Pixel) -> Bool) -> Int {
            var total = 0
            for y in 0..<image.height {
                for x in 0..<image.width where predicate(pixel(x, y)) {
                    total += 1
                }
            }
            return total
        }
    }

    private func rasterize(_ svg: String, scale: CGFloat = 1, dialect: PeleSVGDocument.Dialect = .pele) throws -> Bitmap {
        let document = try #require(PeleSVGDocument(svg: svg, dialect: dialect))
        return try #require(Bitmap(document.makeCGImage(scale: scale)))
    }

    private func bounds(of path: CGPath) -> CGRect {
        path.boundingBoxOfPath
    }

    // MARK: Path data

    @Test("Absolute and relative line commands with implicit repeats")
    func parsesLineCommands() throws {
        let path = try #require(PeleSVGPath.parse("M10 10 h 20 v 20 H 10 Z"))
        #expect(bounds(of: path) == CGRect(x: 10, y: 10, width: 20, height: 20))

        let implicit = try #require(PeleSVGPath.parse("M0,0 10,0 10,10 0,10z"))
        #expect(bounds(of: implicit) == CGRect(x: 0, y: 0, width: 10, height: 10))

        let compact = try #require(PeleSVGPath.parse("M0-5L10-5 10.5.5"))
        #expect(bounds(of: compact).minY == -5)
        #expect(abs(bounds(of: compact).maxX - 10.5) < 0.001)
    }

    @Test("Curves, smooth curves and arcs")
    func parsesCurvesAndArcs() throws {
        let cubic = try #require(PeleSVGPath.parse("M0,0 C0,10 10,10 10,0 S20,-10 20,0"))
        #expect(abs(bounds(of: cubic).maxX - 20) < 0.001)

        let quadratic = try #require(PeleSVGPath.parse("M0,0 Q5,10 10,0 T20,0"))
        #expect(abs(bounds(of: quadratic).maxX - 20) < 0.001)

        // A half circle of radius 10 from (0,0) to (20,0), sweeping below the x axis.
        let arc = try #require(PeleSVGPath.parse("M0,0 A10,10 0 0 1 20,0"))
        let box = bounds(of: arc)
        #expect(abs(box.width - 20) < 0.01)
        #expect(abs(box.height - 10) < 0.05, "arc should bulge by its radius: \(box)")
        #expect(box.minY < -9, "sweep flag 1 bends the arc toward negative y in SVG space")

        // Compact arc flags, as some generators write them.
        let compactFlags = try #require(PeleSVGPath.parse("M0,0A10,10 0 0120,0"))
        #expect(abs(bounds(of: compactFlags).width - 20) < 0.01)
    }

    @Test("Malformed path data is rejected rather than drawn partially wrong")
    func rejectsMalformedPaths() {
        #expect(PeleSVGPath.parse("") == nil)
        #expect(PeleSVGPath.parse("10 10 L 20 20") == nil, "must start with a command")
        #expect(PeleSVGPath.parse("M10 10 L 20") == nil, "missing coordinate")
        #expect(PeleSVGPath.parse("M10 10 X 20 20") == nil, "unknown command")
    }

    // MARK: Values

    @Test("Color syntaxes Mermaid styles can produce", arguments: [
        ("#f00", (255, 0, 0, 255)),
        ("#FF0000", (255, 0, 0, 255)),
        ("#ff000080", (255, 0, 0, 128)),
        ("rgb(0, 128, 255)", (0, 128, 255, 255)),
        ("rgba(0,0,255,0.5)", (0, 0, 255, 128)),
        ("red", (255, 0, 0, 255)),
        ("LightBlue", (173, 216, 230, 255)),
        ("transparent", (0, 0, 0, 0)),
        ("hsl(120, 100%, 50%)", (0, 255, 0, 255)),
        ("hsl(0 0% 50%)", (128, 128, 128, 255)),
        ("hsla(240, 100%, 50%, 0.5)", (0, 0, 255, 128)),
        ("hsl(390deg, 100%, 25%)", (128, 64, 0, 255))
    ])
    func parsesColors(input: String, expected: (Int, Int, Int, Int)) throws {
        let color = try #require(PeleSVGValue.color(input))
        let components = try #require(color.components)
        #expect(components.count == 4)
        #expect(Int((components[0] * 255).rounded()) == expected.0)
        #expect(Int((components[1] * 255).rounded()) == expected.1)
        #expect(Int((components[2] * 255).rounded()) == expected.2)
        #expect(Int((components[3] * 255).rounded()) == expected.3)
    }

    @Test("Unknown colors and paints")
    func rejectsUnknownColors() {
        #expect(PeleSVGValue.color("not-a-color") == nil)
        #expect(PeleSVGValue.color("#12") == nil)
        #expect(PeleSVGPaint.parse("none") == PeleSVGPaint.none)
        #expect(PeleSVGPaint.parse("currentColor") == .currentColor)
        #expect(PeleSVGPaint.parse("url(#grad) #abcdef") == .gradient(id: "grad", fallback: PeleSVGValue.color("#abcdef")))
    }

    @Test("Transforms compose left to right")
    func parsesTransforms() {
        let transform = PeleSVGValue.transform("translate(10,20) rotate(90)")
        let moved = CGPoint(x: 1, y: 0).applying(transform)
        #expect(abs(moved.x - 10) < 0.0001)
        #expect(abs(moved.y - 21) < 0.0001)

        let pivot = PeleSVGValue.transform("rotate(180 5 5)")
        let turned = CGPoint(x: 0, y: 0).applying(pivot)
        #expect(abs(turned.x - 10) < 0.0001)
        #expect(abs(turned.y - 10) < 0.0001)

        let scaled = CGPoint(x: 2, y: 3).applying(PeleSVGValue.transform("scale(2)"))
        #expect(scaled == CGPoint(x: 4, y: 6))
    }

    @Test("Style attribute wins over presentation attributes and inherits")
    func styleCascade() throws {
        let document = try #require(PeleSVGDocument(svg: """
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 10 10" fill="#00ff00" font-size="20">
        <g stroke-width="3" style="stroke-width:5px;opacity:0.5"><rect fill="#ff0000" style="fill:#0000ff" width="1" height="1"/></g>
        </svg>
        """))
        var style = PeleSVGStyle()
        style.apply(element: document.root)
        #expect(style.fill == .color(PeleSVGValue.color("#00ff00")!))
        #expect(style.fontSize == 20)

        guard case let .element(group) = document.root.children.first(where: { if case .element = $0 { return true } else { return false } })! else {
            Issue.record("missing group")
            return
        }
        style.apply(element: group)
        #expect(style.strokeWidth == 5)
        #expect(style.opacity == 0.5)
        #expect(style.fontSize == 20, "font size inherits")

        guard case let .element(rect) = group.children.first! else {
            Issue.record("missing rect")
            return
        }
        style.apply(element: rect)
        #expect(style.fill == .color(PeleSVGValue.color("#0000ff")!))
        #expect(style.opacity == 1, "opacity does not inherit")
        #expect(style.strokeWidth == 5, "stroke width inherits")
    }

    @Test("Dash arrays accept px lengths")
    func dashArrayLengths() throws {
        // What Pele writes for `style A stroke-dasharray:5px 2px`.
        let dashed = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="10">
        <line x1="0" y1="5" x2="100" y2="5" stroke="#ff0000" stroke-width="4" style="stroke-dasharray:5px 2px"/>
        </svg>
        """)
        let painted = try #require(dashed.columns(inRow: 5, where: \.isOpaqueRed))
        #expect(painted.lowerBound == 0)
        #expect(dashed.count(where: \.isOpaqueRed) < 100 * 4, "gaps were left between dashes")
        #expect(dashed.pixel(6, 5) == .transparent, "first gap at 5–7")

        var style = PeleSVGStyle()
        style.apply(element: PeleSVGElement(name: "line", attributes: ["stroke-dasharray": "3, 1.5px 2"]))
        #expect(style.dashes == [3, 1.5, 2])
        style.apply(element: PeleSVGElement(name: "line", attributes: ["stroke-dasharray": "none"]))
        #expect(style.dashes == [])
    }

    @Test("Font shorthand and relative sizes")
    func fontShorthand() throws {
        let document = try #require(PeleSVGDocument(svg: """
        <svg xmlns="http://www.w3.org/2000/svg" width="1" height="1" style="font:italic bold 14px sans-serif;font-family:Avenir Next, sans-serif">
        <text font-size="smaller" font-weight="400"/></svg>
        """))
        var style = PeleSVGStyle()
        style.apply(element: document.root)
        #expect(style.fontSize == 14)
        #expect(style.bold)
        #expect(style.italic)
        #expect(style.fontFamily == "Avenir Next, sans-serif")
        guard case let .element(text) = document.root.children.first(where: { if case .element = $0 { return true } else { return false } })! else {
            Issue.record("missing text")
            return
        }
        style.apply(element: text)
        #expect(abs(style.fontSize - 14 / 1.2) < 0.0001)
        #expect(!style.bold)

        // What Pele writes for `style A font-size:150%`.
        var percent = PeleSVGStyle()
        percent.fontSize = 16
        percent.apply(element: PeleSVGElement(name: "text", attributes: ["style": "font-size:150%;"]))
        #expect(percent.fontSize == 24)
        percent.apply(element: PeleSVGElement(name: "tspan", attributes: ["font-size": "0.5em"]))
        #expect(percent.fontSize == 12)
    }

    @Test("Line-through decorations are drawn")
    func strikethrough() throws {
        // What Pele writes for `style A text-decoration:line-through`.
        let struck = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="40" font-size="20" fill="#ff0000">
        <text x="10" y="30" style="text-decoration:line-through;">Removed label</text></svg>
        """)
        let plain = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="40" font-size="20" fill="#ff0000">
        <text x="10" y="30">Removed label</text></svg>
        """)
        let glyphs = try #require(plain.columns(inRow: 25, where: \.isOpaqueRed))
        // Somewhere between the baseline (30) and mid x-height a row must be red across the whole label.
        let strikeRow = (22...29).first { row in
            let columns = struck.columns(inRow: row, where: \.isOpaqueRed)
            guard let columns else { return false }
            return columns.count >= glyphs.count - 2 && struck.count(where: { $0.isOpaqueRed }) > plain.count(where: { $0.isOpaqueRed })
                && (columns.lowerBound...columns.upperBound).allSatisfy { struck.pixel($0, row).isOpaqueRed }
        }
        #expect(strikeRow != nil, "a continuous line crosses the glyphs")
    }

    // MARK: Document

    @Test("Root size comes from width/height, falling back to the view box")
    func documentSize() throws {
        let sized = try #require(PeleSVGDocument(svg: #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 150" width="600" height="300"></svg>"#))
        #expect(sized.width == 600)
        #expect(sized.height == 300)
        #expect(sized.viewBox == CGRect(x: 0, y: 0, width: 300, height: 150))

        let boxed = try #require(PeleSVGDocument(svg: #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="10 10 50 20"></svg>"#))
        #expect(boxed.width == 50)
        #expect(boxed.height == 20)

        #expect(PeleSVGDocument(svg: "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>") == nil, "no size")
        #expect(PeleSVGDocument(svg: "<div>not svg</div>") == nil)
        #expect(PeleSVGDocument(svg: "<svg width=\"1\" height=\"1\"><g></svg>") == nil, "not well-formed")
    }

    // MARK: Rasterization

    @Test("Shapes fill and stroke at the right pixels")
    func drawsShapes() throws {
        let bitmap = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" viewBox="0 0 40 40">
        <rect x="0" y="0" width="20" height="20" fill="#ff0000"/>
        <circle cx="30" cy="30" r="8" fill="none" stroke="#0000ff" stroke-width="4"/>
        <polygon points="0,40 20,40 20,20" fill="rgb(0,255,0)"/>
        </svg>
        """)
        #expect(bitmap.image.width == 40)
        #expect(bitmap.pixel(5, 5).isOpaqueRed)
        #expect(bitmap.pixel(25, 5) == .transparent, "outside every shape")
        #expect(bitmap.pixel(30, 30) == .transparent, "unfilled circle center")
        #expect(bitmap.pixel(22, 30).isOpaqueBlue, "circle stroke on its left edge")
        #expect(bitmap.pixel(5, 37).green > 200, "polygon interior")
        #expect(bitmap.pixel(5, 25) == .transparent, "outside the triangle")
    }

    @Test("View box scaling, transforms and nested viewports")
    func drawsTransformed() throws {
        let bitmap = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 50 50">
        <g transform="translate(25,25)"><rect x="-5" y="-5" width="10" height="10" fill="#ff0000"/></g>
        <svg x="0" y="0" width="20" height="20" viewBox="0 0 2 2"><rect width="1" height="1" fill="#0000ff"/></svg>
        </svg>
        """)
        #expect(bitmap.pixel(50, 50).isOpaqueRed, "translated rect, doubled by the view box")
        #expect(bitmap.pixel(38, 50) == .transparent)
        #expect(bitmap.pixel(5, 5).isOpaqueBlue, "nested viewport scales 2 units to 20 points to 20 pixels")
        #expect(bitmap.pixel(25, 25) == .transparent)
    }

    @Test("Group opacity composites the group once")
    func groupOpacity() throws {
        let bitmap = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
        <g opacity="0.5"><rect width="10" height="10" fill="#ff0000"/><rect width="10" height="10" fill="#ff0000"/></g>
        </svg>
        """)
        let pixel = bitmap.pixel(5, 5)
        #expect(abs(pixel.alpha - 128) <= 2, "two overlapping shapes in a half-transparent group stay half transparent: \(pixel)")
    }

    @Test("Shape opacity composites fill and stroke together")
    func shapeOpacity() throws {
        // What Pele writes for `style A fill:#f00,stroke:#00f,stroke-width:4px,opacity:0.5`.
        let bitmap = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">
        <rect x="10" y="10" width="20" height="20" style="fill:#ff0000;stroke:#0000ff;stroke-width:4px;opacity:0.5"/>
        </svg>
        """)
        let onStroke = bitmap.pixel(11, 20)
        #expect(abs(onStroke.alpha - 128) <= 2, "where the stroke covers the fill the shape is still half transparent: \(onStroke)")
        #expect(onStroke.isOpaqueBlue == false && onStroke.blue > 200 && onStroke.red < 50, "the stroke color wins where it covers the fill: \(onStroke)")
        let inside = bitmap.pixel(20, 20)
        #expect(abs(inside.alpha - 128) <= 2 && inside.red > 200, "fill interior: \(inside)")
    }

    @Test("Style declarations override corner radius attributes")
    func cornerRadiusPrecedence() throws {
        // What Pele writes for a rounded node with `style A rx:1,ry:1`.
        let bitmap = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">
        <rect x="0" y="0" width="40" height="40" rx="12" style="rx:1;ry:1" fill="#ff0000"/>
        </svg>
        """)
        #expect(bitmap.pixel(2, 2).isOpaqueRed, "a 1pt corner leaves (2,2) inside the rect; a 12pt corner would not")

        let attributeOnly = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">
        <rect x="0" y="0" width="40" height="40" rx="12" fill="#ff0000"/>
        </svg>
        """)
        #expect(attributeOnly.pixel(2, 2) == .transparent, "the attribute still applies on its own")
    }

    @Test("Oversized drawings are refused instead of trapping")
    func refusesOversizedRaster() throws {
        let huge = try #require(PeleSVGDocument(svg: #"<svg xmlns="http://www.w3.org/2000/svg" width="10000000000" height="10000000000"></svg>"#))
        #expect(huge.makeCGImage(scale: 1) == nil)
        #expect(huge.makeImage(scale: 2) == nil)

        let modest = try #require(PeleSVGDocument(svg: #"<svg xmlns="http://www.w3.org/2000/svg" width="4000" height="4000"></svg>"#))
        #expect(modest.makeCGImage(scale: 1) != nil)
        #expect(modest.makeCGImage(scale: 3) == nil, "scale pushes it past the pixel budget")
    }

    @Test("Rendering scale multiplies pixels, not points")
    func rasterScale() throws {
        let document = try #require(PeleSVGDocument(svg: ##"<svg xmlns="http://www.w3.org/2000/svg" width="30" height="20"><rect width="30" height="20" fill="#ff0000"/></svg>"##))
        let image = try #require(document.makeCGImage(scale: 2))
        #expect(image.width == 60)
        #expect(image.height == 40)

        let platformImage = try #require(document.makeImage(scale: 2))
        #expect(platformImage.size == CGSize(width: 30, height: 20))
    }

    @Test("Linear gradients paint between their stops")
    func drawsGradient() throws {
        let bitmap = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="10">
        <defs><linearGradient id="g" gradientUnits="userSpaceOnUse" x1="0" x2="100"><stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/></linearGradient></defs>
        <rect width="100" height="10" fill="url(#g) #00ff00"/>
        <rect y="5" width="100" height="5" fill="url(#missing) #00ff00"/>
        </svg>
        """)
        #expect(bitmap.pixel(2, 2).isOpaqueRed)
        #expect(bitmap.pixel(97, 2).isOpaqueBlue)
        #expect(bitmap.pixel(50, 7).green > 200, "unknown gradient falls back to the fallback color")
    }

    @Test("Text anchors align each chunk around its x coordinate")
    func textAnchors() throws {
        let bitmap = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="90" font-size="16" fill="#ff0000" font-family="sans-serif">
        <text x="100" y="20" text-anchor="middle">centered</text>
        <text x="100" y="50" text-anchor="end">ends here</text>
        <text x="100" y="80">starts here</text>
        </svg>
        """)
        let middle = try #require(bitmap.columns(inRow: 15, where: { $0.alpha > 60 }))
        let center = CGFloat(middle.lowerBound + middle.upperBound) / 2
        #expect(abs(center - 100) < 4, "middle-anchored text centers on x: \(middle)")

        let end = try #require(bitmap.columns(inRow: 45, where: { $0.alpha > 60 }))
        #expect(end.upperBound <= 101 && end.upperBound >= 94, "end-anchored text finishes at x: \(end)")

        let start = try #require(bitmap.columns(inRow: 75, where: { $0.alpha > 60 }))
        #expect(start.lowerBound >= 99 && start.lowerBound <= 106, "start-anchored text begins at x: \(start)")
        #expect(bitmap.pixel(middle.lowerBound + 1, 15).red > 150, "text is painted with the fill color")
    }

    @Test("Multi-span text keeps one line centered and positions each line")
    func spansAndLines() throws {
        // What Pele writes for a two-line label where the second line mixes bold and plain spans.
        let bitmap = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="80" font-size="14" fill="#000000" font-family="sans-serif">
        <text text-anchor="middle" xml:space="preserve"><tspan x="100" y="30">First line</tspan><tspan x="100" y="60" font-weight="bold">Second</tspan><tspan> line</tspan></text>
        </svg>
        """)
        let first = try #require(bitmap.columns(inRow: 26, where: { $0.alpha > 60 }))
        let second = try #require(bitmap.columns(inRow: 56, where: { $0.alpha > 60 }))
        #expect(abs(CGFloat(first.lowerBound + first.upperBound) / 2 - 100) < 4)
        #expect(abs(CGFloat(second.lowerBound + second.upperBound) / 2 - 100) < 4, "bold + plain spans center as one chunk: \(second)")
        #expect(bitmap.columns(inRow: 45, where: { $0.alpha > 60 }) == nil, "nothing between the lines")
    }

    @Test("Whitespace collapses unless preserved")
    func whitespaceHandling() throws {
        let collapsed = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="30" font-size="14" fill="#000000">
        <text x="10" y="20">  a
            b  </text></svg>
        """)
        let preserved = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="30" font-size="14" fill="#000000">
        <text x="10" y="20" xml:space="preserve">    a    b</text></svg>
        """)
        let reference = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="30" font-size="14" fill="#000000">
        <text x="10" y="20">a b</text></svg>
        """)
        let collapsedColumns = try #require(collapsed.columns(inRow: 15, where: { $0.alpha > 60 }))
        let preservedColumns = try #require(preserved.columns(inRow: 15, where: { $0.alpha > 60 }))
        let referenceColumns = try #require(reference.columns(inRow: 15, where: { $0.alpha > 60 }))
        #expect(collapsedColumns == referenceColumns, "collapsing and trimming yields exactly \"a b\"")
        #expect(preservedColumns.lowerBound > collapsedColumns.lowerBound + 10, "preserved spaces indent the text")
        #expect(preservedColumns.count > collapsedColumns.count)
    }

    @Test("Non-breaking spaces are not collapsed")
    func nonBreakingSpaces() throws {
        // What Pele writes for `A["hello&nbsp;&nbsp;world"]`: literal U+00A0s, no xml:space.
        let regular = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="30" font-size="14" fill="#000000">
        <text x="10" y="20">hello  world</text></svg>
        """)
        let nonBreaking = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="30" font-size="14" fill="#000000">
        <text x="10" y="20">hello\u{00A0}\u{00A0}\u{00A0}\u{00A0}world</text></svg>
        """)
        let regularColumns = try #require(regular.columns(inRow: 15, where: { $0.alpha > 60 }))
        let nonBreakingColumns = try #require(nonBreaking.columns(inRow: 15, where: { $0.alpha > 60 }))
        #expect(nonBreakingColumns.upperBound > regularColumns.upperBound + 6, "four nbsp are wider than one collapsed space")
    }

    @Test("Word spacing widens the gaps between words and the anchored width")
    func wordSpacing() throws {
        // What Pele writes for `style A word-spacing:20px` on a two-word label.
        let plain = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="300" height="30" font-size="14" fill="#000000">
        <text x="150" y="20" text-anchor="middle">hello wide world</text></svg>
        """)
        let spaced = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="300" height="30" font-size="14" fill="#000000">
        <text x="150" y="20" text-anchor="middle" style="word-spacing:20px;">hello wide world</text></svg>
        """)
        let plainColumns = try #require(plain.columns(inRow: 15, where: { $0.alpha > 60 }))
        let spacedColumns = try #require(spaced.columns(inRow: 15, where: { $0.alpha > 60 }))
        #expect(spacedColumns.count >= plainColumns.count + 36, "two spaces each 20pt wider: \(spacedColumns) vs \(plainColumns)")
        let plainCenter = CGFloat(plainColumns.lowerBound + plainColumns.upperBound) / 2
        let spacedCenter = CGFloat(spacedColumns.lowerBound + spacedColumns.upperBound) / 2
        #expect(abs(spacedCenter - plainCenter) < 4, "the wider text is still centered on x, so the measured width included the spacing")
    }

    @Test("Text strokes draw an outline")
    func textStroke() throws {
        // What Pele writes for an outlined sankey label: a stroked, unfilled pass behind the filled one.
        let bitmap = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="40" font-size="20" font-weight="bold">
        <text x="10" y="30" fill="none" stroke="#ff0000" stroke-width="3">Outline</text>
        <text x="10" y="30" fill="#0000ff">Outline</text>
        </svg>
        """)
        #expect(bitmap.count(where: { $0.red > 150 && $0.blue < 100 && $0.alpha > 100 }) > 50, "red outline pixels around the glyphs")
        #expect(bitmap.count(where: \.isOpaqueBlue) > 50, "blue fill inside the glyphs")

        let unstroked = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="40" font-size="20">
        <text x="10" y="30" fill="#0000ff">Outline</text>
        </svg>
        """)
        #expect(unstroked.count(where: { $0.red > 150 && $0.blue < 100 && $0.alpha > 100 }) == 0)
    }

    @Test("Unsupported elements are skipped, not drawn")
    func skipsUnsupported() throws {
        let bitmap = try rasterize("""
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
        <defs><rect width="20" height="20" fill="#ff0000"/></defs>
        <image href="data:image/png;base64,AAAA" width="20" height="20"/>
        <foreignObject width="20" height="20"><div xmlns="http://www.w3.org/1999/xhtml">x</div></foreignObject>
        <title>Ignored title text</title>
        </svg>
        """)
        #expect(bitmap.count(where: { $0.alpha > 0 }) == 0)
    }

    #if canImport(JavaScriptCore)
    @Test("Real Pele output rasterizes with the theme's colors")
    func rasterizesPeleOutput() async throws {
        let renderer = try #require(PeleRenderer.shared)
        let result = try await renderer.render("flowchart LR\n  A[Start] --> B[End]", options: PeleRenderOptions(theme: [
            "surface": "#ff0000",
            "line": "#0000ff",
            "border": "#0000ff",
            "fg": "#0000ff"
        ]))
        let document = try #require(PeleSVGDocument(svg: result.svg))
        #expect(document.width == result.width)
        #expect(document.height == result.height)

        let bitmap = try #require(Bitmap(document.makeCGImage(scale: 1)))
        #expect(bitmap.count(where: \.isOpaqueRed) > 200, "node surfaces are painted")
        #expect(bitmap.count(where: \.isOpaqueBlue) > 20, "edges and text are painted")
        #expect(bitmap.pixel(bitmap.image.width / 2, 2) == .transparent, "the margin above the edge stays clear")
    }

    @Test("Every Pele diagram type survives rasterization", arguments: [
        "sequenceDiagram\n  Alice->>Bob: Hello\n  Bob-->>Alice: Hi",
        "pie title Pets\n  \"Dogs\" : 386\n  \"Cats\" : 85",
        "classDiagram\n  Animal <|-- Duck\n  Animal : +int age",
        "stateDiagram-v2\n  [*] --> Still\n  Still --> [*]",
        "erDiagram\n  CUSTOMER ||--o{ ORDER : places",
        "gantt\n  dateFormat YYYY-MM-DD\n  section S\n  Task :a1, 2024-01-01, 30d",
        "mindmap\n  root((root))\n    A\n    B",
        "sankey-beta\n  A,B,10\n  B,C,5",
        "xychart-beta\n  x-axis [a, b]\n  y-axis 0 --> 10\n  bar [3, 7]"
    ])
    func rasterizesAllTypes(source: String) async throws {
        let renderer = try #require(PeleRenderer.shared)
        let result = try await renderer.render(source)
        let document = try #require(PeleSVGDocument(svg: result.svg))
        let bitmap = try #require(Bitmap(document.makeCGImage(scale: 1)))
        #expect(bitmap.count(where: { $0.alpha > 0 }) > 100, "something was drawn for \(result.type)")
    }
    #endif

    #if os(macOS)
    @Test("Vega clips use the transformed group's local coordinates, without changing Pele")
    func vegaClips() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="60" height="40">
        <g transform="translate(20,10)" clip-path="url(#clip1)">
        <path d="M-10,-10h60v40h-60Z" fill="#ff0000"/>
        </g>
        <defs><clipPath id="clip1"><rect width="20" height="10"/></clipPath></defs>
        </svg>
        """
        let chart = try rasterize(svg, dialect: .vega)
        #expect(chart.pixel(25, 15).isOpaqueRed)
        #expect(chart.pixel(15, 15) == .transparent)
        #expect(chart.pixel(45, 15) == .transparent)
        #expect(chart.pixel(25, 25) == .transparent)
        let pele = try rasterize(svg)
        #expect(pele.pixel(15, 15).isOpaqueRed, "the default Pele dialect retains its previous clip behavior")
    }

    @Test("Vega rounded-path clips also constrain accelerated stroke outlines")
    func vegaPathClips() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">
        <g clip-path="url(#clip1)"><path d="M0,20H40" stroke="#ff0000" stroke-width="20"/></g>
        <defs><clipPath id="clip1"><path d="M10,10h20v20h-20Z"/></clipPath></defs>
        </svg>
        """
        let document = try #require(PeleSVGDocument(svg: svg, dialect: .vega))
        let image = try #require(document.makeCGImage(scale: 1))
        let bitmap = try #require(Bitmap(image))
        #expect(bitmap.pixel(20, 20).isOpaqueRed)
        #expect(bitmap.pixel(5, 20) == .transparent)
        let context = try #require(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: PeleSVGValue.colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: 40)
        context.scaleBy(x: 1, y: -1)
        document.draw(in: context, strokesAsFills: true)
        let vector = try #require(Bitmap(context.makeImage()))
        #expect(vector.pixel(20, 20).isOpaqueRed)
        #expect(vector.pixel(5, 20) == .transparent)
    }

    @Test("Vega's percentage gradient coordinates and stop opacity are retained")
    func vegaGradient() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="10">
        <defs><linearGradient id="g" x1="0%" x2="100%" y1="0%" y2="0%">
        <stop offset="0%" stop-color="#ff0000" stop-opacity="0.5"/>
        <stop offset="100%" stop-color="#0000ff"/>
        </linearGradient></defs><rect width="100" height="10" fill="url(#g)"/>
        </svg>
        """
        let bitmap = try rasterize(svg, dialect: .vega)
        #expect(bitmap.pixel(2, 5).red > 230)
        #expect(abs(bitmap.pixel(2, 5).alpha - 131) < 8)
        #expect(bitmap.pixel(97, 5).isOpaqueBlue)
    }

    @Test("Vega diagonal bounding-box gradients retain their color planes on transformed wide and tall marks",
          arguments: [(200, 40), (40, 200)], [false, true])
    func vegaDiagonalBoundingBoxGradient(size: (Int, Int), strokesAsFills: Bool) throws {
        let (width, height) = size
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width * 2 + 40)" height="\(height * 3 + 40)">
        <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/>
        </linearGradient></defs>
        <g transform="translate(10,10) scale(2,3)">
        <rect x="5" y="5" width="\(width)" height="\(height)" fill="url(#g)" stroke="#00ff00" stroke-width="2"/>
        </g></svg>
        """
        let document = try #require(PeleSVGDocument(svg: svg, dialect: .vega))
        let context = try #require(CGContext(data: nil, width: Int(document.width), height: Int(document.height),
                                            bitsPerComponent: 8, bytesPerRow: 0, space: PeleSVGValue.colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: document.height)
        context.scaleBy(x: 1, y: -1)
        document.draw(in: context, strokesAsFills: strokesAsFills)
        let bitmap = try #require(Bitmap(context.makeImage()))
        let originX = 20
        let originY = 25
        for (u, v) in [(0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9)] {
            let pixel = bitmap.pixel(originX + Int(u * Double(width * 2)),
                                     originY + Int(v * Double(height * 3)))
            // The diagonal's color is (u + v) / 2 in the unit bounding box,
            // independent of its aspect ratio and the element's transform.
            let blue = Int(((u + v) * 0.5 * 255).rounded())
            #expect(abs(pixel.red - (255 - blue)) <= 4)
            #expect(abs(pixel.blue - blue) <= 4)
            #expect(pixel.green == 0 && pixel.alpha == 255)
        }
        #expect(bitmap.pixel(originX - 6, originY + height) == .transparent,
                "The gradient remains clipped to the original shape")
        let stroke = bitmap.pixel(originX + width, originY)
        #expect(stroke.green > 240 && stroke.red < 10 && stroke.blue < 10,
                "Bounding-box gradient coordinates must not alter the subsequent stroke")
    }

    @Test("Vega display:none stays invisible and aria-hidden does not hide visible marks")
    func vegaVisibilityAndAccessibility() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">
        <g aria-label="X-axis category"><rect width="20" height="20" fill="#ff0000" aria-hidden="true" aria-label="decorative"/></g>
        <g aria-hidden="true" aria-label="hidden label"><path d=""/></g>
        <rect x="20" width="20" height="20" fill="#0000ff" display="none" aria-label="not displayed"/>
        </svg>
        """
        let document = try #require(PeleSVGDocument(svg: svg, dialect: .vega))
        let bitmap = try #require(Bitmap(document.makeCGImage(scale: 1)))
        #expect(bitmap.pixel(5, 5).isOpaqueRed)
        #expect(bitmap.pixel(25, 5) == .transparent)
        #expect(document.accessibilitySummary == "X-axis category")
        #expect(PeleSVGDocument(svg: svg)?.accessibilitySummary == nil)
    }

    @Test("Unsupported Vega render features fall back instead of producing partial charts", arguments: [
        "<image href='chart.png' width='10' height='10'/>",
        "<defs><radialGradient id='g'/></defs><rect width='10' height='10' fill='url(#g)'/>",
        "<rect width='10' height='10' filter='url(#shadow)'/>",
        "<rect width='10' height='10' clip-path='url(#missing)'/>",
        "<rect width='10' height='10' style='mix-blend-mode:multiply'/>",
        "<defs><clipPath id='c' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath></defs>"
    ])
    func refusesUnsupportedVega(content: String) {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'>\(content)</svg>"
        #expect(PeleSVGDocument(svg: svg, dialect: .vega) == nil)
        #expect(PeleSVGDocument(svg: svg) != nil, "Pele's forgiving parser remains unchanged")
    }

    @Test("Real Vega output preserves bars, transformed axis labels and descriptions")
    func rasterizesVegaOutput() throws {
        let document = try #require(PeleSVGDocument(svg: VegaSVGFixtures.bars, dialect: .vega))
        #expect(document.width == 448)
        #expect(document.height == 312)
        let bitmap = try #require(Bitmap(document.makeCGImage(scale: 1)))
        let bar = bitmap.pixel(200, 20)
        #expect(abs(bar.red - 76) < 2 && abs(bar.green - 120) < 2 && abs(bar.blue - 168) < 2)
        #expect(bitmap.pixel(70, 180) == bar)
        #expect(bitmap.pixel(350, 150) == bar)
        #expect(bitmap.pixel(70, 20).red == 255, "the shorter first bar leaves the plot above it clear")
        let rotatedLabelPixels = (250..<275).reduce(0) { count, y in
            count + (100..<114).filter { bitmap.pixel($0, y).red < 100 }.count
        }
        #expect(rotatedLabelPixels > 10, "the transformed, end-anchored Alpha tick label is drawn below its tick")
        #expect(document.accessibilitySummary?.contains("category: Beta; value: 55") == true)
        #expect(document.accessibilitySummary?.contains("X-axis titled 'category'") == true)
    }

    @Test("Vega multiline tspan offsets keep separate baselines under rotation")
    func vegaMultilineText() throws {
        let multiline = try rasterize(VegaSVGFixtures.multiline, dialect: .vega)
        let firstLineOnly = try rasterize(VegaSVGFixtures.multiline.replacingOccurrences(of: "<tspan x=\"0\" dy=\"13\">Second line</tspan>", with: ""), dialect: .vega)
        let lowerLinePixels = (59..<78).reduce(0) { count, y in
            count + (45..<110).filter {
                multiline.pixel($0, y).alpha > 80 && firstLineOnly.pixel($0, y).alpha == 0
            }.count
        }
        #expect(lowerLinePixels > 40, "the second line occupies its own lower baseline after the text transform")
        #expect(firstLineOnly.count(where: { $0.alpha > 80 }) > 40)
    }
    #endif
}
