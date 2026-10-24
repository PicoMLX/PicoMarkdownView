import Foundation
import CoreGraphics

/// Turns SVG path data (`d="M0,0 L10,0 A5,5 0 0 1 20,0 Z"`) into a `CGPath`.
///
/// Implements the whole SVG 1.1 path grammar — absolute and relative
/// moves, lines, horizontal/vertical lines, cubic and quadratic curves with
/// their smooth variants, elliptical arcs and close — because Pele's shapes
/// use most of it (arcs for cylinders and stadiums, quadratics for waves).
enum PeleSVGPath {
    static func parse(_ data: String) -> CGPath? {
        var tokens = Tokenizer(data)
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadraticControl: CGPoint?
        var hasCommands = false

        guard var command = tokens.nextCommand() else { return nil }

        while true {
            hasCommands = true
            var nextCubicControl: CGPoint?
            var nextQuadraticControl: CGPoint?
            let relative = command.isLowercase
            let upper = Character(command.uppercased())

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch upper {
            case "M":
                guard let x = tokens.nextNumber(), let y = tokens.nextNumber() else { return nil }
                current = point(x, y)
                subpathStart = current
                path.move(to: current)
                // Further coordinate pairs after a move are implicit line-tos.
                command = relative ? "l" : "L"
            case "L":
                guard let x = tokens.nextNumber(), let y = tokens.nextNumber() else { return nil }
                current = point(x, y)
                path.addLine(to: current)
            case "H":
                guard let x = tokens.nextNumber() else { return nil }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case "V":
                guard let y = tokens.nextNumber() else { return nil }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case "C":
                guard let x1 = tokens.nextNumber(), let y1 = tokens.nextNumber(),
                      let x2 = tokens.nextNumber(), let y2 = tokens.nextNumber(),
                      let x = tokens.nextNumber(), let y = tokens.nextNumber() else { return nil }
                let control1 = point(x1, y1)
                let control2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: control1, control2: control2)
                nextCubicControl = control2
            case "S":
                guard let x2 = tokens.nextNumber(), let y2 = tokens.nextNumber(),
                      let x = tokens.nextNumber(), let y = tokens.nextNumber() else { return nil }
                let control1 = lastCubicControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let control2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: control1, control2: control2)
                nextCubicControl = control2
            case "Q":
                guard let x1 = tokens.nextNumber(), let y1 = tokens.nextNumber(),
                      let x = tokens.nextNumber(), let y = tokens.nextNumber() else { return nil }
                let control = point(x1, y1)
                current = point(x, y)
                path.addQuadCurve(to: current, control: control)
                nextQuadraticControl = control
            case "T":
                guard let x = tokens.nextNumber(), let y = tokens.nextNumber() else { return nil }
                let control = lastQuadraticControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                current = point(x, y)
                path.addQuadCurve(to: current, control: control)
                nextQuadraticControl = control
            case "A":
                guard let rx = tokens.nextNumber(), let ry = tokens.nextNumber(),
                      let rotation = tokens.nextNumber(),
                      let largeArc = tokens.nextFlag(), let sweep = tokens.nextFlag(),
                      let x = tokens.nextNumber(), let y = tokens.nextNumber() else { return nil }
                let end = point(x, y)
                addArc(to: path, from: current, to: end, rx: rx, ry: ry,
                       rotationDegrees: rotation, largeArc: largeArc, sweep: sweep)
                current = end
            case "Z":
                path.closeSubpath()
                current = subpathStart
            default:
                return nil
            }

            lastCubicControl = nextCubicControl
            lastQuadraticControl = nextQuadraticControl

