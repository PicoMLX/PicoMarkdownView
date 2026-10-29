import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension NSAttributedString.Key {
    /// 1-based blockquote nesting level. The text views draw one vertical
    /// bar per level in the leading gutter of ranges carrying this attribute
    /// (the bars are drawn, not characters — they don't participate in
    /// selection or copy).
    static let picoBlockquoteLevel = NSAttributedString.Key("picoBlockquoteLevel")

    /// Platform color for the drawn blockquote bars. Dynamic colors adapt
    /// to light/dark automatically at draw time.
    static let picoBlockquoteBarColor = NSAttributedString.Key("picoBlockquoteBarColor")

    /// Distance from the leading edge to the first bar, for a quote inside
    /// a list item, whose bars start at the item's text column.
    static let picoBlockquoteBarInset = NSAttributedString.Key("picoBlockquoteBarInset")
}

/// Shared geometry for drawn blockquote bars. The renderer reserves a text
/// gutter with these metrics; the views draw bars into it.
enum BlockquoteBarMetrics {
    /// Width of each vertical bar.
    static let barWidth: CGFloat = 3
    /// Horizontal distance between the leading edges of successive bars.
    static let levelStep: CGFloat = 12
    /// Gap between the deepest bar and the start of the text.
    static let textGap: CGFloat = 9

    /// Head indent that clears the bars for a quote at `level`.
    static func textIndent(level: Int) -> CGFloat {
        CGFloat(max(level - 1, 0)) * levelStep + barWidth + textGap
    }

    /// Leading x-offset of the bar for `barIndex` (0-based).
    static func barOffset(barIndex: Int) -> CGFloat {
        CGFloat(barIndex) * levelStep
    }
}

/// Draws vertical quote bars. Bar color resolves against the current drawing
/// appearance, so dynamic colors follow light/dark.
enum BlockquoteBarDrawer {
    static func drawBars(level: Int, color: MarkdownColor, in rect: CGRect) {
        guard level > 0, rect.height > 0 else { return }
        for index in 0..<level {
            fillBar(atIndex: index,
                    x: rect.minX,
                    top: rect.minY,
                    bottom: rect.maxY,
                    color: color)
        }
    }

    static func fillBar(atIndex index: Int, x: CGFloat, top: CGFloat, bottom: CGFloat, color: MarkdownColor) {
        guard bottom > top else { return }
        color.setFill()
        let barRect = CGRect(x: x + BlockquoteBarMetrics.barOffset(barIndex: index),
                             y: top,
                             width: BlockquoteBarMetrics.barWidth,
                             height: bottom - top)
        #if canImport(UIKit)
        UIBezierPath(rect: barRect).fill()
        #else
        NSBezierPath(rect: barRect).fill()
        #endif
    }

    static var fallbackColor: MarkdownColor {
        #if canImport(UIKit)
        return .separator
        #else
        return .separatorColor
        #endif
    }
}

#if canImport(UIKit)
/// TextKit 2 hook (iOS 16+): a layout fragment that draws blockquote bars
/// across its own height before rendering the paragraph text.
@available(iOS 16.0, *)
final class BlockquoteBarTextLayoutFragment: NSTextLayoutFragment {
    private var quoteLevel: Int {
        guard let paragraph = textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0,
              let level = paragraph.attributedString.attribute(.picoBlockquoteLevel,
                                                               at: 0,
                                                               effectiveRange: nil) as? Int
        else { return 0 }
        return level
    }

    private var barInset: CGFloat {
        guard let paragraph = textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0 else { return 0 }
        return paragraph.attributedString.attribute(.picoBlockquoteBarInset, at: 0, effectiveRange: nil) as? CGFloat ?? 0
    }

    private var barColor: MarkdownColor {
        guard let paragraph = textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0,
              let color = paragraph.attributedString.attribute(.picoBlockquoteBarColor,
                                                               at: 0,
                                                               effectiveRange: nil) as? MarkdownColor
        else { return BlockquoteBarDrawer.fallbackColor }
        return color
    }

    override var renderingSurfaceBounds: CGRect {
        let level = quoteLevel
        guard level > 0 else { return super.renderingSurfaceBounds }
        // Extend the drawing area to cover the leading gutter where the bars
        // live (text is indented past it, so the default surface may exclude it).
        let gutter = CGRect(x: 0,
                            y: 0,
                            width: barInset + BlockquoteBarMetrics.textIndent(level: level),
                            height: layoutFragmentFrame.height)
        return super.renderingSurfaceBounds.union(gutter)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let level = quoteLevel
        if level > 0 {
            context.saveGState()
            UIGraphicsPushContext(context)
            let barRect = CGRect(x: point.x + barInset,
                                 y: point.y,
                                 width: BlockquoteBarMetrics.textIndent(level: level),
                                 height: layoutFragmentFrame.height)
            BlockquoteBarDrawer.drawBars(level: level, color: barColor, in: barRect)
            UIGraphicsPopContext()
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }
}
#endif
