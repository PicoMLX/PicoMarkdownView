#if os(macOS)
import SwiftUI

/// Compact loading chrome shared by hosted content without exposing its source.
@MainActor
struct PicoHostedLoadingView<Label: View>: View {
    let activity: PicoHostedVectorModel.LoadingActivity
    let isSelected: Bool
    @ViewBuilder let label: () -> Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 8) {
            if activity == .receiving && !reduceMotion {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: symbolName)
                    .accessibilityHidden(true)
            }
            label()
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PicoHostedVectorModel.loadingHeight)
        .background(Color.primary.opacity(contrast == .increased ? 0.08 : 0.035),
                    in: .rect(cornerRadius: 8))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.12))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbolName: String {
        switch activity {
        case .receiving: "clock"
        case .paused: "pause.circle"
        case .stopped: "exclamationmark.circle"
        }
    }
}
#endif
