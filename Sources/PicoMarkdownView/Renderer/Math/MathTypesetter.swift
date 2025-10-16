import Foundation
import CoreGraphics
import CoreText

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
private typealias PlatformFontTrait = UIFontDescriptor.SymbolicTraits
private let italicTrait: PlatformFontTrait = .traitItalic
private let boldTrait: PlatformFontTrait = .traitBold
#else
private typealias PlatformFontTrait = NSFontDescriptor.SymbolicTraits
private let italicTrait: PlatformFontTrait = .italic
private let boldTrait: PlatformFontTrait = .bold
#endif

struct MathTypesetter {
    private let baseFont: PlatformFont
    private let romanFont: CTFont
    private let italicFont: CTFont
    private let boldFont: CTFont
    private let baseSize: CGFloat
    private let ruleThickness: CGFloat

    init(baseFont: PlatformFont) {
        self.baseFont = baseFont
        baseSize = baseFont.pointSize
        romanFont = baseFont.asCTFont()
        italicFont = baseFont.asCTFont(trait: italicTrait)
        boldFont = baseFont.asCTFont(trait: boldTrait)
        ruleThickness = max(1, baseSize * 0.05)
    }

    func artifact(for node: MathNode, display: Bool) -> MathRenderArtifact {
        let style: MathStyle = display ? .display : .text
        let box = layout(node, style: style)
        let size = CGSize(width: box.width, height: box.ascent + box.descent)
        return MathRenderArtifact(size: size, baseline: box.ascent, commands: box.commands)
    }

    private func layout(_ node: MathNode, style: MathStyle) -> MathBox {
        switch node {
        case .sequence(let items):
            return layoutSequence(items, style: style)
        case .symbol(let value, let symbolStyle):
            return glyphBox(text: value, style: symbolStyle, mathStyle: style)
        case .number(let value):
            return glyphBox(text: value, style: .upright, mathStyle: style)
        case .operatorToken(let token):
            let rendered = operatorGlyphs[token] ?? token
            return glyphBox(text: rendered, style: .upright, mathStyle: style)
        case .function(let name):
            return glyphBox(text: name, style: .upright, mathStyle: style)
        case .fraction(let numerator, let denominator):
            let num = layout(numerator, style: style.child)
            let den = layout(denominator, style: style.child)
            return layoutFraction(numerator: num, denominator: den)
        case .sqrt(let body, let index):
            let radicand = layout(body, style: style.child)
            let indexBox = index.map { layout($0, style: style.script) }
            return layoutSqrt(body: radicand, index: indexBox)
        case .scripts(let base, let superscript, let subscriptNode):
            let baseBox = layout(base, style: style)
            let supBox = superscript.map { layout($0, style: style.script) }
            let subBox = subscriptNode.map { layout($0, style: style.script) }
            return layoutScripts(base: baseBox, superscript: supBox, subscript: subBox)
        case .delimiter(let left, let body, let right):
            let inner = layout(body, style: style)
            return layoutDelimiter(left: left, body: inner, right: right)
        case .matrix(let matrixStyle, let rows):
            return layoutMatrix(rows: rows, style: matrixStyle, mathStyle: style)
        case .text(let literal):
            return glyphBox(text: literal, font: romanFont.withSize(style.scaledSize(base: baseSize)))
        case .spacing(let space):
            return spacingBox(space)
        case .accent(let accent, let base):
            let baseBox = layout(base, style: style.child)
            return layoutAccent(accent, base: baseBox)
        case .binomial(let top, let bottom):
            let num = layout(top, style: style.child)
            let den = layout(bottom, style: style.child)
            let fraction = layoutFraction(numerator: num, denominator: den)
            return layoutDelimiter(left: .parenthesisLeft, body: fraction, right: .parenthesisRight)
        case .cases(let rows):
            return layoutCases(rows, style: style)
        case .aligned(let rows):
            return layoutAligned(rows, style: style)
        }
    }

    private func layoutSequence(_ nodes: [MathNode], style: MathStyle) -> MathBox {
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var commands: [MathDrawCommand] = []

        for node in nodes {
            let box = layout(node, style: style)
            commands.append(contentsOf: box.commands.map { $0.shifted(dx: width, dy: 0) })
            width += box.width
            ascent = max(ascent, box.ascent)
            descent = max(descent, box.descent)
        }

        return MathBox(width: width, ascent: ascent, descent: descent, commands: commands)
    }

