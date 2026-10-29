#if os(macOS)
import AppKit

@MainActor
final class PicoHostedAttachmentViewProvider: NSTextAttachmentViewProvider {
    nonisolated override init(textAttachment: NSTextAttachment, parentView: NSView?,
                             textLayoutManager: NSTextLayoutManager?, location: any NSTextLocation) {
        super.init(textAttachment: textAttachment, parentView: parentView,
                   textLayoutManager: textLayoutManager, location: location)
    }

    nonisolated override func loadView() {
        guard let id = (textAttachment as? PicoHostedAttachment)?.hostedContentID else { return }
        // AppKit invokes view creation on the UI actor. Only an immutable UUID
        // crosses this legacy, nonisolated Objective-C callback boundary.
        view = MainActor.assumeIsolated { () -> NSView? in
            PicoHostedAttachment.lookup(id)?.loadHostedView()
        }
    }
}
#endif
