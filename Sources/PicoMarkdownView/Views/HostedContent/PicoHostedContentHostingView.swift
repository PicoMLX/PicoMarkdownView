#if os(macOS)
import AppKit
import SwiftUI

@MainActor
protocol PicoHostedAttachmentHitTarget: AnyObject {
    func acceptsHostedAttachmentHit(at point: NSPoint) -> Bool
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

    init(rootView: PicoMeasuredHostedContent, interaction: PicoHostedAttachmentInteraction) {
        self.interaction = interaction
        super.init(rootView: rootView)
    }

    required init(rootView: PicoMeasuredHostedContent) {
        interaction = .interactive
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("Use init(rootView:interaction:)")
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
