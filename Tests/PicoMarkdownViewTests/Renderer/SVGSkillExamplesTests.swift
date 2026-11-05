#if os(macOS)
import AppKit
import CoreGraphics
import PicoMarkdownSkills
import Testing
@testable import PicoMarkdownView

@MainActor
@Suite
struct SVGSkillExamplesTests {
    @Test("The shipped SVG skill examples decode, describe themselves and draw natively")
    func examplesDraw() throws {
        let markdown = try String(contentsOf: PicoMarkdownSkills.directoryURL
            .appendingPathComponent("svg-graphics/SKILL.md"), encoding: .utf8)
        let examples = try markdown.components(separatedBy: "```svg\n").dropFirst().map { remainder in
            let end = try #require(remainder.range(of: "\n```"), "An SVG skill example needs its closing fence")
            return String(remainder[..<end.lowerBound])
        }
        try #require(!examples.isEmpty)
        for source in examples {
            let document = try #require(NativeSVGDocument(svg: source))
            #expect(document.width > 0 && document.height > 0)
            #expect(document.accessibilityDescription?.isEmpty == false)
            let width = Int(ceil(document.width))
            let height = Int(ceil(document.height))
            let context = try #require(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            document.draw(in: context)
            let bytes = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
            let hasVisiblePixels = (0..<height).contains { y in
                (0..<width).contains { x in bytes[y * context.bytesPerRow + x * 4 + 3] != 0 }
            }
            #expect(hasVisiblePixels, "The example must produce visible native pixels")
        }
    }
}
#endif
