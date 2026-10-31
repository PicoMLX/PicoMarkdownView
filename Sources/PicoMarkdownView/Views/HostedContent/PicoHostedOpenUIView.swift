#if os(macOS)
import AppKit
import SwiftUI

@MainActor
struct PicoHostedOpenUIView: View {
    let model: PicoHostedOpenUIModel
    let context: PicoHostedAttachmentContext
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if model.isDisposed {
                Color.clear.frame(height: 1)
            } else if let error = model.error {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error).foregroundStyle(.secondary)
                    Button("Copy source") { model.copySource() }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                PicoHostedOpenUIBrowser(model: model)
                    .frame(height: model.measuredHeight)
                    .overlay {
                        if model.sizeMessageCount == 0 {
                            ProgressView("Loading OpenUI content…")
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .frame(width: max(1, context.availableWidth))
        .overlay {
            if context.isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: context.availableWidth, initial: true) { _, width in
            model.updateAvailableWidth(width)
        }
        .onChange(of: colorScheme, initial: true) { _, value in
            model.updateAppearance(dark: value == .dark)
        }
    }
}

@MainActor
private struct PicoHostedOpenUIBrowser: NSViewRepresentable {
    let model: PicoHostedOpenUIModel

    func makeNSView(context: Context) -> NSView { model.makeWebView() ?? NSView() }
    func updateNSView(_ view: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: max(1, proposal.width ?? 600), height: model.measuredHeight)
    }
}
#endif
