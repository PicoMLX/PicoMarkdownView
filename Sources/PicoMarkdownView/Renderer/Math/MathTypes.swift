import Foundation
import CoreGraphics

struct MathRenderArtifact: Sendable, Equatable {
    var size: CGSize
    var baseline: CGFloat
    var commands: [MathDrawCommand]

    init(size: CGSize, baseline: CGFloat, commands: [MathDrawCommand]) {
        self.size = size
        self.baseline = baseline
        self.commands = commands
    }
}

enum MathDrawCommand: Sendable, Equatable {
    case glyph(MathGlyphRun)
    case line(MathLine)
    case path(MathPath)
}

struct MathGlyphRun: Sendable, Equatable {
    var fontName: String
    var fontSize: CGFloat
    var glyphs: [UInt16]
    var positions: [CGPoint]
    var color: MathColor

    init(fontName: String,
         fontSize: CGFloat,
         glyphs: [UInt16],
         positions: [CGPoint],
         color: MathColor = .black) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.glyphs = glyphs
        self.positions = positions
        self.color = color
    }
}

struct MathLine: Sendable, Equatable {
    var start: CGPoint
    var end: CGPoint
    var thickness: CGFloat

    init(start: CGPoint, end: CGPoint, thickness: CGFloat) {
        self.start = start
        self.end = end
        self.thickness = thickness
    }
}

struct MathPath: Sendable, Equatable {
    var elements: [MathPathElement]
    var lineWidth: CGFloat
    var color: MathColor
    var fill: Bool

    init(elements: [MathPathElement], lineWidth: CGFloat, color: MathColor = .black, fill: Bool = false) {
        self.elements = elements
        self.lineWidth = lineWidth
        self.color = color
        self.fill = fill
    }
}

enum MathPathElement: Sendable, Equatable {
    case moveTo(CGPoint)
    case lineTo(CGPoint)
    case quadTo(control: CGPoint, end: CGPoint)
    case curveTo(control1: CGPoint, control2: CGPoint, end: CGPoint)
    case close

    func shifted(dx: CGFloat, dy: CGFloat) -> MathPathElement {
        switch self {
        case .moveTo(let point):
            return .moveTo(CGPoint(x: point.x + dx, y: point.y + dy))
        case .lineTo(let point):
            return .lineTo(CGPoint(x: point.x + dx, y: point.y + dy))
        case .quadTo(let control, let end):
            return .quadTo(control: CGPoint(x: control.x + dx, y: control.y + dy),
                           end: CGPoint(x: end.x + dx, y: end.y + dy))
        case .curveTo(let c1, let c2, let end):
            return .curveTo(control1: CGPoint(x: c1.x + dx, y: c1.y + dy),
                            control2: CGPoint(x: c2.x + dx, y: c2.y + dy),
                            end: CGPoint(x: end.x + dx, y: end.y + dy))
        case .close:
            return .close
        }
    }
}

extension MathDrawCommand {
    func shifted(dx: CGFloat, dy: CGFloat) -> MathDrawCommand {
        switch self {
        case .glyph(var run):
            run.positions = run.positions.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            return .glyph(run)
        case .line(var line):
            line.start = CGPoint(x: line.start.x + dx, y: line.start.y + dy)
            line.end = CGPoint(x: line.end.x + dx, y: line.end.y + dy)
            return .line(line)
        case .path(var path):
            path.elements = path.elements.map { $0.shifted(dx: dx, dy: dy) }
            return .path(path)
        }
    }
}

extension MathPath {
    func shifted(dx: CGFloat, dy: CGFloat) -> MathPath {
        MathPath(elements: elements.map { $0.shifted(dx: dx, dy: dy) },
                  lineWidth: lineWidth,
                  color: color,
                  fill: fill)
    }
}

struct MathColor: Sendable, Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static let black = MathColor(red: 0, green: 0, blue: 0, alpha: 1)
}

enum MathRenderError: Error, Equatable {
    case unsupportedCommand(String)
    case parseFailure(String)
}
