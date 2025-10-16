import Foundation
import CoreGraphics
import CoreText

#if canImport(SwiftUI)
import SwiftUI
#endif

struct MathArtifactRenderer {
    static func draw(_ artifact: MathRenderArtifact, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        // UIKit/AppKit contexts have origin in lower-left; flip so baseline aligns with CoreText coordinates.
        let height = artifact.size.height
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)

        for command in artifact.commands {
            switch command {
            case .glyph(let run):
                drawGlyphRun(run, in: context)
            case .line(let line):
                drawLine(line, in: context)
            case .path(let path):
                drawPath(path, in: context)
            }
        }
    }

    static func makeImage(from artifact: MathRenderArtifact, scale: CGFloat) -> CGImage? {
        guard artifact.size.width > 0, artifact.size.height > 0 else { return nil }
        let width = Int(artifact.size.width * scale)
        let height = Int(artifact.size.height * scale)
        guard width > 0, height > 0 else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let bitmap = CGContext(data: nil,
                                     width: width,
                                     height: height,
                                     bitsPerComponent: 8,
                                     bytesPerRow: 0,
                                     space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        bitmap.scaleBy(x: scale, y: scale)
        draw(artifact, in: bitmap)
        return bitmap.makeImage()
    }

#if canImport(SwiftUI)
    static func draw(_ artifact: MathRenderArtifact, in graphicsContext: inout GraphicsContext, size: CGSize) {
        graphicsContext.withCGContext { cgContext in
            draw(artifact, in: cgContext)
        }
    }
#endif

    private static func drawGlyphRun(_ run: MathGlyphRun, in context: CGContext) {
        let ctFont = CTFontCreateWithName(run.fontName as CFString, run.fontSize, nil)
        var glyphs = run.glyphs.map { CGGlyph($0) }
        var positions = run.positions
        context.saveGState()
        context.setFillColor(resolveColor(from: run.color))
        CTFontDrawGlyphs(ctFont, &glyphs, &positions, glyphs.count, context)
        context.restoreGState()
    }

    private static func drawLine(_ line: MathLine, in context: CGContext) {
        context.saveGState()
        context.setLineWidth(line.thickness)
        context.setStrokeColor(resolveColor(from: .black))
        context.move(to: line.start)
        context.addLine(to: line.end)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawPath(_ path: MathPath, in context: CGContext) {
        guard let cgPath = makePath(from: path.elements) else { return }
        context.saveGState()
        context.addPath(cgPath)
        context.setLineWidth(path.lineWidth)
        let color = resolveColor(from: path.color)
        if path.fill {
            context.setFillColor(color)
            context.fillPath()
        } else {
            context.setStrokeColor(color)
            context.strokePath()
        }
        context.restoreGState()
    }

    private static func makePath(from elements: [MathPathElement]) -> CGPath? {
        guard !elements.isEmpty else { return nil }
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case .moveTo(let point):
                path.move(to: point)
            case .lineTo(let point):
                path.addLine(to: point)
            case let .quadTo(control, end):
                path.addQuadCurve(to: end, control: control)
            case let .curveTo(control1, control2, end):
                path.addCurve(to: end, control1: control1, control2: control2)
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }

    private static func resolveColor(from color: MathColor) -> CGColor {
        if color.red == 0, color.green == 0, color.blue == 0, color.alpha == 1 {
#if canImport(UIKit)
            return UIColor.label.cgColor
#else
            return NSColor.labelColor.cgColor
#endif
        }
        return CGColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
