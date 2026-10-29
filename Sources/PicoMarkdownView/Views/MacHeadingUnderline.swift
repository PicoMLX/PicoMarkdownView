#if canImport(AppKit) && !canImport(UIKit)
import AppKit

extension NSAttributedString.Key {
    static let picoHeadingUnderlinePadding = NSAttributedString.Key("PicoMarkdownHeadingUnderlinePadding")
}

/// GitHub-style H1/H2 borders are paragraph decorations, not text or blocks.
enum MacHeadingUnderline {
    static let thickness: CGFloat = 1

    static func applying(to content: NSAttributedString) -> NSAttributedString {
        guard content.length > 0 else { return content }
        let last = content.length - 1
        let range = (content.string as NSString).paragraphRange(for: NSRange(location: last, length: 1))
        let font = content.attribute(.font, at: last, effectiveRange: nil) as? NSFont
        let padding = (font?.pointSize ?? NSFont.systemFontSize) * 0.3
        let style = (content.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.paragraphSpacing += padding + thickness
        let result = NSMutableAttributedString(attributedString: content)
        // Only the final paragraph gets a border, even if the heading contains
        // explicit line breaks. Native wrapping stays within that paragraph.
        result.addAttributes([.paragraphStyle: style, .picoHeadingUnderlinePadding: padding], range: range)
        return result
    }

    static func rect(for fragment: NSTextLayoutFragment) -> CGRect? {
        guard let paragraph = fragment.textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
              let padding = paragraph.attributedString.attribute(.picoHeadingUnderlinePadding, at: 0, effectiveRange: nil) as? CGFloat,
              let line = fragment.textLineFragments.last(where: { $0.characterRange.length > 0 }),
              let container = fragment.textLayoutManager?.textContainer else { return nil }
        let style = paragraph.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let left = max(0, style?.headIndent ?? 0, style?.firstLineHeadIndent ?? 0)
        let tail = style?.tailIndent ?? 0
        let right = tail > 0 ? tail : container.size.width + tail
        guard right.isFinite, right > left else { return nil }
        return CGRect(x: left - fragment.layoutFragmentFrame.minX,
                      y: line.typographicBounds.maxY + padding,
                      width: right - left, height: thickness)
    }
}
#endif
