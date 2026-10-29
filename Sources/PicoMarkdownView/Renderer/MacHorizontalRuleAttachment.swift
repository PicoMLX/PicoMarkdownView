#if canImport(AppKit)
import AppKit

/// Reserves a rule's layout space. MacMarkdownTextLayoutFragment paints it;
/// AppKit's default attachment cell has no image to draw.
final class MacHorizontalRuleAttachment: NSTextAttachment {
    static let thickness: CGFloat = 1

    init() {
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any],
                                   location: any NSTextLocation, textContainer: NSTextContainer?,
                                   proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let proposedWidth = proposedLineFragment.maxX - position.x
        let width = proposedWidth.isFinite ? max(1, proposedWidth) : 1
        return CGRect(x: 0, y: 0, width: width, height: Self.thickness)
    }
}
#endif