    private func glyphBox(text: String, style: MathSymbolStyle, mathStyle: MathStyle) -> MathBox {
        guard !text.isEmpty else { return .empty }
        let font = font(for: style, mathStyle: mathStyle)
        return glyphBox(text: text, font: font)
    }

    private func glyphBox(text: String, font: CTFont) -> MathBox {
        guard !text.isEmpty else { return .empty }
        var glyphs: [UInt16] = []
        var positions: [CGPoint] = []
        var cursor: CGFloat = 0
        for scalar in text.unicodeScalars {
            var glyph = CGGlyph()
            var value = UniChar(scalar.value)
            CTFontGetGlyphsForCharacters(font, &value, &glyph, 1)
            var copy = glyph
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &copy, &advance, 1)
            glyphs.append(UInt16(glyph))
            positions.append(CGPoint(x: cursor, y: 0))
            cursor += advance.width
        }
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let run = MathGlyphRun(fontName: CTFontCopyPostScriptName(font) as String,
                               fontSize: CTFontGetSize(font),
                               glyphs: glyphs,
                               positions: positions)
        return MathBox(width: cursor, ascent: ascent, descent: descent, commands: [.glyph(run)])
    }

    private func layoutFraction(numerator: MathBox, denominator: MathBox) -> MathBox {
        let gap = baseSize * 0.2
        let width = max(numerator.width, denominator.width) + baseSize * 0.2
        let numX = (width - numerator.width) / 2
        let denX = (width - denominator.width) / 2
        let lineY = baseSize * 0.1
        let numShift = lineY + gap + numerator.descent
        let denShift = -(lineY + gap + denominator.ascent)

        var commands: [MathDrawCommand] = []
        commands.append(contentsOf: numerator.commands.map { $0.shifted(dx: numX, dy: numShift) })
        commands.append(.line(MathLine(start: CGPoint(x: 0, y: lineY),
                                       end: CGPoint(x: width, y: lineY),
                                       thickness: ruleThickness)))
        commands.append(contentsOf: denominator.commands.map { $0.shifted(dx: denX, dy: denShift) })

        let ascent = max(numerator.ascent + numShift, lineY + ruleThickness)
        let descent = max(-(denShift - denominator.descent), lineY + ruleThickness)
        return MathBox(width: width, ascent: ascent, descent: descent, commands: commands)
    }

    private func layoutSqrt(body: MathBox, index: MathBox?) -> MathBox {
        let padding = baseSize * 0.4
        let height = body.ascent + body.descent + baseSize * 0.2
        var commands: [MathDrawCommand] = []
        let radical = MathPath(elements: MathPathElement.radical(width: body.width + padding, height: height),
                               lineWidth: ruleThickness)
        commands.append(.path(radical))
        commands.append(contentsOf: body.commands.map { $0.shifted(dx: padding, dy: 0) })

        var ascent = max(body.ascent, height)
        let descent = body.descent

        if let indexBox = index {
            let shiftY = body.ascent - indexBox.descent
            commands.append(contentsOf: indexBox.commands.map { $0.shifted(dx: 0, dy: shiftY) })
            ascent = max(ascent, shiftY + indexBox.ascent)
        }

        return MathBox(width: body.width + padding * 1.2, ascent: ascent, descent: descent, commands: commands)
    }

    private func layoutScripts(base: MathBox, superscript: MathBox?, subscript subscriptBox: MathBox?) -> MathBox {
        var commands = base.commands
        var width = base.width
        var ascent = base.ascent
        var descent = base.descent
        let gap = baseSize * 0.1

        if let superscript {
            let shiftX = width + gap
            let shiftY = base.ascent - baseSize * 0.25
            commands.append(contentsOf: superscript.commands.map { $0.shifted(dx: shiftX, dy: shiftY) })
            width = max(width, shiftX + superscript.width)
            ascent = max(ascent, shiftY + superscript.ascent)
        }

        if let subscriptBox {
            let shiftX = base.width + gap
            let shiftY = -(subscriptBox.descent + baseSize * 0.15)
            commands.append(contentsOf: subscriptBox.commands.map { $0.shifted(dx: shiftX, dy: shiftY) })
            width = max(width, shiftX + subscriptBox.width)
            descent = max(descent, -(shiftY - subscriptBox.descent))
        }

        return MathBox(width: width, ascent: ascent, descent: descent, commands: commands)
    }

    private func layoutDelimiter(left: MathDelimiter, body: MathBox, right: MathDelimiter) -> MathBox {
        let totalHeight = max(body.ascent + body.descent, baseSize)
        let leftBox = delimiterBox(left, height: totalHeight)
        let rightBox = delimiterBox(right, height: totalHeight)
        var commands: [MathDrawCommand] = []
        commands.append(contentsOf: leftBox.commands)
        commands.append(contentsOf: body.commands.map { $0.shifted(dx: leftBox.width, dy: 0) })
        commands.append(contentsOf: rightBox.commands.map { $0.shifted(dx: leftBox.width + body.width, dy: 0) })
        let ascent = max(body.ascent, leftBox.ascent, rightBox.ascent)
        let descent = max(body.descent, leftBox.descent, rightBox.descent)
        return MathBox(width: leftBox.width + body.width + rightBox.width,
                       ascent: ascent,
                       descent: descent,
                       commands: commands)
    }

    private func delimiterBox(_ delimiter: MathDelimiter, height: CGFloat) -> MathBox {
        guard height > 0 else { return .empty }
        switch delimiter {
        case .none:
            return .empty
        case .vertical:
            let line = MathLine(start: CGPoint(x: ruleThickness / 2, y: height / 2),
                                end: CGPoint(x: ruleThickness / 2, y: -height / 2),
                                thickness: ruleThickness)
            return MathBox(width: ruleThickness, ascent: height / 2, descent: height / 2, commands: [.line(line)])
        case .doubleVertical:
            let spacing = ruleThickness * 1.6
            let first = MathLine(start: CGPoint(x: ruleThickness / 2, y: height / 2), end: CGPoint(x: ruleThickness / 2, y: -height / 2), thickness: ruleThickness)
            let second = MathLine(start: CGPoint(x: spacing + ruleThickness / 2, y: height / 2), end: CGPoint(x: spacing + ruleThickness / 2, y: -height / 2), thickness: ruleThickness)
            return MathBox(width: spacing + ruleThickness, ascent: height / 2, descent: height / 2, commands: [.line(first), .line(second)])
        default:
            let path = MathPath(elements: MathPathElement.stretchy(delimiter: delimiter, height: height, thickness: ruleThickness),
                                lineWidth: ruleThickness)
            let width = baseSize * 0.6
            return MathBox(width: width, ascent: height / 2, descent: height / 2, commands: [.path(path)])
        }
    }

    private func layoutMatrix(rows: [[MathNode]], style: MathMatrixStyle, mathStyle: MathStyle) -> MathBox {
        guard !rows.isEmpty else { return .empty }
        let rowBoxes = rows.map { row in row.map { layout($0, style: mathStyle.child) } }
        let columnCount = rowBoxes.map { $0.count }.max() ?? 0
        var columnWidths = Array(repeating: CGFloat.zero, count: columnCount)
        var rowAscents: [CGFloat] = Array(repeating: 0, count: rowBoxes.count)
        var rowDescents: [CGFloat] = Array(repeating: 0, count: rowBoxes.count)

        for (rowIndex, row) in rowBoxes.enumerated() {
            for (columnIndex, box) in row.enumerated() {
                columnWidths[columnIndex] = max(columnWidths[columnIndex], box.width)
                rowAscents[rowIndex] = max(rowAscents[rowIndex], box.ascent)
                rowDescents[rowIndex] = max(rowDescents[rowIndex], box.descent)
            }
        }

        let columnGap = baseSize * 0.5
        let rowGap = baseSize * 0.3
        var commands: [MathDrawCommand] = []
        var cursorY: CGFloat = 0
        var maxAscent: CGFloat = 0

        for (rowIndex, row) in rowBoxes.enumerated() {
            var cursorX: CGFloat = 0
            let ascent = rowAscents[rowIndex]
            let descent = rowDescents[rowIndex]
            maxAscent = max(maxAscent, cursorY + ascent)

            for (columnIndex, box) in row.enumerated() {
                let shiftX = cursorX + (columnWidths[columnIndex] - box.width) / 2
                commands.append(contentsOf: box.commands.map { $0.shifted(dx: shiftX, dy: cursorY) })
                cursorX += columnWidths[columnIndex] + columnGap
            }

            cursorY += ascent + descent + rowGap
        }

        let contentWidth = columnWidths.reduce(0, +) + CGFloat(max(0, columnCount - 1)) * columnGap
        let matrixBox = MathBox(width: contentWidth, ascent: maxAscent, descent: cursorY - maxAscent, commands: commands)

        switch style {
        case .matrix:
            return matrixBox
        case .pmatrix:
            return layoutDelimiter(left: .parenthesisLeft, body: matrixBox, right: .parenthesisRight)
        }
    }

    private func layoutCases(_ rows: [(condition: MathNode, result: MathNode)], style: MathStyle) -> MathBox {
        guard !rows.isEmpty else { return .empty }
        let conditionBoxes = rows.map { layout($0.condition, style: style.child) }
        let resultBoxes = rows.map { layout($0.result, style: style.child) }
        let maxConditionWidth = conditionBoxes.map { $0.width }.max() ?? 0
        let gap = baseSize * 0.5
        var commands: [MathDrawCommand] = []
        var cursorY: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0

        for index in rows.indices {
            let cond = conditionBoxes[index]
            let result = resultBoxes[index]
            commands.append(contentsOf: cond.commands.map { $0.shifted(dx: baseSize * 0.7, dy: cursorY) })
            commands.append(contentsOf: result.commands.map { $0.shifted(dx: baseSize * 0.7 + maxConditionWidth + gap, dy: cursorY) })
            ascent = max(ascent, cursorY + cond.ascent, cursorY + result.ascent)
            descent = max(descent, -(cursorY - cond.descent), -(cursorY - result.descent))
            cursorY += max(cond.ascent + cond.descent, result.ascent + result.descent) + baseSize * 0.3
        }

        let brace = delimiterBox(.braceLeft, height: ascent + descent)
        commands.insert(contentsOf: brace.commands, at: 0)
        let width = brace.width + baseSize * 0.7 + maxConditionWidth + gap + (resultBoxes.map { $0.width }.max() ?? 0)
        return MathBox(width: width, ascent: ascent, descent: descent, commands: commands)
    }

    private func layoutAligned(_ rows: [[MathNode]], style: MathStyle) -> MathBox {
        guard !rows.isEmpty else { return .empty }
        let rowBoxes = rows.map { row in row.map { layout($0, style: style.child) } }
        let columnCount = rowBoxes.map { $0.count }.max() ?? 0
        var columnWidths = Array(repeating: CGFloat.zero, count: columnCount)
        for row in rowBoxes {
            for (index, box) in row.enumerated() {
                columnWidths[index] = max(columnWidths[index], box.width)
            }
        }

        let columnGap = baseSize * 0.4
        let rowGap = baseSize * 0.2
        var commands: [MathDrawCommand] = []
        var cursorY: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0

        for row in rowBoxes {
            var cursorX: CGFloat = 0
            var rowAscent: CGFloat = 0
            var rowDescent: CGFloat = 0
            for (index, box) in row.enumerated() {
                commands.append(contentsOf: box.commands.map { $0.shifted(dx: cursorX, dy: cursorY) })
                cursorX += columnWidths[index] + columnGap
                rowAscent = max(rowAscent, box.ascent)
                rowDescent = max(rowDescent, box.descent)
            }
            ascent = max(ascent, cursorY + rowAscent)
            descent = max(descent, -(cursorY - rowDescent))
            cursorY += rowAscent + rowDescent + rowGap
        }

        let width = columnWidths.reduce(0, +) + CGFloat(max(0, columnCount - 1)) * columnGap
        return MathBox(width: width, ascent: ascent, descent: descent, commands: commands)
    }

    private func spacingBox(_ kind: MathSpaceKind) -> MathBox {
        let width: CGFloat
        switch kind {
        case .thin: width = baseSize * 0.16
        case .medium: width = baseSize * 0.25
        case .quad: width = baseSize
        }
        return MathBox(width: width, ascent: 0, descent: 0, commands: [])
    }

    private func layoutAccent(_ accent: MathAccentKind, base: MathBox) -> MathBox {
        var commands = base.commands
        let accentBaseline = base.ascent + baseSize * 0.1
        switch accent {
        case .hat:
            let start = CGPoint(x: 0, y: accentBaseline)
            let peak = CGPoint(x: base.width / 2, y: accentBaseline + baseSize * 0.2)
            let end = CGPoint(x: base.width, y: accentBaseline)
            let path = MathPath(elements: [.moveTo(start), .lineTo(peak), .lineTo(end)], lineWidth: ruleThickness)
            commands.append(.path(path))
            return MathBox(width: base.width, ascent: accentBaseline + baseSize * 0.2, descent: base.descent, commands: commands)
        case .bar, .overline:
            let line = MathLine(start: CGPoint(x: 0, y: accentBaseline), end: CGPoint(x: base.width, y: accentBaseline), thickness: ruleThickness)
            commands.append(.line(line))
            return MathBox(width: base.width, ascent: accentBaseline + ruleThickness, descent: base.descent, commands: commands)
        case .vec:
            let line = MathLine(start: CGPoint(x: 0, y: accentBaseline), end: CGPoint(x: base.width, y: accentBaseline), thickness: ruleThickness)
            let arrow = MathPath(elements: [
                .moveTo(CGPoint(x: base.width - baseSize * 0.25, y: accentBaseline + baseSize * 0.12)),
                .lineTo(CGPoint(x: base.width, y: accentBaseline)),
                .lineTo(CGPoint(x: base.width - baseSize * 0.25, y: accentBaseline - baseSize * 0.12))
            ], lineWidth: ruleThickness)
            commands.append(.line(line))
            commands.append(.path(arrow))
            return MathBox(width: base.width, ascent: accentBaseline + baseSize * 0.2, descent: base.descent, commands: commands)
        }
    }

    private func font(for style: MathSymbolStyle, mathStyle: MathStyle) -> CTFont {
        let size = mathStyle.scaledSize(base: baseSize)
        switch style {
        case .italic:
            return italicFont.withSize(size)
        case .upright:
            return romanFont.withSize(size)
        case .bold:
            return boldFont.withSize(size)
        }
    }
}

