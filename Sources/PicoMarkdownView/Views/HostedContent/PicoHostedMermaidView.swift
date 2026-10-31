#if os(macOS)
import AppKit
import SwiftUI

@MainActor
struct PicoHostedMermaidView: View {
    let model: PicoHostedMermaidModel
    let context: PicoHostedAttachmentContext

    var body: some View {
        let width = model.viewportWidth(availableWidth: context.availableWidth)
        PicoHostedMermaidCanvas(model: model, isSelected: context.isSelected)
            .frame(width: width,
                   height: model.viewportHeight(availableWidth: width))
    }
}

@MainActor
private struct PicoHostedMermaidCanvas: NSViewRepresentable {
    let model: PicoHostedMermaidModel
    let isSelected: Bool
    func makeNSView(context: Context) -> PicoHostedMermaidCanvasView {
        PicoHostedMermaidCanvasView(model: model)
    }

    func updateNSView(_ view: PicoHostedMermaidCanvasView, context: Context) {
        view.isSelected = isSelected
        view.refreshPresentation()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PicoHostedMermaidCanvasView, context: Context) -> CGSize? {
        let width = model.viewportWidth(availableWidth: proposal.width ?? 1)
        return CGSize(width: width,
                      height: model.viewportHeight(availableWidth: width))
    }
}
#endif
