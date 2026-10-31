#if os(macOS) && canImport(JavaScriptCore)
import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import PicoMarkdownView

struct PeleSankeyGradientTests {
    private static let source = "sankey\n\nSource,Target,10"

    @MainActor
    @Test("macOS vector Sankey links gain gradients while the bitmap provider stays source-colored")
    func vectorGradientsLeaveBitmapRenderingUnchanged() async throws {
        let provider = PeleDiagramProvider(theme: .default())
        let request = MermaidRenderRequest(source: Self.source, targetWidth: 320, scale: 1)
        let vector = try #require(await provider.renderVector(request))
        let document = try #require(PeleSVGDocument(svg: vector.svg))
        #expect(document.gradients.count == 1)
        #expect(vector.svg.contains("fill=\"url(#pele-sankey-"))
        #expect(vector.svg.contains("var(") == false)

        let renderer = try #require(PeleRenderer.shared)
        let baseline = try await renderer.render(Self.source, options: PeleRenderOptions(maxWidth: 320))
        let baselineDocument = try #require(PeleSVGDocument(svg: baseline.svg))
        #expect(baselineDocument.gradients.isEmpty)
        #expect(vector.intrinsicSize == CGSize(width: baseline.width, height: baseline.height))

        // This is the legacy provider used on iOS, exercised on macOS so
        // an accidental propagation of vector options changes these pixels.
        let bitmap = try #require(await provider.render(request))
        #expect(bitmap.intrinsicSize == vector.intrinsicSize)
        let image = try #require(bitmap.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixels = try Bitmap(image)
        let left = pixels.pixel(x: 0.25, y: 0.25)
        let right = pixels.pixel(x: 0.75, y: 0.25)
        #expect(left.alpha > 90 && left.alpha < 115)
        #expect(right.alpha > 90 && right.alpha < 115)
        #expect(abs(left.red - right.red) <= 2)
        #expect(abs(left.blue - right.blue) <= 2)
        #expect(left.blue > left.red + 50, "legacy links keep Pele's blue source color throughout")
    }

    @Test("Real Pele Sankey gradients reach native drawing in both stroke modes", arguments: [false, true])
    func nativeDrawingInterpolatesSankeyColors(strokesAsFills: Bool) async throws {
        let renderer = try #require(PeleRenderer.shared)
        var options = PeleDiagramProvider.vectorRenderOptions(for: .default(), appearance: .light, maxWidth: 320)
        options.theme["series-1"] = "#ff0000"
        options.theme["series-2"] = "#0000ff"
        let rendered = try await renderer.render(Self.source, options: options)
        let document = try #require(PeleSVGDocument(svg: rendered.svg))
        #expect(document.gradients.count == 1)

        let width = Int(document.width.rounded(.up))
        let height = Int(document.height.rounded(.up))
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: PeleSVGValue.colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / document.width, y: -CGFloat(height) / document.height)
        document.draw(in: context, strokesAsFills: strokesAsFills)
        let pixels = try Bitmap(#require(context.makeImage()))
        // The single ribbon is straight; its quarter-height avoids labels.
        let left = pixels.pixel(x: 0.25, y: 0.25)
        let right = pixels.pixel(x: 0.75, y: 0.25)
        #expect(left.red > left.blue + 80)
        #expect(right.blue > right.red + 80)
        #expect(left.alpha > 90 && left.alpha < 115, "Sankey link opacity stays at 40 percent")
        #expect(right.alpha > 90 && right.alpha < 115)
    }

    private struct Pixel {
        let red: Int
        let blue: Int
        let alpha: Int
    }

    private struct Bitmap {
        let image: CGImage
        let bytes: [UInt8]

        init(_ image: CGImage) throws {
            self.image = image
            self.bytes = [UInt8](try #require(image.dataProvider?.data as Data?))
        }

        /// Un-premultiplied channels at fractional image coordinates.
        func pixel(x: CGFloat, y: CGFloat) -> Pixel {
            let offset = Int(y * CGFloat(image.height)) * image.bytesPerRow + Int(x * CGFloat(image.width)) * 4
            let alpha = Int(bytes[offset + 3])
            guard alpha > 0 else { return Pixel(red: 0, blue: 0, alpha: 0) }
            func channel(_ value: UInt8) -> Int { min(255, Int(value) * 255 / alpha) }
            return Pixel(red: channel(bytes[offset]), blue: channel(bytes[offset + 2]), alpha: alpha)
        }
    }
}
#endif
