#if canImport(AppKit) && !canImport(UIKit)
import AppKit

/// Native chrome for selectable code paragraphs. TextKit remains responsible
/// for the code, its selection, and all layout outside the reserved header.
@MainActor
final class MacCodeBlockCopyControls {
    private weak var textView: NSTextView?
    private let codeForBlock: (BlockID) -> String?
    private(set) var buttons: [BlockID: MacCodeBlockCopyButton] = [:]

    init(textView: NSTextView, codeForBlock: @escaping (BlockID) -> String?) {
        self.textView = textView
        self.codeForBlock = codeForBlock
    }

    func updateLayout() {
        guard let textView, let manager = textView.textLayoutManager,
              let content = manager.textContentManager else { clear(); return }
        let visible = textView.visibleRect.intersection(textView.bounds)
        guard !visible.isEmpty else { clear(); return }
        let origin = textView.textContainerOrigin
        let sample = NSPoint(x: max(0, visible.midX - origin.x), y: max(0, visible.minY - origin.y))
        // An outer SwiftUI scroll view can move the visible area before the
        // text view's own viewport controller updates its cached range.
        let start = manager.textLayoutFragment(for: sample)?.rangeInElement.location
            ?? content.location(content.documentRange.location,
                                offsetBy: textView.characterIndexForInsertion(at: NSPoint(x: visible.midX, y: visible.minY)))
            ?? manager.textViewportLayoutController.viewportRange?.location
        guard let start else { clear(); return }
        var visibleIDs: Set<BlockID> = []
        manager.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            guard fragment.state.rawValue >= NSTextLayoutFragment.State.layoutAvailable.rawValue else { return false }
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            guard frame.minY <= visible.maxY else { return false }
            guard let id = MacCodeBlockCopy.blockID(in: fragment),
                  let localHeader = MacCodeBlockCopy.toolbarRect(for: fragment) else { return true }
            let header = localHeader.offsetBy(dx: frame.minX, dy: frame.minY)
            guard header.intersects(visible) else { return true }
            let size = min(MacCodeBlockCopy.buttonSize, max(0, header.width - MacCodeBlockCopy.inset * 2))
            guard size > 0 else { return true }
            let buttonFrame = NSRect(x: header.maxX - MacCodeBlockCopy.inset - size,
                                     y: header.minY + MacCodeBlockCopy.inset,
                                     width: size, height: size)
            guard buttonFrame.intersects(visible) else { return true }
            visibleIDs.insert(id)
            let button: MacCodeBlockCopyButton
            if let existing = self.buttons[id] {
                button = existing
            } else {
                button = MacCodeBlockCopyButton { [weak self] in self?.codeForBlock(id) }
                self.buttons[id] = button
                textView.addSubview(button)
            }
            button.frame = buttonFrame
            return true
        }
        for id in Array(buttons.keys) where !visibleIDs.contains(id) { removeButton(for: id) }
        if let window = textView.window, window.isKeyWindow {
            updateHover(at: textView.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else {
            updateHover(at: nil)
        }
    }

    func updateHover(at point: NSPoint?) {
        var hoveredID: BlockID?
        if let point, let textView, textView.visibleRect.contains(point) {
            hoveredID = buttons.first(where: { $0.value.frame.contains(point) })?.key
            if hoveredID == nil, let manager = textView.textLayoutManager {
                let origin = textView.textContainerOrigin
                let position = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
                if let fragment = manager.textLayoutFragment(for: position) {
                    hoveredID = MacCodeBlockCopy.blockID(in: fragment)
                }
            }
        }
        for (id, button) in buttons { button.updateHover(id == hoveredID) }
    }

    func clear() {
        for id in Array(buttons.keys) { removeButton(for: id) }
    }

    private func removeButton(for id: BlockID) {
        guard let button = buttons.removeValue(forKey: id) else { return }
        button.invalidate()
        button.removeFromSuperview()
    }
}

@MainActor
final class MacCodeBlockCopyButton: NSButton {
    private var code: (() -> String?)?
    private var isPointerInside = false
    private var hasKeyboardFocus = false
    private var hasAccessibilityFocus = false
    private var isTakingPointerFocus = false
    private(set) var acceptsPointerHit = false

    init(code: @escaping () -> String?) {
        self.code = code
        super.init(frame: .zero)
        target = self
        action = #selector(copyCode(_:))
        image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")
        imagePosition = .imageOnly
        bezelStyle = .glass
        borderShape = .circle
        controlSize = .regular
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        focusRingType = .exterior
        setAccessibilityLabel("Copy code") // [VERIFY] The symbol copies the code body.
        setAccessibilityHelp("Copies this code block as plain text, without Markdown code fences.")
        toolTip = "Copy code without Markdown code fences."
        updateVisibility()
    }

    required init?(coder: NSCoder) { fatalError("Create code Copy controls with a source provider") }

    func updateHover(_ inside: Bool) {
        isPointerInside = inside
        updateVisibility()
    }

    @discardableResult
    func copy(to pasteboard: NSPasteboard) -> Bool {
        guard let source = code?() else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(source, forType: .string)
    }

    func invalidate() {
        code = nil
        target = nil
        action = nil
        isEnabled = false
        isPointerInside = false
        hasKeyboardFocus = false
        hasAccessibilityFocus = false
        updateVisibility()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            hasKeyboardFocus = !isTakingPointerFocus
            updateVisibility()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            hasKeyboardFocus = false
            updateVisibility()
        }
        return accepted
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        hasAccessibilityFocus = focused
        updateVisibility()
    }

    override func mouseDown(with event: NSEvent) {
        isTakingPointerFocus = true
        defer { isTakingPointerFocus = false }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        hasKeyboardFocus = true
        updateVisibility()
        super.keyDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsPointerHit ? super.hitTest(point) : nil
    }

    private func updateVisibility() {
        let shown = code != nil && (isPointerInside || hasKeyboardFocus || hasAccessibilityFocus)
        acceptsPointerHit = shown
        alphaValue = shown ? 1 : 0
    }

    @objc private func copyCode(_ sender: Any?) { copy(to: .general) }
}
#endif
