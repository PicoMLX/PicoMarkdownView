#if canImport(AppKit)
import AppKit

/// A one-point rule whose width follows TextKit 2's current line fragment.
final class MacHorizontalRuleAttachment: NSTextAttachment {
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
        return CGRect(x: 0, y: 0, width: width, height: 1)
    }

    override func image(for imageBounds: CGRect, attributes: [NSAttributedString.Key: Any],
                        location: any NSTextLocation, textContainer: NSTextContainer?) -> NSImage? {
        NSImage(size: imageBounds.size, flipped: false) { rect in
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(rect: rect).fill()
            return true
        }
    }
}
#endif
