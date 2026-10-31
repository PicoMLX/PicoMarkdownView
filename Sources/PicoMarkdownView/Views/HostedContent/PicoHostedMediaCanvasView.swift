#if os(macOS)
import AppKit

/// Draws vector content into the current display context.
/// Zoom changes drawing coordinates, never a previously rasterized image.
@MainActor
final class PicoHostedMediaCanvasView: NSView, PicoHostedAttachmentHitTarget, PicoHostedAttachmentMagnificationTarget {
    let model: PicoHostedMediaModel
    var isSelected = false { didSet { needsDisplay = true } }
    private static let buttonSize: CGFloat = 32
    private static let groupSpacing: CGFloat = 8
    private let toolbar = NSGlassEffectContainerView()
    private let toolbarContent = NSView()
    private let zoomGlass = NSGlassEffectView()
    private let zoomControl = PicoHostedMediaZoomControl(frame: .zero)
    private let copyButton = PicoHostedMediaButton(title: "", target: nil, action: nil)
    private var isPointerInside = false
    private var hasControlFocus = false
    private var isTakingPointerFocus = false
    private var controlsAreVisible = false
    private var tracking: NSTrackingArea?
    private var dragPoint: CGPoint?
    private var accessibilitySource: String?
    private var accessibilityKind: PicoHostedMediaModel.Kind?
    private let reducesMotion: @MainActor () -> Bool
    private var zoomAnimationTask: Task<Void, Never>?
    private var zoomAnimationGeneration: UInt64 = 0
    private var zoomAnimationViewportSize: CGSize?
    private var isApplyingAnimatedZoom = false
    private(set) var presentedDrawingRect: CGRect?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !model.isImage || model.canActivateImage }

    init(model: PicoHostedMediaModel,
         reducesMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.model = model
        self.reducesMotion = reducesMotion
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(model.isImage ? .image : .group)
        setAccessibilityLabel(model.accessibilityLabel)
        focusRingType = .exterior
        if !model.isImage { setupToolbar() }
        model.onPresentationChanged = { [weak self] in self?.refreshPresentation() }
        refreshPresentation()
    }

    required init?(coder: NSCoder) { fatalError("Create a vector canvas with its model") }

    deinit { zoomAnimationTask?.cancel() }

    private var viewport: CGRect { bounds }

    override func layout() {
        super.layout()
        if let size = zoomAnimationViewportSize, size != viewport.size { cancelZoomAnimation() }
        model.updateViewport(viewport.size)
        guard !model.isImage else { needsDisplay = true; return }
        // Keep the zoom pair connected, including when Copy wraps below it.
        let zoomWidth = Self.buttonSize * 2
        let rowWidth = zoomWidth + Self.groupSpacing + Self.buttonSize
        let stacked = bounds.width - 16 < rowWidth
        let width = stacked ? zoomWidth : rowWidth
        let height = stacked ? Self.buttonSize * 2 + Self.groupSpacing : Self.buttonSize
        toolbar.frame = CGRect(x: max(8, bounds.width - width - 8), y: 8,
                               width: width, height: height)
        toolbarContent.frame = toolbar.bounds
        zoomGlass.frame = CGRect(x: 0, y: stacked ? Self.buttonSize + Self.groupSpacing : 0,
                                 width: zoomWidth, height: Self.buttonSize)
        zoomControl.frame = zoomGlass.bounds
        copyButton.frame = CGRect(x: stacked ? width - Self.buttonSize : zoomWidth + Self.groupSpacing,
                                  y: 0, width: Self.buttonSize, height: Self.buttonSize)
        refreshPointerPresence()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !model.isImage else { return }
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
                                  owner: self, userInfo: nil)
        addTrackingArea(next)
        tracking = next
        refreshPointerPresence()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hasControlFocus = false; cancelZoomAnimation() }
        refreshPointerPresence()
    }

    private func refreshPointerPresence() {
        if let window, window.isKeyWindow {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isPointerInside = bounds.intersection(visibleRect).contains(point)
        } else {
            isPointerInside = false
        }
        updateToolbarVisibility()
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true; updateToolbarVisibility() }
    override func mouseExited(with event: NSEvent) { isPointerInside = false; updateToolbarVisibility() }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { hasControlFocus = !isTakingPointerFocus; updateToolbarVisibility() }
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
        context.saveGState()
        context.clip(to: viewport)
        let destination = (presentedDrawingRect ?? model.drawingRect(in: viewport.size))
            .offsetBy(dx: viewport.minX, dy: viewport.minY)
        model.draw(in: context, destination: destination)
        context.restoreGState()
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
        !isHidden && !model.isImage && viewport.contains(point) && model.capturesScroll
    }

    func acceptsHostedAttachmentMagnification(at point: NSPoint) -> Bool {
        !isHidden && !model.isImage && viewport.contains(point)
    }

    override func accessibilityPerformPress() -> Bool {
        model.isImage ? model.activateImage() : super.accessibilityPerformPress()
    }

    override func mouseDown(with event: NSEvent) {
        guard !model.isImage else { super.mouseDown(with: event); return }
        cancelZoomAnimation()
        isTakingPointerFocus = true
        window?.makeFirstResponder(self)
        isTakingPointerFocus = false
        hasControlFocus = false
        updateToolbarVisibility()
        model.activateNavigation()
        dragPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !model.isImage else { super.mouseDragged(with: event); return }
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

    override func magnify(with event: NSEvent) {
        guard !model.isImage else { super.magnify(with: event); return }
        cancelZoomAnimation()
        model.zoom(by: exp(event.magnification))
    }

    override func keyDown(with event: NSEvent) {
        if model.isImage {
            if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
               [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? ""), model.activateImage() { return }
            super.keyDown(with: event)
            return
        }
        hasControlFocus = true
        updateToolbarVisibility()
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoomIn(nil)
        case "-": zoomOut(nil)
        case "0": fitDiagram(nil)
        case "\u{1b}": cancelOperation(nil)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard !model.isImage else { super.cancelOperation(sender); return }
        cancelZoomAnimation()
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
        let markdown = NSMenuItem(title: model.kind.copyTitle, action: #selector(copyMarkdown(_:)), keyEquivalent: "")
        markdown.target = self
        menu.addItem(markdown)
        if !model.isImage {
            let source = NSMenuItem(title: "Copy source", action: #selector(copySource(_:)), keyEquivalent: "")
            source.target = self
            menu.addItem(source)
        }
        return menu
    }

    func refreshPresentation() {
        // An open vector source has no drawing yet. Keep its native view stable, but
        // exclude it and its controls from input and accessibility while the
        // SwiftUI loading row supplies the presentation.
        isHidden = model.isLoading
        guard !isHidden else { return }
        // Source, pan and gesture updates interrupt an in-flight button zoom.
        if !isApplyingAnimatedZoom { cancelZoomAnimation() }
        if model.isImage {
            setAccessibilityRole(model.canActivateImage ? .button : .image)
            setAccessibilityLabel(model.accessibilityLabel)
            setAccessibilityHelp(model.imageAccessibilityHelp)
            setAccessibilityValue(nil)
            var actions = [NSAccessibilityCustomAction(name: model.kind.copyTitle) { [weak model] in model?.copyMarkdown() ?? false }]
            if model.canActivateImage {
                actions.insert(NSAccessibilityCustomAction(name: "Open image") { [weak model] in model?.activateImage() ?? false }, at: 0)
            }
            setAccessibilityCustomActions(actions)
        } else {
            zoomControl.setEnabled(model.zoom > 0.25, forSegment: 0)
            zoomControl.setEnabled(model.zoom < 8, forSegment: 1)
            zoomControl.setAccessibilityValue("\(Int((model.zoom * 100).rounded())) percent")
            let state = "\(Int((model.zoom * 100).rounded())) percent zoom. \(model.isClosed ? "Complete" : "Streaming preview")."
            setAccessibilityValue([state, model.document?.accessibilitySummary].compactMap { $0 }.joined(separator: " "))
            if accessibilityKind != model.kind {
                accessibilityKind = model.kind
                zoomControl.setAccessibilityLabel(model.kind.noun + " zoom")
                zoomControl.setAccessibilityHelp("Zoom within the " + model.kind.noun.lowercased() + " frame. Press Escape to reset zoom and return to the text.")
                configureCopyLabels()
                accessibilitySource = nil
            }
            if accessibilitySource != model.source {
                accessibilitySource = model.source
                setAccessibilityLabel(model.accessibilityLabel)
                setAccessibilityHelp("Source: " + model.source)
            }
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Zoom in") { [weak self] in self?.zoomIn(nil); return self != nil },
                NSAccessibilityCustomAction(name: "Zoom out") { [weak self] in self?.zoomOut(nil); return self != nil },
                NSAccessibilityCustomAction(name: model.kind.copyTitle) { [weak model] in model?.copyMarkdown() ?? false },
                NSAccessibilityCustomAction(name: "Copy source") { [weak model] in model?.copySource() ?? false }
            ])
        }
        needsDisplay = true
        updateToolbarVisibility()
    }

    private func setupToolbar() {
        toolbar.alphaValue = 0
        toolbar.spacing = 0
        toolbar.contentView = toolbarContent
        addSubview(toolbar)

        zoomControl.segmentCount = 2
        zoomControl.trackingMode = .momentary
        zoomControl.segmentStyle = .rounded
        zoomControl.borderShape = .capsule
        zoomControl.segmentDistribution = .fillEqually
        zoomControl.controlSize = .regular
        zoomControl.cell?.isBordered = false
        zoomControl.target = self
        zoomControl.action = #selector(changeZoom(_:))
        let symbols = [("minus.magnifyingglass", "Zoom out", "Zoom out (−). Press Escape to reset."),
                       ("plus.magnifyingglass", "Zoom in", "Zoom in (+). Press Escape to reset.")]
        for (index, item) in symbols.enumerated() {
            let image = NSImage(systemSymbolName: item.0, accessibilityDescription: item.1)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            zoomControl.setImage(image, forSegment: index)
            zoomControl.setToolTip(item.2, forSegment: index)
        }
        zoomControl.setAccessibilityLabel(model.kind.noun + " zoom")
        zoomControl.setAccessibilityHelp("Zoom within the " + model.kind.noun.lowercased() + " frame. Press Escape to reset zoom and return to the text.")
        zoomGlass.contentView = zoomControl
        zoomGlass.cornerRadius = Self.buttonSize / 2
        zoomGlass.effectIsInteractive = true
        toolbarContent.addSubview(zoomGlass)

        copyButton.target = self
        copyButton.action = #selector(copyMarkdown(_:))
        configureCopyLabels()
        copyButton.bezelStyle = .glass
        copyButton.borderShape = .circle
        copyButton.controlSize = .regular
        copyButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        copyButton.imagePosition = .imageOnly
        toolbarContent.addSubview(copyButton)

        let focusChanged: (Bool) -> Void = { [weak self] focused in
            self?.hasControlFocus = focused
            self?.updateToolbarVisibility()
        }
        zoomControl.onFocusChanged = focusChanged
        copyButton.onFocusChanged = focusChanged
    }

    private func configureCopyLabels() {
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: model.kind.copyTitle)
        copyButton.setAccessibilityLabel(model.kind.copyTitle)
        copyButton.setAccessibilityHelp(model.kind.copyHelp)
        copyButton.toolTip = model.kind.copyToolTip
    }

    private func updateToolbarVisibility() {
        let shown = !model.isImage && (isPointerInside || hasControlFocus)
        guard shown != controlsAreVisible else { return }
        controlsAreVisible = shown
        toolbar.alphaValue = shown ? 1 : 0
        zoomControl.acceptsPointerHit = shown
        copyButton.acceptsPointerHit = shown
    }

    @objc private func changeZoom(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { zoomOut(sender) }
        if sender.selectedSegment == 1 { zoomIn(sender) }
    }

    private func animateZoom(by factor: CGFloat) {
        let startRect = presentedDrawingRect ?? model.drawingRect(in: viewport.size)
        let previousZoom = model.zoom
        isApplyingAnimatedZoom = true
        model.zoom(by: factor)
        isApplyingAnimatedZoom = false
        guard model.zoom != previousZoom else { return }
        cancelZoomAnimation()
        let endRect = model.drawingRect(in: viewport.size)
        guard window != nil, viewport.width > 0, viewport.height > 0,
              !reducesMotion(), startRect != endRect else { return }

        let transition = PicoMediaZoomAnimation(from: startRect, to: endRect)
        presentedDrawingRect = startRect
        zoomAnimationViewportSize = viewport.size
        let generation = zoomAnimationGeneration
        let clock = ContinuousClock()
        let start = clock.now
        zoomAnimationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.zoomAnimationGeneration == generation else { return }
                guard !self.reducesMotion() else { self.cancelZoomAnimation(); return }
                let elapsed = start.duration(to: clock.now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let progress = seconds / PicoMediaZoomAnimation.duration
                self.presentedDrawingRect = transition.rect(at: progress)
                self.needsDisplay = true
                if progress >= 1 {
                    self.presentedDrawingRect = nil
                    self.zoomAnimationViewportSize = nil
                    self.zoomAnimationTask = nil
                    return
                }
                do { try await Task.sleep(for: .nanoseconds(16_666_667)) }
                catch { return }
            }
        }
    }

    /// Wait for the currently scheduled transition, including its final
    /// presentation cleanup, without assuming a frame-delivery deadline.
    func waitForZoomAnimation() async {
        await zoomAnimationTask?.value
    }

    private func cancelZoomAnimation() {
        zoomAnimationGeneration &+= 1
        zoomAnimationTask?.cancel()
        zoomAnimationTask = nil
        zoomAnimationViewportSize = nil
        if presentedDrawingRect != nil { presentedDrawingRect = nil; needsDisplay = true }
    }

    @objc private func zoomIn(_ sender: Any?) { animateZoom(by: 1.25) }
    @objc private func zoomOut(_ sender: Any?) { animateZoom(by: 1 / 1.25) }
    @objc private func fitDiagram(_ sender: Any?) { cancelZoomAnimation(); model.fitDiagram() }
    @objc private func copyMarkdown(_ sender: Any?) { model.copyMarkdown() }
    @objc private func copySource(_ sender: Any?) { model.copySource() }
}

