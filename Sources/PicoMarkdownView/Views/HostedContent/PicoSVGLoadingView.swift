#if os(macOS)
import SwiftUI

/// Loading chrome is independent of the raw source and its append frequency.
/// This is content, so it uses a quiet fill rather than control-layer glass.
@MainActor
struct PicoSVGLoadingView: View {
    let isVisible: Bool
    let activity: PicoHostedVectorModel.LoadingActivity
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 8) {
            if activity == .receiving && !reduceMotion {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: activity == .paused ? "pause.circle" : "photo")
                    .accessibilityHidden(true)
            }
            PicoSVGLoadingLabel(activity: activity)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: PicoHostedVectorModel.svgLoadingHeight, alignment: .leading)
        .background(Color.primary.opacity(contrast == .increased ? 0.08 : 0.035),
                    in: .rect(cornerRadius: 8))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.12))
                    .accessibilityHidden(true)
            }
        }
        .opacity(isVisible ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityHidden(!isVisible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isVisible)
    }
}

@MainActor
private struct PicoSVGLoadingLabel: View {
    let activity: PicoHostedVectorModel.LoadingActivity

    var body: some View {
        switch activity {
        case .receiving:
            Text("Preparing graphic…", tableName: "SVGLoading", bundle: .module,
                 comment: "Status shown while an SVG graphic's source is still arriving.")
        case .paused:
            Text("Graphic paused", tableName: "SVGLoading", bundle: .module,
                 comment: "Status shown when displaying new SVG source is paused.")
        case .stopped:
            Text("Graphic incomplete", tableName: "SVGLoading", bundle: .module,
                 comment: "Status shown when an SVG stream stops before its graphic is complete.")
        }
    }
}
#endif
