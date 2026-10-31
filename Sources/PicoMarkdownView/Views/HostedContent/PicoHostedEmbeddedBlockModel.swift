#if os(macOS)
import SwiftUI
import Observation

/// The attachment and pending deadline outlive individual source appends. Its
/// actual adapter factory still receives only the final immutable source.
@MainActor
@Observable
final class PicoHostedEmbeddedBlockModel {
    @ObservationIgnored private(set) var presentation: RenderedEmbeddedBlock
    let loadingState: PicoEmbeddedLoadingState?
    private(set) var content: AnyView?
    @ObservationIgnored private(set) var context: PicoEmbeddedBlockContext?
    @ObservationIgnored private(set) var didCallFactory = false
    @ObservationIgnored private var availableWidth: CGFloat = 1
    @ObservationIgnored private var isSelected = false

    init(presentation: RenderedEmbeddedBlock) {
        self.presentation = presentation
        loadingState = presentation.renderer.showsLoadingPlaceholder ? PicoEmbeddedLoadingState() : nil
        loadingState?.startLoading()
        update(presentation)
    }

    var acceptsPresentation: Bool { !presentation.isClosed || content != nil }

    func matches(_ candidate: RenderedEmbeddedBlock) -> Bool {
        presentation.renderer.identity == candidate.renderer.identity && presentation.kind == candidate.kind
            && (!didCallFactory || presentation.source == candidate.source)
    }

    func update(_ candidate: RenderedEmbeddedBlock) {
        presentation = candidate
        context?.update(bodyFontSize: candidate.bodyFontSize)
        guard candidate.isClosed else { return }
        // Stream completion does not stop a closed adapter's asynchronous
        // preparation. The adapter itself ends its shared loading state.
        loadingState?.setActivity(.receiving)
        guard !didCallFactory else { return }
        didCallFactory = true
        let context = PicoEmbeddedBlockContext(source: candidate.source, kind: candidate.kind,
                                              bodyFontSize: candidate.bodyFontSize, loadingState: loadingState)
        context.update(availableWidth: availableWidth, isSelected: isSelected)
        self.context = context
        content = candidate.renderer.makeView(context)
        if content == nil { loadingState?.finishLoading() }
    }

    func updateLayout(availableWidth: CGFloat, isSelected: Bool) {
        self.availableWidth = availableWidth
        self.isSelected = isSelected
        context?.update(availableWidth: availableWidth, isSelected: isSelected)
    }

    func setOpenActivity(_ activity: PicoEmbeddedLoadingState.Activity) {
        guard !presentation.isClosed else { return }
        loadingState?.setActivity(activity)
    }

    func markdownRepresentation() -> String { presentation.markdown }
}

@MainActor
struct PicoHostedEmbeddedBlockView: View {
    let model: PicoHostedEmbeddedBlockModel
    let context: PicoHostedAttachmentContext

    var body: some View {
        if let content = model.content {
            content
        } else if let loadingState = model.loadingState {
            PicoEmbeddedLoadingView(state: loadingState, isSelected: context.isSelected)
        }
    }
}
#endif
