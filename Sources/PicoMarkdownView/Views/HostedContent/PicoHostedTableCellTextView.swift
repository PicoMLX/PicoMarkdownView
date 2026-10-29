#if os(macOS)
import AppKit

@MainActor
final class PicoHostedTableCellTextView: NSTextView, PicoHostedAttachmentHitTarget {
    var onOpenLink: (@MainActor (PicoHostedTableLink) -> Void)?
    var onHoverLink: (@MainActor (URL?, String, CGRect?) -> Void)?
    private var source: AttributedString?
    private var contentWidth: CGFloat = 0
    private var columnAlignment: TableAlignment = .none
    private var linkRanges: [(link: PicoHostedTableLink, range: NSRange)] = []
    private var linkTrackingArea: NSTrackingArea?
    private var hoveredLinkID: String?

    func update(content: AttributedString, width: CGFloat, alignment: TableAlignment) {
        let width = max(1, width)
        guard source != content || abs(width - contentWidth) > 0.5 || columnAlignment != alignment else { return }
        source = content
        contentWidth = width
        columnAlignment = alignment
        let attributed = NSMutableAttributedString(attributedString: .picoConverted(from: content))
        if attributed.length == 0 { attributed.append(NSAttributedString(string: " ")) }
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.textBlocks = []
            paragraph.headIndent = 0
            paragraph.firstLineHeadIndent = 0
            paragraph.tailIndent = 0
            paragraph.paragraphSpacing = 0
            paragraph.paragraphSpacingBefore = 0
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = switch alignment {
            case .left, .none: .left
            case .center: .center
            case .right: .right
            }
            attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        attributed.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            if value == nil { attributed.addAttribute(.font, value: NSFont.preferredFont(forTextStyle: .body), range: range) }
        }
        attributed.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, let image = attachment.image else { return }
            let original = attachment.bounds == .zero ? CGRect(origin: .zero, size: image.size) : attachment.bounds
            guard original.width > width else { return }
            let scale = width / original.width
            let copy = NSTextAttachment()
            copy.image = image
            copy.bounds = CGRect(x: original.minX * scale, y: original.minY * scale,
                                 width: original.width * scale, height: original.height * scale)
            attributed.addAttribute(.attachment, value: copy, range: range)
        }
        linkRanges.removeAll(keepingCapacity: true)
        attributed.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            guard let url else { return }
            let label = (attributed.string as NSString).substring(with: range)
            linkRanges.append((PicoHostedTableLink(id: String(range.location), url: url, label: label), range))
        }
        textContainer?.containerSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if let content = textContentStorage, let storage = content.textStorage {
            content.performEditingTransaction { storage.setAttributedString(attributed) }
        }
        needsDisplay = true
        invalidateIntrinsicContentSize()
        updateTrackingAreas()
    }

    func contentHeight() -> CGFloat {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return 1 }
        manager.ensureLayout(for: content.documentRange)
        var bottom: CGFloat = 1
        manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout]) { fragment in
            bottom = max(bottom, fragment.layoutFragmentFrame.maxY)
            return true
        }
        return ceil(bottom)
    }

    func acceptsHostedAttachmentHit(at point: NSPoint) -> Bool { link(at: point) != nil }

    override func mouseDown(with event: NSEvent) {
        guard let hit = link(at: convert(event.locationInWindow, from: nil)) else { return }
        onOpenLink?(hit.link)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkTrackingArea { removeTrackingArea(linkTrackingArea) }
        linkTrackingArea = nil
        guard !linkRanges.isEmpty else { clearHover(); return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        linkTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { clearHover() }

    private func updateHover(_ event: NSEvent) {
        guard let hit = link(at: convert(event.locationInWindow, from: nil)) else { clearHover(); return }
        guard hit.link.id != hoveredLinkID else { return }
        hoveredLinkID = hit.link.id
        var ancestor = superview
        while let view = ancestor, !(view is NSTextView) { ancestor = view.superview }
        let rect = ancestor.map { convert(hit.rect, to: $0) }
        onHoverLink?(hit.link.url, hit.link.label, rect)
    }

    private func clearHover() {
        guard hoveredLinkID != nil else { return }
        hoveredLinkID = nil
        onHoverLink?(nil, "", nil)
    }

    private func link(at point: NSPoint) -> (link: PicoHostedTableLink, rect: CGRect)? {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return nil }
        let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        for entry in linkRanges {
            guard let start = content.location(content.documentRange.location, offsetBy: entry.range.location),
                  let end = content.location(start, offsetBy: entry.range.length),
                  let range = NSTextRange(location: start, end: end) else { continue }
            var hit: CGRect?
            manager.enumerateTextSegments(in: range, type: .standard, options: []) { _, rect, _, _ in
                if rect.contains(local) { hit = rect; return false }
                return true
            }
            if let hit {
                return (entry.link, hit.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
            }
        }
        return nil
    }
}
#endif
