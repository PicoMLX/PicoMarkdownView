#if canImport(AppKit) && !canImport(UIKit)
import AppKit

/// Draws the quote gutter without installing a TextKit 1 layout manager.
final class MacBlockquoteTextLayoutFragment: NSTextLayoutFragment {
    private var attributes: [NSAttributedString.Key: Any] {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else { return [:] }
        return paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
    }

    override var renderingSurfaceBounds: CGRect {
        let level = attributes[.picoBlockquoteLevel] as? Int ?? 0
        let inset = attributes[.picoBlockquoteBarInset] as? CGFloat ?? 0
        let gutter = CGRect(x: 0, y: 0, width: inset + BlockquoteBarMetrics.textIndent(level: level), height: layoutFragmentFrame.height)
        return level > 0 ? super.renderingSurfaceBounds.union(gutter) : super.renderingSurfaceBounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let values = attributes
        let level = values[.picoBlockquoteLevel] as? Int ?? 0
        if level > 0 {
            let inset = values[.picoBlockquoteBarInset] as? CGFloat ?? 0
            let color = values[.picoBlockquoteBarColor] as? NSColor ?? .separatorColor
            context.saveGState()
            context.setFillColor(color.cgColor)
            for index in 0..<level {
                context.fill(CGRect(x: point.x + inset + BlockquoteBarMetrics.barOffset(barIndex: index),
                                    y: point.y, width: BlockquoteBarMetrics.barWidth, height: layoutFragmentFrame.height))
            }
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }
}
#endif
