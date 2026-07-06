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

/// TextKit 1 hook: draws blockquote bars behind the text. Used by the iOS
/// TextKit 1 view and both macOS views (the macOS "TextKit 2" view runs on
/// an `NSLayoutManager` as well).
final class BlockquoteBarLayoutManager: NSLayoutManager {
    private struct BarSegment {
        var level: Int
        var color: MarkdownColor?
        var range: NSRange
        var rect: CGRect
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }

        // Expand the scan by one attribute run on each side so bars can be
        // bridged across paragraph gaps at the edges of the drawn region.
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var scanStart = min(charRange.location, storage.length - 1)
        if scanStart > 0 {
            var effective = NSRange(location: 0, length: 0)
            _ = storage.attribute(.picoBlockquoteLevel, at: scanStart - 1, effectiveRange: &effective)
            if effective.length > 0 { scanStart = effective.location }
        }
        var scanEnd = min(charRange.upperBound, storage.length)
        if scanEnd < storage.length {
            var effective = NSRange(location: 0, length: 0)
            _ = storage.attribute(.picoBlockquoteLevel, at: scanEnd, effectiveRange: &effective)
            if effective.length > 0 { scanEnd = max(scanEnd, effective.upperBound) }
        }
        guard scanEnd > scanStart else { return }

        var segments: [BarSegment] = []
        let scanRange = NSRange(location: scanStart, length: scanEnd - scanStart)
        storage.enumerateAttribute(.picoBlockquoteLevel, in: scanRange, options: []) { value, range, _ in
            guard let level = value as? Int, level > 0, range.length > 0 else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0,
                  let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
            var rect = boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x = origin.x
            rect.origin.y += origin.y
            let color = storage.attribute(.picoBlockquoteBarColor,
                                          at: range.location,
                                          effectiveRange: nil) as? MarkdownColor
            segments.append(BarSegment(level: level, color: color, range: range, rect: rect))
        }

        // Draw each segment's bars, extending a bar down to the next segment
        // when the neighbor is adjacent in the text and shares that level, so
        // the bar runs continuously across paragraph gaps and nested quotes
        // (GitHub-style) instead of breaking at every block boundary.
        for (index, segment) in segments.enumerated() {
            let next = index + 1 < segments.count ? segments[index + 1] : nil
            let joinsNext = next.map { segment.range.upperBound == $0.range.location } ?? false
            for barIndex in 0..<segment.level {
                var bottom = segment.rect.maxY
                if let next, joinsNext, next.level > barIndex {
                    bottom = max(bottom, next.rect.minY)
                }
                BlockquoteBarDrawer.fillBar(atIndex: barIndex,
                                            x: segment.rect.minX,
                                            top: segment.rect.minY,
                                            bottom: bottom,
                                            color: segment.color ?? BlockquoteBarDrawer.fallbackColor)
            }
        }
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
                            width: BlockquoteBarMetrics.textIndent(level: level),
                            height: layoutFragmentFrame.height)
        return super.renderingSurfaceBounds.union(gutter)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let level = quoteLevel
        if level > 0 {
            context.saveGState()
            UIGraphicsPushContext(context)
            let barRect = CGRect(x: point.x,
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
