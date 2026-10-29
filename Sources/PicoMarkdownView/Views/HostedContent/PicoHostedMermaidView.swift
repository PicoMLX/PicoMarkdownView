#if os(macOS)
import AppKit
import SwiftUI

@MainActor
struct PicoHostedMermaidView: View {
    let model: PicoHostedMermaidModel
    let context: PicoHostedAttachmentContext

    var body: some View {
        PicoHostedMermaidCanvas(model: model, isSelected: context.isSelected)
            .frame(width: context.availableWidth,
                   height: model.viewportHeight(availableWidth: context.availableWidth) + PicoHostedMermaidCanvasView.toolbarHeight)
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
}
#endif