private enum MathStyle {
    case display
    case text
    case script
    case scriptscript

    func scaledSize(base: CGFloat) -> CGFloat {
        switch self {
        case .display: return base
        case .text: return base * 0.95
        case .script: return base * 0.8
        case .scriptscript: return base * 0.7
        }
    }

    var child: MathStyle {
        switch self {
        case .display: return .text
        case .text: return .script
        case .script: return .scriptscript
        case .scriptscript: return .scriptscript
        }
    }

    var script: MathStyle {
        switch self {
        case .display, .text: return .script
        case .script, .scriptscript: return .scriptscript
        }
    }
}

private struct MathBox {
    var width: CGFloat
    var ascent: CGFloat
    var descent: CGFloat
    var commands: [MathDrawCommand]

    static let empty = MathBox(width: 0, ascent: 0, descent: 0, commands: [])
}

private extension PlatformFont {
    func asCTFont() -> CTFont {
#if canImport(UIKit)
        CTFontCreateWithFontDescriptor(fontDescriptor as CTFontDescriptor, pointSize, nil)
#else
        CTFontCreateWithFontDescriptor(fontDescriptor, pointSize, nil)
#endif
    }

    func asCTFont(trait: PlatformFontTrait) -> CTFont {
#if canImport(UIKit)
        let descriptor = fontDescriptor.withSymbolicTraits(trait) ?? fontDescriptor
        return CTFontCreateWithFontDescriptor(descriptor as CTFontDescriptor, pointSize, nil)
#else
        var traits = fontDescriptor.symbolicTraits
        traits.insert(trait)
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return CTFontCreateWithFontDescriptor(descriptor, pointSize, nil)
#endif
    }
}