typealias PicoHostedVectorCanvasView = PicoHostedMediaCanvasView
typealias PicoHostedMermaidCanvasView = PicoHostedMediaCanvasView

/// Interpolates vector drawing coordinates; no cached image is scaled.
struct PicoMediaZoomAnimation {
    static let duration: TimeInterval = 0.18
    let from: CGRect
    let to: CGRect

    func rect(at progress: Double) -> CGRect {
        let t = min(1, max(0, progress))
        let eased = CGFloat(1 - pow(1 - t, 3))
        func value(_ start: CGFloat, _ end: CGFloat) -> CGFloat { start + (end - start) * eased }
        return CGRect(x: value(from.minX, to.minX), y: value(from.minY, to.minY),
                      width: value(from.width, to.width), height: value(from.height, to.height))
    }
}

typealias PicoVectorZoomAnimation = PicoMediaZoomAnimation
typealias PicoMermaidZoomAnimation = PicoMediaZoomAnimation

@MainActor
private final class PicoHostedMediaZoomControl: NSSegmentedControl, PicoHostedAttachmentHitTarget {
    var acceptsPointerHit = false
    var onFocusChanged: ((Bool) -> Void)?
    private var isTakingPointerFocus = false

    func acceptsHostedAttachmentHit(at point: NSPoint) -> Bool { acceptsPointerHit && bounds.contains(point) }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChanged?(!isTakingPointerFocus) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChanged?(false) }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        isTakingPointerFocus = true
        onFocusChanged?(false)
        defer { isTakingPointerFocus = false }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onFocusChanged?(true)
        super.keyDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { acceptsPointerHit ? super.hitTest(point) : nil }
}

@MainActor
private final class PicoHostedMediaButton: NSButton, PicoHostedAttachmentHitTarget {
    var acceptsPointerHit = false
    var onFocusChanged: ((Bool) -> Void)?
    private var isTakingPointerFocus = false

    func acceptsHostedAttachmentHit(at point: NSPoint) -> Bool { acceptsPointerHit && bounds.contains(point) }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChanged?(!isTakingPointerFocus) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChanged?(false) }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        isTakingPointerFocus = true
        onFocusChanged?(false)
        defer { isTakingPointerFocus = false }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onFocusChanged?(true)
        super.keyDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { acceptsPointerHit ? super.hitTest(point) : nil }
}
#endif
