#if canImport(AppKit) && !canImport(UIKit)
import AppKit

/// Keeps Markdown decorations in the same TextKit 2 paragraph as selectable text.
final class MacMarkdownTextLayoutFragment: NSTextLayoutFragment {
    private struct Decoration {
        var rect: CGRect
        var color: NSColor
    }

    private var attributes: [NSAttributedString.Key: Any] {
        Self.attributes(of: self)
    }

    private static func attributes(of fragment: NSTextLayoutFragment) -> [NSAttributedString.Key: Any] {
        guard let paragraph = fragment.textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0 else { return [:] }
        return paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
    }

    private static func contentBounds(of fragment: NSTextLayoutFragment) -> CGRect? {
        // The synthetic empty line at the document end is not part of the quote.
        fragment.textLineFragments.filter { $0.characterRange.length > 0 }
            .map(\.typographicBounds).reduce(nil) { bounds, line in
                bounds.map { $0.union(line) } ?? line
            }
    }

    private var quoteBars: [Decoration] {
        let values = attributes
        guard let level = values[.picoBlockquoteLevel] as? Int, level > 0,
              let content = Self.contentBounds(of: self) else { return [] }
        let inset = values[.picoBlockquoteBarInset] as? CGFloat ?? 0
        let color = values[.picoBlockquoteBarColor] as? NSColor ?? .separatorColor
        let next = nextFragment
        let nextValues = next.map(Self.attributes) ?? [:]
        let nextLevel = nextValues[.picoBlockquoteLevel] as? Int ?? 0
        let nextInset = nextValues[.picoBlockquoteBarInset] as? CGFloat ?? 0
        let joinsNext = nextLevel > 0 && abs(inset - nextInset) < 0.5
        let contentBottom = max(content.maxY, MacHeadingUnderline.rect(for: self)?.maxY ?? content.maxY)
        return (0..<level).map { index in
            var bottom = contentBottom
            if joinsNext, index < nextLevel, let next,
               let nextContent = Self.contentBounds(of: next) {
                bottom = max(bottom, next.layoutFragmentFrame.minY - layoutFragmentFrame.minY + nextContent.minY)
            }
            // Paragraph indentation moves the fragment origin. The gutter is
            // anchored to the container, including when a quote encloses a list.
            let x = inset + BlockquoteBarMetrics.barOffset(barIndex: index) - layoutFragmentFrame.minX
            return Decoration(rect: CGRect(x: x, y: content.minY,
                                            width: BlockquoteBarMetrics.barWidth,
                                            height: max(0, bottom - content.minY)), color: color)
        }
    }

    private var nextFragment: NSTextLayoutFragment? {
        guard let range = textElement?.elementRange,
              let next = textLayoutManager?.textLayoutFragment(for: range.endLocation),
              next !== self, next.state.rawValue >= NSTextLayoutFragment.State.layoutAvailable.rawValue else { return nil }
        return next
    }

    private var decorations: [Decoration] {
        var result: [Decoration] = []
        if let background = MacCodeBlockBackground.decoration(for: self) {
            result.append(Decoration(rect: background.rect, color: background.color))
        }
        if let rect = MacHeadingUnderline.rect(for: self) {
            result.append(Decoration(rect: rect, color: .separatorColor))
        }
        if attributes[.attachment] is MacHorizontalRuleAttachment,
           let line = textLineFragments.first(where: { $0.characterRange.length > 0 }) {
            let bounds = line.typographicBounds
            // Attachment coordinates sit on the text baseline; the line's
            // typographic bounds also include the paragraph's leading space.
            let rect = CGRect(x: bounds.minX,
                              y: bounds.minY + line.glyphOrigin.y - MacHorizontalRuleAttachment.thickness,
                              width: bounds.width, height: MacHorizontalRuleAttachment.thickness)
            result.append(Decoration(rect: rect, color: .secondaryLabelColor))
        }
        result.append(contentsOf: quoteBars)
        return result
    }

    override var renderingSurfaceBounds: CGRect {
        decorations.reduce(super.renderingSurfaceBounds) { $0.union($1.rect) }
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        for decoration in decorations {
            context.setFillColor(decoration.color.cgColor)
            context.fill(decoration.rect.offsetBy(dx: point.x, dy: point.y))
        }
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}
#endif
