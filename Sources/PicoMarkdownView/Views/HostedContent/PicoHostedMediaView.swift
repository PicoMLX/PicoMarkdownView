#if os(macOS)
import AppKit
import SwiftUI

@MainActor
struct PicoHostedMediaView: View {
    let model: PicoHostedMediaModel
    let context: PicoHostedAttachmentContext

    var body: some View {
        let width = model.viewportWidth(availableWidth: context.availableWidth)
        if model.isLoading {
            Group {
                if model.showsLoadingPlaceholder {
                    PicoHostedLoadingView(activity: model.loadingActivity,
                                          isSelected: context.isSelected) {
                        Text(model.loadingAccessibilityLabel ?? "")
                    }
                } else {
                    Color.clear.accessibilityHidden(true)
                }
            }
            .frame(width: width, height: PicoHostedMediaModel.loadingHeight)
        } else {
            PicoHostedMediaCanvas(model: model, isSelected: context.isSelected)
                .frame(width: width,
                       height: model.viewportHeight(availableWidth: width))
        }
    }
}

@MainActor
private struct PicoHostedMediaCanvas: NSViewRepresentable {
    let model: PicoHostedMediaModel
    let isSelected: Bool
    func makeNSView(context: Context) -> PicoHostedMediaCanvasView {
        PicoHostedMediaCanvasView(model: model)
    }

    func updateNSView(_ view: PicoHostedMediaCanvasView, context: Context) {
        view.isSelected = isSelected
        view.refreshPresentation()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PicoHostedMediaCanvasView, context: Context) -> CGSize? {
        let width = model.viewportWidth(availableWidth: proposal.width ?? 1)
        return CGSize(width: width,
                      height: model.viewportHeight(availableWidth: width))
    }
}
typealias PicoHostedVectorView = PicoHostedMediaView
typealias PicoHostedMermaidView = PicoHostedMediaView
#endif
