#if os(macOS)
import AppKit

/// Replays the SVG paths and CoreText drawing into the current display context.
/// Zoom changes drawing coordinates, never a previously rasterized image.
@MainActor
final class PicoHostedMermaidCanvasView: NSView, PicoHostedAttachmentHitTarget {
    static let toolbarHeight: CGFloat = 38
    let model: PicoHostedMermaidModel
    var isSelected = false { didSet { needsDisplay = true } }
    private static let buttonSize: CGFloat = 28
    private static let buttonSpacing: CGFloat = 3
    private let toolbar = NSView()
    private var toolbarButtons: [PicoHostedMermaidButton] = []
    private var expandButton: PicoHostedMermaidButton?
    private var isPointerInside = false
    private var hasControlFocus = false
    private var tracking: NSTrackingArea?
    private var dragPoint: CGPoint?
    private var accessibilitySource: String?
    private var presentedExpansion: Bool?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(model: PicoHostedMermaidModel) {
        self.model = model
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Mermaid diagram")
        focusRingType = .exterior
        setupToolbar()
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Zoom in") { [weak self] in self?.zoomIn(nil); return self != nil },
            NSAccessibilityCustomAction(name: "Zoom out") { [weak self] in self?.zoomOut(nil); return self != nil },
            NSAccessibilityCustomAction(name: "Fit diagram") { [weak self] in self?.fitDiagram(nil); return self != nil },
            NSAccessibilityCustomAction(name: "Fit width") { [weak self] in self?.fitWidth(nil); return self != nil },
            NSAccessibilityCustomAction(name: "Expand or restore diagram") { [weak self] in self?.toggleExpanded(nil); return self != nil },
            NSAccessibilityCustomAction(name: "Copy Mermaid") { [weak model] in model?.copyMarkdown() ?? false },
            NSAccessibilityCustomAction(name: "Copy source") { [weak model] in model?.copySource() ?? false }
        ])
        model.onPresentationChanged = { [weak self] in self?.refreshPresentation() }
        refreshPresentation()
    }

    required init?(coder: NSCoder) { fatalError("Create a Mermaid canvas with its model") }

    private var viewport: CGRect {
        CGRect(x: 0, y: Self.toolbarHeight, width: bounds.width,
               height: max(1, bounds.height - Self.toolbarHeight))
    }

    override func layout() {
        super.layout()
        model.updateViewport(viewport.size)
        // Keep the native controls at a feasible size even while SwiftUI
        // measures the attachment with a zero or narrow width proposal.
        let width = CGFloat(toolbarButtons.count) * (Self.buttonSize + Self.buttonSpacing) - Self.buttonSpacing
        toolbar.frame = CGRect(x: max(4, bounds.width - width - 6), y: 5,
                               width: width, height: Self.buttonSize)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true; updateToolbarVisibility() }
    override func mouseExited(with event: NSEvent) { isPointerInside = false; updateToolbarVisibility() }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { hasControlFocus = true; updateToolbarVisibility() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { hasControlFocus = false; updateToolbarVisibility() }
        return accepted
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        context.saveGState()
        context.clip(to: viewport)
        if let document = model.document {
            let destination = model.drawingRect(in: viewport.size).offsetBy(dx: viewport.minX, dy: viewport.minY)
            context.translateBy(x: destination.minX, y: destination.minY)
            context.scaleBy(x: destination.width / document.width, y: destination.height / document.height)
            document.draw(in: context, strokesAsFills: true)
        }
        context.restoreGState()
        // Filled outlines avoid the macOS accelerated wide-line renderer,
        // which can submit an empty Metal draw when strokes are clipped.
        let border = CGPath(roundedRect: bounds.insetBy(dx: min(0.5, bounds.width / 2),
                                                       dy: min(0.5, bounds.height / 2)),
                            cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(border)
        context.setLineWidth(isSelected ? 2 : 1)
        context.replacePathWithStrokedPath()
        context.setFillColor((isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor)
        context.fillPath()
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            bounds.fill()
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    func acceptsHostedAttachmentHit(at point: NSPoint) -> Bool {
        viewport.contains(point) && model.capturesScroll
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        model.activateNavigation()
        dragPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let next = convert(event.locationInWindow, from: nil)
        if let dragPoint { model.pan(by: CGPoint(x: next.x - dragPoint.x, y: next.y - dragPoint.y)) }
        dragPoint = next
    }

    override func mouseUp(with event: NSEvent) { dragPoint = nil }

    override func scrollWheel(with event: NSEvent) {
        guard model.capturesScroll else { super.scrollWheel(with: event); return }
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let consumed = model.pan(by: CGPoint(x: event.scrollingDeltaX * multiplier,
                                            y: event.scrollingDeltaY * multiplier))
        if !consumed { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) { model.zoom(by: exp(event.magnification)) }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoomIn(nil)
        case "-": zoomOut(nil)
        case "0": fitDiagram(nil)
        case "f": fitWidth(nil)
        case "\u{1b}": cancelOperation(nil)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        model.fitDiagram()
        var ancestor = superview
        while let view = ancestor {
            if let text = view as? NSTextView { window?.makeFirstResponder(text); return }
            ancestor = view.superview
        }
        window?.makeFirstResponder(nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let markdown = NSMenuItem(title: "Copy Mermaid", action: #selector(copyMarkdown(_:)), keyEquivalent: "")
        markdown.target = self
        menu.addItem(markdown)
        let source = NSMenuItem(title: "Copy source", action: #selector(copySource(_:)), keyEquivalent: "")
        source.target = self
        menu.addItem(source)
        return menu
    }

    func refreshPresentation() {
        if presentedExpansion != model.isExpanded {
            presentedExpansion = model.isExpanded
            let label = model.isExpanded ? "Restore diagram size" : "Expand diagram"
            expandButton?.image = NSImage(systemSymbolName: model.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                         accessibilityDescription: label)
            expandButton?.setAccessibilityLabel(label)
            expandButton?.toolTip = label
        }
        setAccessibilityValue("\(Int((model.zoom * 100).rounded())) percent zoom. \(model.isClosed ? "Complete" : "Streaming preview").")
        if accessibilitySource != model.source {
            accessibilitySource = model.source
            setAccessibilityHelp("Diagram source: " + model.source)
        }
        needsDisplay = true
        updateToolbarVisibility()
    }

    private func setupToolbar() {
        addSubview(toolbar)
        addButton("minus.magnifyingglass", label: "Zoom out", action: #selector(zoomOut(_:)))
        addButton("plus.magnifyingglass", label: "Zoom in", action: #selector(zoomIn(_:)))
        addButton("arrow.down.right.and.arrow.up.left", label: "Fit diagram", action: #selector(fitDiagram(_:)))
        addButton("arrow.left.and.right", label: "Fit width", action: #selector(fitWidth(_:)))
        expandButton = addButton("arrow.up.left.and.arrow.down.right", label: "Expand diagram", action: #selector(toggleExpanded(_:)))
        addButton("doc.on.doc", label: "Copy Mermaid", action: #selector(copyMarkdown(_:)))
    }

    @discardableResult
    private func addButton(_ symbol: String, label: String, action: Selector) -> PicoHostedMermaidButton {
        let button = PicoHostedMermaidButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.setAccessibilityLabel(label) // [VERIFY] The labels describe the supplied toolbar actions.
        button.toolTip = label
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.imagePosition = .imageOnly
        button.onFocusChanged = { [weak self] focused in
            self?.hasControlFocus = focused
            self?.updateToolbarVisibility()
        }
        button.frame = CGRect(x: CGFloat(toolbarButtons.count) * (Self.buttonSize + Self.buttonSpacing),
                              y: 0, width: Self.buttonSize, height: Self.buttonSize)
        toolbar.addSubview(button)
        toolbarButtons.append(button)
        return button
    }

    private func updateToolbarVisibility() {
        let shown = isPointerInside || hasControlFocus
        toolbar.alphaValue = shown ? 1 : 0
        for button in toolbarButtons { button.acceptsPointerHit = shown }
    }

    @objc private func zoomIn(_ sender: Any?) { model.zoom(by: 1.25) }
    @objc private func zoomOut(_ sender: Any?) { model.zoom(by: 1 / 1.25) }
    @objc private func fitDiagram(_ sender: Any?) { model.fitDiagram() }
    @objc private func fitWidth(_ sender: Any?) { model.fitWidth() }
    @objc private func toggleExpanded(_ sender: Any?) { model.toggleExpanded() }
    @objc private func copyMarkdown(_ sender: Any?) { model.copyMarkdown() }
    @objc private func copySource(_ sender: Any?) { model.copySource() }
}

@MainActor
private final class PicoHostedMermaidButton: NSButton, PicoHostedAttachmentHitTarget {
    var acceptsPointerHit = false
    var onFocusChanged: ((Bool) -> Void)?

    func acceptsHostedAttachmentHit(at point: NSPoint) -> Bool { acceptsPointerHit && bounds.contains(point) }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChanged?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChanged?(false) }
        return accepted
    }

    override func hitTest(_ point: NSPoint) -> NSView? { acceptsPointerHit ? super.hitTest(point) : nil }
}
#endif
