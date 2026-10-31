#if os(macOS)
import AppKit
import CoreGraphics
import Testing
@testable import PicoMarkdownView

@MainActor
struct NativeSVGDocumentTests {
    @Test("SVG geometry and accessible title are retained without rasterizing")
    func dimensionsAndDescription() throws {
        let document = try #require(NativeSVGDocument(svg: Self.svg("""
            <title>Flow &amp; storage</title>
            <desc> Source to destination </desc>
            <rect width="100" height="80" fill="red"/>
            """, dimensions: "viewBox=\"0 0 100 80\"")))
        #expect(document.width == 100)
        #expect(document.height == 80)
        #expect(document.accessibilityDescription == "Flow & storage. Source to destination")
    }

    @Test("Native SVG respects the hosted canvas's top-left origin")
    func orientation() throws {
        let document = try #require(NativeSVGDocument(svg: Self.svg("""
            <rect width="100" height="40" fill="red"/>
            <rect y="40" width="100" height="40" fill="blue"/>
            """)))
        let bitmap = try draw(document)
        #expect(bitmap.pixel(x: 50, y: 10).red > 240)
        #expect(bitmap.pixel(x: 50, y: 10).blue < 10)
        #expect(bitmap.pixel(x: 50, y: 70).blue > 240)
        #expect(bitmap.pixel(x: 50, y: 70).red < 10)
    }

    @Test("CSS selectors, variables and internal SVG definitions reach native drawing")
    func stylingAndReferences() throws {
        let document = try #require(NativeSVGDocument(svg: Self.svg("""
            <style>:root { --card: #00ff00; } .card { fill: var(--card); }</style>
            <defs><rect id="card" width="30" height="30" class="card"/></defs>
            <use href="#card" x="10" y="10"/>
            <use href="#card" x="60" y="40"/>
            """)))
        let bitmap = try draw(document)
        #expect(bitmap.pixel(x: 20, y: 20).green > 240)
        #expect(bitmap.pixel(x: 70, y: 50).green > 240)
        #expect(bitmap.pixel(x: 50, y: 30).alpha == 0)
    }

    @Test("SVG gradient, clip path and mask produce their expected pixels")
    func gradientsClippingAndMasks() throws {
        let document = try #require(NativeSVGDocument(svg: Self.svg("""
            <defs>
              <linearGradient id="colors"><stop stop-color="red"/><stop offset="1" stop-color="blue"/></linearGradient>
              <linearGradient id="fade"><stop stop-color="white"/><stop offset="1" stop-color="black"/></linearGradient>
              <clipPath id="top"><rect width="100" height="35"/></clipPath>
              <mask id="fadeMask"><rect width="100" height="80" fill="url(#fade)"/></mask>
            </defs>
            <rect width="100" height="80" fill="url(#colors)" clip-path="url(#top)"/>
            <rect y="45" width="100" height="35" fill="red" mask="url(#fadeMask)"/>
            """)))
        let bitmap = try draw(document)
        let left = bitmap.pixel(x: 10, y: 10)
        let right = bitmap.pixel(x: 90, y: 10)
        #expect(left.red > left.blue + 100)
        #expect(right.blue > right.red + 100)
        #expect(bitmap.pixel(x: 50, y: 40).alpha == 0)
        #expect(bitmap.pixel(x: 10, y: 60).alpha > bitmap.pixel(x: 90, y: 60).alpha + 150)
    }

    @Test("Zoom redraws narrow SVG geometry at the new display resolution")
    func vectorZoom() throws {
        let document = try #require(NativeSVGDocument(svg: Self.svg(
            "<rect x=\"4.99\" width=\"0.02\" height=\"10\" fill=\"red\"/>",
            dimensions: "width=\"10\" height=\"10\"")))
        let bitmap = try draw(document, width: 1000, height: 1000)
        // At 100x scale this subpixel source shape is two opaque pixels wide.
        // Scaling a bitmap rendered at the original 10pt size cannot do this.
        #expect(bitmap.pixel(x: 499, y: 500).alpha > 240)
        #expect(bitmap.pixel(x: 500, y: 500).alpha > 240)
        #expect(bitmap.pixel(x: 496, y: 500).alpha == 0)
        #expect(bitmap.pixel(x: 503, y: 500).alpha == 0)
    }

    @Test("Unsupported or non-self-contained SVG remains source", arguments: [
        "<svg><g></svg>",
        "<html><svg/></html>",
        "<svg xmlns=\"urn:other\" width=\"100\" height=\"80\"><rect width=\"100\" height=\"80\"/></svg>",
        svg("<script>alert(1)</script>"),
        svg("<rect width=\"100\" height=\"80\" onclick=\"alert(1)\"/>"),
        svg("<foreignObject width=\"100\" height=\"80\"/>"),
        svg("<defs><filter id=\"blur\"><feGaussianBlur stdDeviation=\"5\"/></filter></defs>"),
        svg("<rect width=\"100\" height=\"80\" filter=\"url(#blur)\"/>"),
        svg("<style>rect { filter: url(#blur); }</style><rect width=\"100\" height=\"80\"/>"),
        svg("<rect width=\"100\" height=\"80\" style=\"filter:blur(5px)\"/>"),
        svg("<animate attributeName=\"x\" from=\"0\" to=\"100\"/>"),
        svg("<image href=\"https://example.com/image.png\"/>"),
        svg("<use href=\"https://example.com/shape.svg#shape\"/>"),
        svg("<g xml:base=\"https://example.com/\"><use href=\"#shape\"/></g>"),
        svg("<rect fill=\"url(https://example.com/fill.svg)\"/>"),
        svg("<style>@import 'https://example.com/style.css';</style>"),
        svg("<style>rect { fill:url(https://example.com/fill.svg); }</style>"),
        svg("<style>rect { fill:u/**/rl(https://example.com/fill.svg); }</style>"),
        svg("<style>rect { fill:ur\\6c(https://example.com/fill.svg); }</style>"),
        svg("<rect style=\"fill:url(https://example.com/fill.svg\"/>"),
        "<?xml-stylesheet href=\"https://example.com/style.css\"?>" + svg(""),
        "<!DOCTYPE svg [<!ENTITY payload 'external'>]>" + svg("<title>&payload;</title>"),
        svg("<rect width=\"100\" height=\"80\"/>", dimensions: "width=\"0\" height=\"80\""),
        svg("<rect width=\"100\" height=\"80\"/>", dimensions: "width=\"-1\" height=\"80\""),
        svg("<rect width=\"100\" height=\"80\"/>", dimensions: "width=\"1e300\" height=\"80\""),
        svg("<rect width=\"100\" height=\"80\"/>", dimensions: "viewBox=\"0 0 invalid 100 80\""),
        svg("<rect width=\"100\" height=\"80\"/>", dimensions: "viewBox=\"0 0 -100 80\"")
    ])
    func unsupportedSource(_ source: String) {
        #expect(NativeSVGDocument(svg: source) == nil)
    }

    @Test("A regular XML declaration and quoted internal CSS URLs are supported",
          arguments: ["url('#g')", "url(\"#g\")"])
    func normalXMLAndInternalCSS(url: String) throws {
        let source = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + Self.svg("""
            <defs><linearGradient id="g"><stop stop-color="red"/><stop offset="1" stop-color="blue"/></linearGradient></defs>
            <style>/* optional stylesheet comment */ rect { fill: \(url); }</style>
            <rect width="100" height="80"/>
            """)
        let document = try #require(NativeSVGDocument(svg: source))
        let bitmap = try draw(document)
        #expect(bitmap.pixel(x: 10, y: 10).red > bitmap.pixel(x: 90, y: 10).red + 100)
    }

    @Test("Quoted fragment normalization leaves SVG text content unchanged")
    func quotedURLNormalizationPreservesVisibleText() throws {
        let definitions = "<defs><linearGradient id=\"g\"><stop stop-color=\"red\"/><stop offset=\"1\" stop-color=\"blue\"/></linearGradient></defs>"
        let baseline = try #require(NativeSVGDocument(svg: Self.svg(definitions + """
            <rect width="100" height="25" fill="url(#g)"/>
            <text x="2" y="60" font-size="18">url(&apos;#g&apos;)</text>
            """)))
        let normalized = try #require(NativeSVGDocument(svg: Self.svg(definitions + """
            <rect width="100" height="25" fill="url('#g')"/>
            <text x="2" y="60" font-size="18">url('#g')</text>
            """)))
        let expected = try draw(baseline)
        let actual = try draw(normalized)
        #expect(actual.bytes == expected.bytes)
    }

    nonisolated private static func svg(_ body: String, dimensions: String = "width=\"100\" height=\"80\"") -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" \(dimensions)>\(body)</svg>"
    }

    private func draw(_ document: NativeSVGDocument, width: Int? = nil, height: Int? = nil) throws -> Bitmap {
        let width = width ?? Int(document.width.rounded(.up))
        let height = height ?? Int(document.height.rounded(.up))
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / document.width, y: -CGFloat(height) / document.height)
        document.draw(in: context)
        let image = try #require(context.makeImage())
        return try Bitmap(image)
    }

    private struct Pixel {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int
    }

    private struct Bitmap {
        let image: CGImage
        let bytes: [UInt8]

        init(_ image: CGImage) throws {
            self.image = image
            bytes = [UInt8](try #require(image.dataProvider?.data as Data?))
        }

        func pixel(x: Int, y: Int) -> Pixel {
            let offset = y * image.bytesPerRow + x * 4
            let alpha = Int(bytes[offset + 3])
            guard alpha > 0 else { return Pixel(red: 0, green: 0, blue: 0, alpha: 0) }
            func channel(_ value: UInt8) -> Int { min(255, Int(value) * 255 / alpha) }
            return Pixel(red: channel(bytes[offset]), green: channel(bytes[offset + 1]),
                         blue: channel(bytes[offset + 2]), alpha: alpha)
        }
    }
}
#endif
