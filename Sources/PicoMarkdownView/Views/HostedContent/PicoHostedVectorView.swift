#if os(macOS)
import AppKit
import SwiftUI

@MainActor
struct PicoHostedVectorView: View {
    let model: PicoHostedVectorModel
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
            .frame(width: width, height: PicoHostedVectorModel.loadingHeight)
        } else {
            PicoHostedVectorCanvas(model: model, isSelected: context.isSelected)
                .frame(width: width,
                       height: model.viewportHeight(availableWidth: width))
        }
    }
}

@MainActor
private struct PicoHostedVectorCanvas: NSViewRepresentable {
    let model: PicoHostedVectorModel
    let isSelected: Bool
    func makeNSView(context: Context) -> PicoHostedVectorCanvasView {
        PicoHostedVectorCanvasView(model: model)
    }

    func updateNSView(_ view: PicoHostedVectorCanvasView, context: Context) {
        view.isSelected = isSelected
        view.refreshPresentation()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PicoHostedVectorCanvasView, context: Context) -> CGSize? {
        let width = model.viewportWidth(availableWidth: proposal.width ?? 1)
        return CGSize(width: width,
                      height: model.viewportHeight(availableWidth: width))
    }
}
#endif