private extension CTFont {
    func withSize(_ size: CGFloat) -> CTFont {
        CTFontCreateCopyWithAttributes(self, size, nil, nil)
    }
}

private let operatorGlyphs: [String: String] = [
    "sum": "∑",
    "prod": "∏",
    "int": "∫",
    "lim": "lim",
    "to": "→",
    "implies": "⇒",
    "iff": "⇔",
    "le": "≤",
    "ge": "≥",
    "neq": "≠",
    "approx": "≈",
    "in": "∈",
    "subseteq": "⊆",
    "supseteq": "⊇",
    "cup": "∪",
    "cap": "∩",
    "infty": "∞",
    "cdot": "·",
    "ldots": "…",
    "cdots": "⋯",
    "dots": "…"
]

private extension MathPathElement {
    static func stretchy(delimiter: MathDelimiter, height: CGFloat, thickness: CGFloat) -> [MathPathElement] {
        let half = height / 2
        let width = thickness * 4
        switch delimiter {
        case .parenthesisLeft:
            return [
                .moveTo(CGPoint(x: width, y: -half)),
                .quadTo(control: CGPoint(x: 0, y: -half), end: CGPoint(x: 0, y: 0)),
                .quadTo(control: CGPoint(x: 0, y: half), end: CGPoint(x: width, y: half))
            ]
        case .parenthesisRight:
            return [
                .moveTo(CGPoint(x: 0, y: -half)),
                .quadTo(control: CGPoint(x: width, y: -half), end: CGPoint(x: width, y: 0)),
                .quadTo(control: CGPoint(x: width, y: half), end: CGPoint(x: 0, y: half))
            ]
        case .bracketLeft:
            return [
                .moveTo(CGPoint(x: width, y: half)),
                .lineTo(CGPoint(x: 0, y: half)),
                .lineTo(CGPoint(x: 0, y: -half)),
                .lineTo(CGPoint(x: width, y: -half))
            ]
        case .bracketRight:
            return [
                .moveTo(CGPoint(x: 0, y: half)),
                .lineTo(CGPoint(x: width, y: half)),
                .lineTo(CGPoint(x: width, y: -half)),
                .lineTo(CGPoint(x: 0, y: -half))
            ]
        case .braceLeft:
            let control = width * 0.4
            return [
                .moveTo(CGPoint(x: width, y: half)),
                .lineTo(CGPoint(x: control, y: half)),
                .quadTo(control: CGPoint(x: 0, y: half), end: CGPoint(x: 0, y: control)),
                .quadTo(control: CGPoint(x: 0, y: 0), end: CGPoint(x: control, y: 0)),
                .quadTo(control: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: -control)),
                .quadTo(control: CGPoint(x: 0, y: -half), end: CGPoint(x: control, y: -half)),
                .lineTo(CGPoint(x: width, y: -half))
            ]
        case .braceRight:
            let control = width * 0.4
            return [
                .moveTo(CGPoint(x: 0, y: half)),
                .lineTo(CGPoint(x: width - control, y: half)),
                .quadTo(control: CGPoint(x: width, y: half), end: CGPoint(x: width, y: control)),
                .quadTo(control: CGPoint(x: width, y: 0), end: CGPoint(x: width - control, y: 0)),
                .quadTo(control: CGPoint(x: width, y: 0), end: CGPoint(x: width, y: -control)),
                .quadTo(control: CGPoint(x: width, y: -half), end: CGPoint(x: width - control, y: -half)),
                .lineTo(CGPoint(x: 0, y: -half))
            ]
        case .angleLeft:
            return [
                .moveTo(CGPoint(x: width, y: half)),
                .lineTo(CGPoint(x: 0, y: 0)),
                .lineTo(CGPoint(x: width, y: -half))
            ]
        case .angleRight:
            return [
                .moveTo(CGPoint(x: 0, y: half)),
                .lineTo(CGPoint(x: width, y: 0)),
                .lineTo(CGPoint(x: 0, y: -half))
            ]
        case .vertical, .doubleVertical, .none:
            return []
        }
    }

    static func radical(width: CGFloat, height: CGFloat) -> [MathPathElement] {
        let baseline = height * 0.2
        return [
            .moveTo(CGPoint(x: 0, y: baseline)),
            .lineTo(CGPoint(x: width * 0.25, y: 0)),
            .lineTo(CGPoint(x: width * 0.35, y: height * 0.6)),
            .lineTo(CGPoint(x: width, y: height * 0.6))
        ]
    }
}
