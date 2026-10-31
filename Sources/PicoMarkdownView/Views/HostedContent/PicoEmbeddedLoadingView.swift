#if os(macOS)
import SwiftUI

/// Shared loading chrome keeps a stable place in the native text layout while
/// source arrives or an embedded preview prepares its first presentation.
@MainActor
package struct PicoEmbeddedLoadingView: View {
    private let state: PicoEmbeddedLoadingState
    private let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    package init(state: PicoEmbeddedLoadingState, isSelected: Bool) {
        self.state = state
        self.isSelected = isSelected
    }

    package var body: some View {
        HStack(spacing: 8) {
            Group {
                if isVisible && state.activity == .receiving && !reduceMotion {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: statusSymbol)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)

            statusLabel
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: PicoEmbeddedLoadingState.height, alignment: .leading)
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHidden(!isVisible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isVisible)
    }

    private var isVisible: Bool { state.showsPlaceholder && state.isLoading }

    private var statusSymbol: String {
        switch state.activity {
        case .receiving: "hourglass"
        case .paused: "pause.circle"
        case .stopped: "doc.text"
        }
    }

    private var statusLabel: Text {
        switch state.activity {
        case .receiving:
            Text("Preparing preview…", tableName: "EmbeddedLoading", bundle: .module,
                 comment: "Status shown while source for an embedded preview is arriving or being prepared.")
        case .paused:
            Text("Preview paused", tableName: "EmbeddedLoading", bundle: .module,
                 comment: "Status shown while updates to an embedded preview are paused.")
        case .stopped:
            Text("Preview incomplete", tableName: "EmbeddedLoading", bundle: .module,
                 comment: "Status shown when an embedded preview stops before its source is complete.")
        }
    }
}
#endif
