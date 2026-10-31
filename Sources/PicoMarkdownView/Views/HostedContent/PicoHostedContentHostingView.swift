#if os(macOS)
import AppKit
import SwiftUI

@MainActor
protocol PicoHostedAttachmentHitTarget: AnyObject {
    func acceptsHostedAttachmentHit(at point: NSPoint) -> Bool
}

/// Magnification can reach selectable content without capturing clicks or
/// wheel scrolling that belong to the surrounding Markdown text view.
@MainActor
protocol PicoHostedAttachmentMagnificationTarget: AnyObject {
    func acceptsHostedAttachmentMagnification(at point: NSPoint) -> Bool
}

@MainActor
struct PicoMeasuredHostedContent: View {
    let context: PicoHostedAttachmentContext
    let content: @MainActor (PicoHostedAttachmentContext) -> AnyView
    let onHeight: @MainActor (CGFloat) -> Void

    var body: some View {
        content(context)
            .frame(width: context.availableWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
    }
}

@MainActor
final class PicoHostedContentHostingView: NSHostingView<PicoMeasuredHostedContent> {
    let interaction: PicoHostedAttachmentInteraction
    private let statusLabel: @MainActor () -> String?

    init(rootView: PicoMeasuredHostedContent, interaction: PicoHostedAttachmentInteraction,
         accessibilityStatus: @escaping @MainActor () -> String? = { nil }) {
        self.interaction = interaction
        self.statusLabel = accessibilityStatus
        super.init(rootView: rootView)
    }

    required init(rootView: PicoMeasuredHostedContent) {
        interaction = .interactive
        statusLabel = { nil }
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("Use init(rootView:interaction:)")
    }

    // NSHostingView can omit the SwiftUI status subtree inside a TextKit
    // attachment. Project its visible status onto the native host itself.
    override func isAccessibilityElement() -> Bool {
        statusLabel() != nil || super.isAccessibilityElement()
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        statusLabel() != nil ? .staticText : super.accessibilityRole()
    }

    override func accessibilityLabel() -> String? {
        statusLabel() ?? super.accessibilityLabel()
    }

    override func accessibilityChildren() -> [Any]? {
        statusLabel() != nil ? [] : super.accessibilityChildren()
    }

    /// Search only live, visible attachment views under the gesture point.
    /// A selectable host deliberately returns nil from ordinary hit testing.
    static func forwardMagnification(with event: NSEvent, in view: NSView) -> Bool {
        let point = view.convert(event.locationInWindow, from: nil)
        guard !view.isHidden, view.alphaValue > 0,
              view.bounds.intersection(view.visibleRect).contains(point) else { return false }
        if let host = view as? PicoHostedContentHostingView {
            return host.forwardMagnification(with: event)
        }
        for child in view.subviews.reversed() {
            if forwardMagnification(with: event, in: child) { return true }
        }
        return false
    }

    private func forwardMagnification(with event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        // Bypass this host's selection policy to locate an opt-in gesture
        // target. Leave the normal click/drag hit-test path unchanged.
        var candidate = super.hitTest(convert(point, to: superview))
        while let view = candidate, view !== self {
            if let target = view as? any PicoHostedAttachmentMagnificationTarget,
               target.acceptsHostedAttachmentMagnification(at: view.convert(point, from: self)) {
                view.magnify(with: event)
                return true
            }
            candidate = view.superview
        }
        return false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard interaction == .selectableBlock else { return hit }
        let localPoint = convert(point, from: superview)
        var candidate = hit
        while let view = candidate, view !== self {
            if let target = view as? any PicoHostedAttachmentHitTarget,
               target.acceptsHostedAttachmentHit(at: view.convert(localPoint, from: self)) {
                return view
            }
            candidate = view.superview
        }
        return nil
    }
}
#endif
