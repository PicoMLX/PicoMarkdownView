#if canImport(AppKit) && !canImport(UIKit)
import AppKit

/// The macOS renderer always uses TextKit 2. None of its sizing, hit testing,
/// decoration or attachment paths may consult NSTextView.layoutManager.
@MainActor
final class StreamingTextKit2View: NSTextView, NSTextLayoutManagerDelegate {
    private let backend: TextKitStreamingBackend
    private(set) lazy var codeBlockCopyControls = MacCodeBlockCopyControls(textView: self) { [weak backend = self.backend] id in
        backend?.codeBlockForCopy(id: id)?.code
    }
    var onMermaidContentWidthChanged: ((CGFloat?) -> Void)?
    var onContentSizeChanged: ((CGSize) -> Void)?
    var linkActionHandler: ((URL, String) -> Void)?
    var hoverHandler: ((URL?, String, CGRect?) -> Void)?
    private var lastMermaidWidthBucket: Int?
    private var lastLaidOutWidth: CGFloat = -1
    private var lastReportedContentSize = CGSize(width: -1, height: -1)
    private var hoverTrackingArea: NSTrackingArea?
    private weak var codeCopyClipView: NSClipView?
    private var lastHoverLinkStart: Int?
    private var measuring = false

    init(backend: TextKitStreamingBackend) {
        self.backend = backend
        let content = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        content.addTextLayoutManager(manager)
        manager.textContainer = container
        super.init(frame: .zero, textContainer: container)
        backend.connect(to: content, layoutManager: manager)
        manager.delegate = self
        isRichText = true
        importsGraphics = true
        isEditable = false
        isHorizontallyResizable = false
        isVerticallyResizable = true
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        register([.onScrollingOutOfViewport, .onEditingInlineParagraphs],
                 forTextAttachmentViewProviderType: PicoHostedAttachmentViewProvider.self)
        backend.onDocumentReset = { [weak self] in self?.codeBlockCopyControls.clear() }
        backend.onHostedContentSizeChanged = { [weak self] range in
            self?.invalidateHostedLayout(in: range)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                                       textLayoutFragmentFor location: NSTextLocation,
                                       in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            let attributes = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
            if attributes[.picoBlockquoteLevel] != nil || attributes[.picoCodeBlockBackgroundColor] != nil
                || attributes[.picoCodeBlockToolbarHeight] != nil
                || attributes[.attachment] is MacHorizontalRuleAttachment || attributes[.picoHeadingUnderlinePadding] != nil {
                return MacMarkdownTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    /// Hit testing for context menus uses the visible image, not the wider
    /// hosted attachment frame. Activation itself uses native link tracking.
    func imageCanvasTarget(at point: NSPoint) -> PicoHostedMediaCanvasView? {
        Self.imageCanvasTarget(atWindowPoint: convert(point, to: nil), in: self)
    }

    private static func imageCanvasTarget(atWindowPoint point: NSPoint, in view: NSView) -> PicoHostedMediaCanvasView? {
        let local = view.convert(point, from: nil)
        guard view.window != nil, !view.isHidden, view.alphaValue > 0,
              view.bounds.intersection(view.visibleRect).contains(local) else { return nil }
        if let canvas = view as? PicoHostedMediaCanvasView, canvas.model.isImage { return canvas }
        for child in view.subviews.reversed() {
            if let target = imageCanvasTarget(atWindowPoint: point, in: child) { return target }
        }
        return nil
    }

    override func magnify(with event: NSEvent) {
        if PicoHostedContentHostingView.forwardMagnification(with: event, in: self) { return }
        super.magnify(with: event)
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = Self.linkURL(from: link), backend.isImageActivationLink(url) {
            // TextKit's own link tracking distinguishes a click from dragging
            // a selection. The actual image is narrower than some host frames.
            if let event = NSApp.currentEvent, event.windowNumber == window?.windowNumber,
               event.type == .leftMouseDown || event.type == .leftMouseUp {
                guard let canvas = imageCanvasTarget(at: convert(event.locationInWindow, from: nil)),
                      backend.imageAttachmentRange(for: canvas)?.location == charIndex else { return }
            }
            _ = backend.activateImageLink(url, at: charIndex)
            return
        }
        guard let handler = linkActionHandler, let url = Self.linkURL(from: link) else {
            super.clicked(onLink: link, at: charIndex)
            return
        }
        handler(url, linkDisplayText(at: charIndex))
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: flag)
        updateHostedContent()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
        updateHostedContent()
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        // Hosted content has a Markdown representation, not an archived view.
        // Keep AppKit's rich-copy formats for selections without a hosted block.
        selectionContainsHostedContent ? [.string] : super.writablePasteboardTypes
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, selectedRanges.contains(where: { $0.rangeValue.length > 0 }) else {
            return super.writeSelection(to: pboard, type: type)
        }
        return pboard.setString(markdownForSelection(), forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let canvas = imageCanvasTarget(at: point), let id = backend.imageID(for: canvas) {
            // Do not expose AppKit's Open Link/Copy Link actions for our
            // private image-activation route. Source export stays Markdown.
            let menu = NSMenu()
            let item = NSMenuItem(title: "Copy Image Markdown", action: #selector(copyImageMarkdown(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ImageCopyRequest(id: id, generation: backend.documentGeneration)
            menu.addItem(item)
            return menu
        }
        if let link = linkHit(at: point, includeImageActivation: true)?.url,
           backend.isImageActivationLink(link) { return NSMenu() }
        let menu = super.menu(for: event) ?? NSMenu()
        guard let id = codeBlockID(at: point),
              backend.codeBlockForCopy(id: id) != nil else { return menu }
        let item = NSMenuItem(title: "Copy code", action: #selector(copyCodeBlock(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = CodeBlockCopyRequest(id: id, generation: backend.documentGeneration)
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func copyImageMarkdown(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? ImageCopyRequest,
              request.generation == backend.documentGeneration,
              let markdown = backend.imageMarkdownForCopy(id: request.id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    private struct ImageCopyRequest {
        let id: BlockID
        let generation: UInt64
    }

    @objc private func copyCodeBlock(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? CodeBlockCopyRequest,
              request.generation == backend.documentGeneration,
              let code = backend.codeBlockForCopy(id: request.id)?.code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    private struct CodeBlockCopyRequest {
        let id: BlockID
        let generation: UInt64
    }

    private func codeBlockID(at point: NSPoint) -> BlockID? {
        guard let fragment = textLayoutManager?.textLayoutFragment(for: CGPoint(
            x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)) else { return nil }
        return MacCodeBlockCopy.blockID(in: fragment)
    }

    private var selectionContainsHostedContent: Bool {
        guard let storage = textStorage else { return false }
        for value in selectedRanges {
            let range = NSIntersectionRange(value.rangeValue, NSRange(location: 0, length: storage.length))
            var found = false
            storage.enumerateAttribute(.attachment, in: range) { attachment, _, stop in
                if attachment is PicoHostedAttachment { found = true; stop.pointee = true }
            }
            if found { return true }
        }
        return false
    }

    func markdownForSelection() -> String {
        guard let storage = textStorage else { return "" }
        return selectedRanges.map { value in
            let range = NSIntersectionRange(value.rangeValue, NSRange(location: 0, length: storage.length))
            let selected = storage.attributedSubstring(from: range)
            var result = ""
            selected.enumerateAttributes(in: NSRange(location: 0, length: selected.length)) { attributes, run, _ in
                if let attachment = attributes[.attachment] as? PicoHostedAttachment {
                    result += attachment.markdownRepresentation()
                } else {
                    result += (selected.string as NSString).substring(with: run)
                }
            }
            return result
        }.joined(separator: "\n")
    }

    override var intrinsicContentSize: NSSize {
        guard !isVerticallyResizable else { return super.intrinsicContentSize }
        guard bounds.width > 0 else {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: measuredContentSize().height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeCodeCopyViewport()
        if window == nil { codeBlockCopyControls.clear() }
        if window != nil {
            needsLayout = true
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }

    private func observeCodeCopyViewport() {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: codeCopyClipView)
        codeCopyClipView = window == nil ? nil : enclosingScrollView?.contentView
        if let codeCopyClipView {
            codeCopyClipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(codeCopyViewportChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: codeCopyClipView)
        }
    }

    @objc private func codeCopyViewportChanged(_ notification: Notification) {
        codeBlockCopyControls.updateLayout()
    }

    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        let buttons = codeBlockCopyControls.buttons.values.sorted { $0.frame.minY < $1.frame.minY }
        for button in buttons where !children.contains(where: { ($0 as? NSView) === button }) {
            children.append(button)
        }
        return children
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            updateHostedContent()
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        updateHostedContent()
        notifyMermaidContentWidthIfNeeded()
        let size = measuredContentSize()
        codeBlockCopyControls.updateLayout()
        if let onContentSizeChanged, bounds.width > 0,
           abs(size.width - lastReportedContentSize.width) > 0.5 || abs(size.height - lastReportedContentSize.height) > 0.5 {
            lastReportedContentSize = size
            onContentSizeChanged(size)
        }
        if !isVerticallyResizable { invalidateIntrinsicContentSize() }
    }

    private func measuredContentSize() -> CGSize {
        guard !measuring, bounds.width > 0,
              let manager = textLayoutManager, let content = manager.textContentManager else {
            return CGSize(width: bounds.width, height: max(0, lastReportedContentSize.height))
        }
        measuring = true
        defer { measuring = false }
        let width = max(1, bounds.width - textContainerInset.width * 2)
        if abs(width - lastLaidOutWidth) > 0.5 {
            lastLaidOutWidth = width
            textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            manager.invalidateLayout(for: content.documentRange)
        }
        // SwiftUI embeds a complete message in a List/LazyVStack, so it needs
        // the message's full height. Streaming edits remain block-local.
        manager.ensureLayout(for: content.documentRange)
        // Usage bounds can retain the extent of removed code after a large
        // streamed fence becomes an attachment. Use the current final fragment.
        var contentHeight: CGFloat = 0
        if !content.documentRange.isEmpty {
            manager.enumerateTextLayoutFragments(from: nil,
                options: [.reverse, .ensuresLayout, .ensuresExtraLineFragment]) { fragment in
                contentHeight = fragment.layoutFragmentFrame.maxY
                return false
            }
        }
        let height = ceil(contentHeight + textContainerInset.height * 2)
        return CGSize(width: bounds.width, height: max(0, height))
    }

    private func updateHostedContent() {
        backend.updateHostedAttachments(width: max(1, bounds.width - textContainerInset.width * 2),
                                        selection: selectedRanges.map(\.rangeValue))
    }

    private func invalidateHostedLayout(in range: NSRange) {
        guard let manager = textLayoutManager, let content = manager.textContentManager,
              let textRange = textRange(range, in: content) else { return }
        manager.invalidateLayout(for: textRange)
        needsLayout = true
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    private func notifyMermaidContentWidthIfNeeded() {
        let width = bounds.width - textContainerInset.width * 2
        let normalized = width > 0 ? width : nil
        let bucket = normalized.map { Int(($0 / 8).rounded(.toNearestOrAwayFromZero)) }
        guard bucket != lastMermaidWidthBucket else { return }
        lastMermaidWidthBucket = bucket
        onMermaidContentWidthChanged?(normalized)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        codeBlockCopyControls.updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        codeBlockCopyControls.updateHover(at: convert(event.locationInWindow, from: nil))
        guard let hoverHandler else { return }
        if let info = hoverLink(at: convert(event.locationInWindow, from: nil)) {
            guard info.linkStart != lastHoverLinkStart else { return }
            lastHoverLinkStart = info.linkStart
            hoverHandler(info.url, info.displayText, info.rect)
        } else { clearHover() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        codeBlockCopyControls.updateHover(at: nil)
        clearHover()
    }

    private func clearHover() {
        guard lastHoverLinkStart != nil else { return }
        lastHoverLinkStart = nil
        hoverHandler?(nil, "", nil)
    }

    /// TextKit 2 geometry keeps ordinary link and tag hover out of compatibility mode.
    func hoverLink(at point: NSPoint) -> (url: URL?, displayText: String, linkStart: Int, rect: CGRect?)? {
        linkHit(at: point, includeImageActivation: false)
    }

    private func linkHit(at point: NSPoint, includeImageActivation: Bool)
        -> (url: URL?, displayText: String, linkStart: Int, rect: CGRect?)? {
        guard let manager = textLayoutManager, let content = manager.textContentManager,
              let storage = textStorage, storage.length > 0 else { return nil }
        let nearest = min(characterIndexForInsertion(at: point), storage.length - 1)
        for index in [nearest, max(0, nearest - 1)] {
            var range = NSRange(location: 0, length: 0)
            guard let link = storage.attribute(.link, at: index, longestEffectiveRange: &range,
                in: NSRange(location: 0, length: storage.length)), let textRange = textRange(range, in: content) else { continue }
            if !includeImageActivation, let url = Self.linkURL(from: link), backend.isImageActivationLink(url) { continue }
            var hitRect: CGRect?
            manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
                let viewRect = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                if viewRect.contains(point) { hitRect = viewRect; return false }
                return true
            }
            if let hitRect {
                return (Self.linkURL(from: link), storage.attributedSubstring(from: range).string, range.location, hitRect)
            }
        }
        return nil
    }

    private func textRange(_ range: NSRange, in content: NSTextContentManager) -> NSTextRange? {
        guard let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    private static func linkURL(from link: Any) -> URL? {
        if let url = link as? URL { return url }
        if let string = link as? String { return URL(string: string) }
        return nil
    }

    private func linkDisplayText(at index: Int) -> String {
        guard let storage = textStorage, index >= 0, index < storage.length else { return "" }
        var range = NSRange(location: 0, length: 0)
        _ = storage.attribute(.link, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length))
        return storage.attributedSubstring(from: range).string
    }
}
#endif