            if upper == "Z" || !tokens.peekIsNumber() {
                guard let next = tokens.nextCommand() else { break }
                command = next
            }
            // Otherwise the same command repeats with the next argument set.
        }

        return hasCommands ? path : nil
    }

    /// Elliptical arc per SVG 1.1 appendix F.6.5, approximated with cubic
    /// Béziers of at most a quarter turn each.
    private static func addArc(to path: CGMutablePath, from start: CGPoint, to end: CGPoint,
                               rx radiusX: CGFloat, ry radiusY: CGFloat, rotationDegrees: CGFloat,
                               largeArc: Bool, sweep: Bool) {
        if start == end { return }
        var rx = abs(radiusX)
        var ry = abs(radiusY)
        if rx == 0 || ry == 0 {
            path.addLine(to: end)
            return
        }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }

        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coefficient = denominator == 0 ? 0 : sqrt(numerator / denominator)
        if largeArc == sweep { coefficient = -coefficient }
        let cx1 = coefficient * (rx * y1 / ry)
        let cy1 = coefficient * -(ry * x1 / rx)
        let center = CGPoint(x: cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2,
                             y: sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2)

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let length = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            guard length > 0 else { return 0 }
            var value = acos(min(max(dot / length, -1), 1))
            if ux * vy - uy * vx < 0 { value = -value }
            return value
        }

        let startAngle = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let tangent = 4 / 3 * tan(step / 4)

        func pointOnEllipse(_ theta: CGFloat) -> CGPoint {
            let x = rx * cos(theta)
            let y = ry * sin(theta)
            return CGPoint(x: cosPhi * x - sinPhi * y + center.x, y: sinPhi * x + cosPhi * y + center.y)
        }

        func derivative(_ theta: CGFloat) -> CGPoint {
            let x = -rx * sin(theta)
            let y = ry * cos(theta)
            return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
        }

        var theta = startAngle
        for segment in 0..<segments {
            let next = theta + step
            let p0 = pointOnEllipse(theta)
            let p3 = segment == segments - 1 ? end : pointOnEllipse(next)
            let d0 = derivative(theta)
            let d3 = derivative(next)
            let control1 = CGPoint(x: p0.x + tangent * d0.x, y: p0.y + tangent * d0.y)
            let control2 = CGPoint(x: p3.x - tangent * d3.x, y: p3.y - tangent * d3.y)
            path.addCurve(to: p3, control1: control1, control2: control2)
            theta = next
        }
    }

    // MARK: Tokenizer

    private struct Tokenizer {
        private let scalars: [UInt8]
        private var index = 0

        init(_ string: String) {
            scalars = Array(string.utf8)
        }

        private mutating func skipSeparators() {
            while index < scalars.count {
                let byte = scalars[index]
                if byte == UInt8(ascii: ",") || byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n")
                    || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r") {
                    index += 1
                } else {
                    return
                }
            }
        }

        mutating func nextCommand() -> Character? {
            skipSeparators()
            guard index < scalars.count else { return nil }
            let byte = scalars[index]
            guard (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) else {
                return nil
            }
            index += 1
            return Character(UnicodeScalar(byte))
        }

        mutating func peekIsNumber() -> Bool {
            skipSeparators()
            guard index < scalars.count else { return false }
            let byte = scalars[index]
            return byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
        }

        mutating func nextNumber() -> CGFloat? {
            skipSeparators()
            guard index < scalars.count else { return nil }
            let start = index
            var sawDigit = false
            var sawDot = false
            var sawExponent = false
            if scalars[index] == UInt8(ascii: "-") || scalars[index] == UInt8(ascii: "+") { index += 1 }
            while index < scalars.count {
                let byte = scalars[index]
                if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                    sawDigit = true
                } else if byte == UInt8(ascii: "."), !sawDot, !sawExponent {
                    sawDot = true
                } else if (byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")), sawDigit, !sawExponent {
                    sawExponent = true
                    if index + 1 < scalars.count, scalars[index + 1] == UInt8(ascii: "-") || scalars[index + 1] == UInt8(ascii: "+") {
                        index += 1
                    }
                } else {
                    break
                }
                index += 1
            }
            guard sawDigit, let text = String(bytes: scalars[start..<index], encoding: .utf8), let value = Double(text), value.isFinite else {
                index = start
                return nil
            }
            return CGFloat(value)
        }

        /// Arc flags are single `0`/`1` characters that may be run together
        /// with what follows (`0 01` as well as `0 0 1`).
        mutating func nextFlag() -> Bool? {
            skipSeparators()
            guard index < scalars.count else { return nil }
            switch scalars[index] {
            case UInt8(ascii: "0"):
                index += 1
                return false
            case UInt8(ascii: "1"):
                index += 1
                return true
            default:
                return nil
            }
        }
    }
}
