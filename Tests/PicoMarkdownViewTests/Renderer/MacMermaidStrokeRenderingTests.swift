#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import PicoMarkdownView

@Suite("macOS Mermaid vector stroke outlines")
struct MacMermaidStrokeRenderingTests {
    private struct Pixels {
        let bytes: [UInt8]

        var ink: Int {
            stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }
        }
    }

    private func pixels(from image: CGImage) throws -> Pixels {
        let data = try #require(image.dataProvider?.data as Data?)
        var rgba: [UInt8] = []
        rgba.reserveCapacity(image.width * image.height * 4)
        for row in 0..<image.height {
            let start = row * image.bytesPerRow
            rgba.append(contentsOf: data[start..<(start + image.width * 4)])
        }
        return Pixels(bytes: rgba)
    }

    private func render(_ document: PeleSVGDocument, strokesAsFills: Bool, clip: CGRect? = nil) throws -> Pixels {
        let scale: CGFloat = 2
        let width = Int((document.width * scale).rounded(.up))
        let height = Int((document.height * scale).rounded(.up))
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: PeleSVGValue.colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / document.width, y: -CGFloat(height) / document.height)
        if let clip { context.clip(to: clip) }
        document.draw(in: context, strokesAsFills: strokesAsFills)
        return try pixels(from: #require(context.makeImage()))
    }

    /// Outline expansion and native stroking can differ at antialiased edge
    /// samples. Compare their coverage and color while rejecting missing
    /// dashes, changed caps/joins, or a lost stroke.
    private func expectEquivalent(_ outline: Pixels, _ stroke: Pixels) {
        #expect(outline.bytes.count == stroke.bytes.count)
        guard outline.bytes.count == stroke.bytes.count else { return }
        var difference = 0
        var visiblyDifferentPixels = 0
        var paintedPixels = 0
        for offset in stride(from: 0, to: stroke.bytes.count, by: 4) {
            var largestChannelDifference = 0
            for channel in 0..<4 {
                let delta = abs(Int(outline.bytes[offset + channel]) - Int(stroke.bytes[offset + channel]))
                difference += delta
                largestChannelDifference = max(largestChannelDifference, delta)
            }
            if max(outline.bytes[offset + 3], stroke.bytes[offset + 3]) > 0 { paintedPixels += 1 }
            if largestChannelDifference > 32 { visiblyDifferentPixels += 1 }
        }
        #expect(Double(difference) / Double(max(stroke.bytes.count, 1)) < 1,
                "Mean premultiplied RGBA error must stay below one byte")
        #expect(Double(visiblyDifferentPixels) / Double(max(paintedPixels, 1)) < 0.03,
                "At least 97% of painted pixels retain their optical coverage and color")
        #expect(abs(Double(outline.ink - stroke.ink)) / Double(max(stroke.ink, 1)) < 0.02,
                "Total alpha coverage must remain within 2%")
    }

    @Test("Dashed outlines preserve cap, join, transform and nested viewport geometry",
          arguments: ["butt", "round", "square"], ["miter", "round", "bevel"])
    func dashedStrokes(cap: String, join: String) throws {
        let document = try #require(PeleSVGDocument(svg: """
        <svg xmlns="http://www.w3.org/2000/svg" width="160" height="110" viewBox="0 0 160 110">
          <g transform="translate(15,12) rotate(7) scale(1.2,0.85)" fill="none"
             stroke="#3366cc" stroke-width="5" stroke-linecap="\(cap)" stroke-linejoin="\(join)"
             stroke-dasharray="9 4" stroke-dashoffset="3">
            <path d="M5 8 L42 28 L61 3 L104 24"/>
            <path d="M4 61 C20 20 70 85 105 43"/>
          </g>
          <svg x="12" y="82" width="130" height="20" viewBox="0 0 130 20">
            <g transform="translate(3,0)" fill="none" stroke="#cc3300" stroke-width="3">
              <polyline points="1,15 34,3 60,15 90,3 118,15"/>
            </g>
          </svg>
        </svg>
        """))
        let original = try render(document, strokesAsFills: false)
        let outline = try render(document, strokesAsFills: true)
        #expect(original.ink > 100_000)
        expectEquivalent(outline, original)
    }

    @Test("Dashed outlines retain painted segments, gaps and dash phase")
    func dashGapsAndPhase() throws {
        let document = try #require(PeleSVGDocument(svg: """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="20">
          <path d="M10 10 L90 10" fill="none" stroke="#ff0000" stroke-width="4"
                stroke-dasharray="10 6" stroke-dashoffset="3"/>
        </svg>
        """))
        let original = try render(document, strokesAsFills: false)
        let outline = try render(document, strokesAsFills: true)
        // At scale 2, phase 3 leaves the first painted segment at x=10...17,
        // followed by gaps at 17...23 and 33...39, in SVG coordinates.
        func alpha(_ image: Pixels, x: Int) -> UInt8 { image.bytes[(20 * 200 + x * 2) * 4 + 3] }
        for x in [12, 27] {
            #expect(alpha(original, x: x) > 240)
            #expect(alpha(outline, x: x) > 240)
        }
        for x in [20, 36] {
            #expect(alpha(original, x: x) == 0)
            #expect(alpha(outline, x: x) == 0)
        }
        expectEquivalent(outline, original)
    }

    @Test("A stroke centered on the clipping boundary retains its visible half")
    func clippingBoundary() throws {
        let document = try #require(PeleSVGDocument(svg: """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="60" fill="none" stroke="#ff0000" stroke-width="8">
          <path d="M10 8 L10 52"/>
          <path d="M10 30 L90 30" stroke-dasharray="7 3" stroke-linecap="round"/>
          <path d="M90 8 L90 52"/>
        </svg>
        """))
        let clip = CGRect(x: 10, y: 10, width: 80, height: 40)
        let original = try render(document, strokesAsFills: false, clip: clip)
        let outline = try render(document, strokesAsFills: true, clip: clip)
        #expect(original.ink > 100_000)
        expectEquivalent(outline, original)
    }

    @Test("Fully clipped and empty strokes leave no pixels or path state behind",
          arguments: ["<path d=\"\"/>", "<path d=\"M1 1\"/>", "<path d=\"M1 1 L9 9\"/>"])
    func clippedAndEmptyStrokes(element: String) throws {
        let document = try #require(PeleSVGDocument(svg: """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="60" fill="none" stroke="#ff0000" stroke-width="4">
          \(element)
        </svg>
        """))
        let clip = CGRect(x: 50, y: 20, width: 40, height: 30)
        let original = try render(document, strokesAsFills: false, clip: clip)
        let outline = try render(document, strokesAsFills: true, clip: clip)
        #expect(original.ink == 0)
        #expect(outline.ink == 0)
        expectEquivalent(outline, original)
    }

    @Test("Source fill colors, opacity, text outlines and strikethrough survive stroke outlining")
    func mixedPresentation() throws {
        let document = try #require(PeleSVGDocument(svg: """
        <svg xmlns="http://www.w3.org/2000/svg" width="210" height="100" font-size="20">
          <g opacity="0.5">
            <rect x="10" y="10" width="90" height="30" fill="#00cc00" stroke="#0000ff" stroke-width="5"/>
          </g>
          <text x="10" y="70" fill="#cc0000" text-decoration="line-through">Removed label</text>
          <text x="10" y="95" fill="none" stroke="#0000ff" stroke-width="2">Outlined label</text>
        </svg>
        """))
        let original = try render(document, strokesAsFills: false)
        let outline = try render(document, strokesAsFills: true)
        #expect(original.ink > 100_000)
        expectEquivalent(outline, original)
    }

    @Test("Bitmap rendering retains the original default stroke path")
    func defaultBitmapPath() throws {
        let document = try #require(PeleSVGDocument(svg: """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="60" fill="none" stroke="#0000ff" stroke-width="4">
          <path d="M10 10 L45 48 L90 10" stroke-dasharray="7 4" stroke-linecap="round"/>
        </svg>
        """))
        let image = try #require(document.makeCGImage(scale: 2))
        let defaultBitmap = try pixels(from: image)
        let explicitStroke = try render(document, strokesAsFills: false)
        #expect(defaultBitmap.bytes == explicitStroke.bytes)
    }
}
#endif
