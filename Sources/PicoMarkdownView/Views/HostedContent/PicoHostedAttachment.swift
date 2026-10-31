#if os(macOS)
import AppKit
import SwiftUI

/// A stable TextKit 2 attachment that hosts arbitrary SwiftUI content.
///
/// Retain the attachment while its block exists and update the model captured
/// by `content`. Its view and model survive ordinary streaming updates. The
/// content must supply an intrinsic height for the proposed available width.
@MainActor
public final class PicoHostedAttachment: NSTextAttachment {
    private struct WeakAttachment { weak var value: PicoHostedAttachment? }
    private static var attachments: [UUID: WeakAttachment] = [:]

    nonisolated let hostedContentID = UUID()
    public let context = PicoHostedAttachmentContext()
    public let interaction: PicoHostedAttachmentInteraction
    public private(set) var measuredSize = CGSize(width: 1, height: 1)
    public var onSizeChanged: (@MainActor (CGSize) -> Void)?
    var onLayoutInvalidated: (@MainActor (CGSize) -> Void)?
    public var hostingView: NSView? { hostedView }

    private let markdown: @MainActor () -> String
    private let content: @MainActor (PicoHostedAttachmentContext) -> AnyView
    private var hostedView: PicoHostedContentHostingView?
    private var measurementScheduled = false

    public init<Content: View>(
        interaction: PicoHostedAttachmentInteraction = .interactive,
        markdown: @escaping @MainActor () -> String,
        @ViewBuilder content: @escaping @MainActor (PicoHostedAttachmentContext) -> Content
    ) {
        self.interaction = interaction
        self.markdown = markdown
        self.content = { AnyView(content($0)) }
        super.init(data: Data([1]), ofType: "com.picomarkdown.hosted-content")
        allowsTextAttachmentView = true
        bounds = CGRect(origin: .zero, size: measuredSize)
        Self.attachments[hostedContentID] = WeakAttachment(value: self)
    }

    public required init?(coder: NSCoder) {
        fatalError("Hosted attachments are created from their SwiftUI content factory")
    }

    isolated deinit {
        Self.attachments[hostedContentID] = nil
    }

    public func update(availableWidth: CGFloat, isSelected: Bool) {
        context.update(availableWidth: availableWidth, isSelected: isSelected)
        if abs(measuredSize.width - context.availableWidth) > 0.5 {
            setMeasuredSize(CGSize(width: context.availableWidth, height: measuredSize.height))
            invalidateSize()
        } else {
            reconcileHostedViewSize()
        }
    }

    /// Seed known geometry before TextKit inserts a lazy hosted attachment.
    /// An offscreen view need not be created just to reserve its block height.
    func seedSizeBeforeViewCreation(_ size: CGSize) {
        guard hostedView == nil else { return }
        setMeasuredSize(size)
    }

    public func markdownRepresentation() -> String { markdown() }

    /// Coalesces an intrinsic-size refresh after model or layout changes.
    public func invalidateSize() {
        guard hostedView != nil, !measurementScheduled else { return }
        measurementScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.measurementScheduled = false
            guard let hostedView = self.hostedView else { return }
            self.reconcileHostedViewSize()
            hostedView.layoutSubtreeIfNeeded()
            self.setMeasuredSize(CGSize(width: self.context.availableWidth,
                                        height: hostedView.fittingSize.height))
        }
    }

    nonisolated public override func viewProvider(
        for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        PicoHostedAttachmentViewProvider(textAttachment: self, parentView: parentView,
                                        textLayoutManager: textContainer?.textLayoutManager, location: location)
    }

    static func lookup(_ id: UUID) -> PicoHostedAttachment? { attachments[id]?.value }

    func loadHostedView() -> NSView {
        if let hostedView {
            reconcileHostedViewSize()
            invalidateSize()
            return hostedView
        }
        let root = PicoMeasuredHostedContent(context: context, content: content,
                                            onHeight: { [weak self] _ in self?.invalidateSize() })
        let view = PicoHostedContentHostingView(rootView: root, interaction: interaction)
        view.sizingOptions = [.intrinsicContentSize]
        view.frame = CGRect(origin: .zero, size: measuredSize)
        hostedView = view
        invalidateSize()
        return view
    }

    private func setMeasuredSize(_ proposed: CGSize) {
        guard proposed.width.isFinite, proposed.height.isFinite, proposed.height > 0 else { return }
        let size = CGSize(width: max(1, proposed.width), height: max(1, ceil(proposed.height)))
        let changed = abs(size.width - measuredSize.width) > 0.5 || abs(size.height - measuredSize.height) > 0.5
        if changed {
            measuredSize = size
            bounds.size = size
        }
        reconcileHostedViewSize()
        guard changed else { return }
        onLayoutInvalidated?(size)
        onSizeChanged?(size)
    }

    private func reconcileHostedViewSize() {
        guard let hostedView else { return }
        // TextKit can reset a provider's view to zero while the attachment's
        // cached measurement stays valid. Repair the actual view independently
        // of measurement changes, without issuing another layout notification.
        if abs(hostedView.frame.width - measuredSize.width) > 0.5
            || abs(hostedView.frame.height - measuredSize.height) > 0.5 {
            hostedView.setFrameSize(measuredSize)
        }
        if abs(hostedView.bounds.width - measuredSize.width) > 0.5
            || abs(hostedView.bounds.height - measuredSize.height) > 0.5 {
            hostedView.setBoundsSize(measuredSize)
        }
    }
}
#endif
