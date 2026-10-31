#if canImport(AppKit) && !canImport(UIKit)
import AppKit

extension NSAttributedString.Key {
    static let picoCodeBlockCopyID = NSAttributedString.Key("PicoMarkdownCodeBlockCopyID")
    static let picoCodeBlockToolbarHeight = NSAttributedString.Key("PicoMarkdownCodeBlockToolbarHeight")
}

/// Native paragraph space for code controls. No characters or attachments are
/// inserted, so selection and the source remain independent of the toolbar.
enum MacCodeBlockCopy {
    static let toolbarHeight: CGFloat = 40
    static let buttonSize: CGFloat = 32
    static let inset: CGFloat = 4

    static func applying(to attributed: NSAttributedString, id: BlockID) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed)
        guard result.length > 0 else { return result }
        result.addAttribute(.picoCodeBlockCopyID, value: NSNumber(value: id),
                            range: NSRange(location: 0, length: result.length))
        let firstParagraph = (result.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        result.addAttribute(.picoCodeBlockToolbarHeight, value: toolbarHeight, range: firstParagraph)
        return result
    }

    static func toolbarRect(for fragment: NSTextLayoutFragment) -> CGRect? {
        guard let paragraph = fragment.textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0,
              let height = paragraph.attributedString.attribute(.picoCodeBlockToolbarHeight, at: 0, effectiveRange: nil) as? CGFloat,
              let line = fragment.textLineFragments.first(where: { $0.characterRange.length > 0 }),
              let container = fragment.textLayoutManager?.textContainer else { return nil }
        let style = paragraph.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let left = max(0, min(style?.headIndent ?? 0, style?.firstLineHeadIndent ?? 0))
        let tail = style?.tailIndent ?? 0
        let right = tail > 0 ? tail : container.size.width + tail
        guard right - left >= buttonSize + inset * 2 else { return nil }
        return CGRect(x: left - fragment.layoutFragmentFrame.minX,
                      y: line.typographicBounds.minY - height, width: right - left, height: height)
    }

    static func blockID(in fragment: NSTextLayoutFragment) -> BlockID? {
        guard let paragraph = fragment.textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0 else { return nil }
        return (paragraph.attributedString.attribute(.picoCodeBlockCopyID, at: 0, effectiveRange: nil) as? NSNumber)?.uint64Value
    }
}
#endif
