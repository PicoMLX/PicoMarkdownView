#if canImport(AppKit) && !canImport(UIKit)
import AppKit

extension NSAttributedString.Key {
    static let picoCodeBlockID = NSAttributedString.Key("PicoMarkdownCodeBlockID")
    static let picoCodeBlockBackgroundColor = NSAttributedString.Key("PicoMarkdownCodeBlockBackgroundColor")
}

/// Block decoration is separate from character backgrounds, which TextKit 2
/// draws only behind the text. All returned geometry is fragment-local.
enum MacCodeBlockBackground {
    static func decoration(for fragment: NSTextLayoutFragment) -> (rect: CGRect, color: NSColor)? {
        guard let paragraph = fragment.textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0,
              let id = paragraph.attributedString.attribute(.picoCodeBlockID, at: 0, effectiveRange: nil) as? NSNumber,
              let color = paragraph.attributedString.attribute(.picoCodeBlockBackgroundColor, at: 0, effectiveRange: nil) as? NSColor,
              let manager = fragment.textLayoutManager,
              let container = manager.textContainer else { return nil }
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        guard let first = lines.first, let last = lines.last else { return nil }
        let paragraphStyle = paragraph.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let left = max(0, min(paragraphStyle?.headIndent ?? 0, paragraphStyle?.firstLineHeadIndent ?? 0))
        let tail = paragraphStyle?.tailIndent ?? 0
        let right = tail > 0 ? tail : container.size.width + tail
        let width = right - left
        guard width.isFinite, width > 0 else { return nil }

        let frame = fragment.layoutFragmentFrame
        let top = first.typographicBounds.minY
        // A fragment frame includes paragraph spacing. That margin separates
        // fences and must not be painted as part of either block.
        var bottom = last.typographicBounds.maxY
        if let elementRange = paragraph.elementRange,
           let next = manager.textLayoutFragment(for: elementRange.endLocation), next !== fragment,
           next.state == .layoutAvailable,
           let nextParagraph = next.textElement as? NSTextParagraph,
           nextParagraph.attributedString.length > 0,
           nextParagraph.attributedString.attribute(.picoCodeBlockID, at: 0, effectiveRange: nil) as? NSNumber == id,
           let nextLine = next.textLineFragments.first(where: { $0.characterRange.length > 0 }) {
            bottom = max(bottom, next.layoutFragmentFrame.minY + nextLine.typographicBounds.minY - frame.minY)
        }
        guard bottom > top else { return nil }
        return (CGRect(x: left - frame.minX, y: top, width: width, height: bottom - top), color)
    }
}
#endif
