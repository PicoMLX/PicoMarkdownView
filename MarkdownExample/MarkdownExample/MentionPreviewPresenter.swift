import SwiftUI
import PicoMarkdownView

/// Owns the transient UI so hover changes do not rebuild the streaming input.
@MainActor
struct MentionPreviewPresenter: ViewModifier {
    let inputID: UUID
    let onTagTap: (TagReference) -> Void
    let onTagHover: (String?) -> Void

    @State private var profile: ExampleMentionProfile?
    @State private var anchorRect: CGRect?
    @State private var hoveredProfileID: String?
    @State private var hoveredRect: CGRect?
    @State private var isPopoverPresented = false
    @State private var isHoveringPreview = false
    @State private var isPinned = false
    @State private var pendingHover: Task<Void, Never>?
    @State private var selectedProfile: ExampleMentionProfile?

    func body(content: Content) -> some View {
        content
            .onTagTap(handleTap)
            .onTagHover(handleHover)
            .popover(isPresented: $isPopoverPresented,
                     attachmentAnchor: .rect(anchorRect.map { .rect($0) } ?? .bounds),
                     arrowEdge: .top) {
                if let profile {
                    MentionProfilePreview(profile: profile, dismiss: dismiss)
#if os(macOS)
                        .onHover(perform: handlePreviewHover)
#endif
                }
            }
            .sheet(item: $selectedProfile) { profile in
                MentionProfilePreview(profile: profile, dismiss: dismiss)
                    .padding()
            }
            .onGeometryChange(for: CGRect.self) { geometry in
                let frame = geometry.frame(in: .global)
                // Streaming can add height without moving the hovered text.
                return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 0)
            } action: { _, _ in
                dismissHoverPreview()
            }
            .onChange(of: isPopoverPresented) { _, presented in
                if !presented {
                    pendingHover?.cancel()
                    isPinned = false
                    isHoveringPreview = false
                }
            }
            .onChange(of: inputID) { _, _ in dismiss() }
            .onDisappear(perform: dismiss)
    }

    private func handleHover(_ tag: TagReference?, _ rect: CGRect?) {
        onTagHover(tag.map { tag in
            let displayTag = "\(tag.prefix)\(tag.identifier)"
            return String(localized: "Tag: \(displayTag)")
        })
        guard let tag, let next = ExampleMentionProfile.profile(for: tag),
              let rect, !rect.isEmpty, !rect.isInfinite, !rect.isNull else {
            hoveredProfileID = nil
            hoveredRect = nil
            scheduleDismissal()
            return
        }
        hoveredProfileID = next.id
        hoveredRect = rect
        pendingHover?.cancel()
        guard selectedProfile == nil, !isPinned else { return }
        if isPopoverPresented, profile?.id == next.id {
            anchorRect = rect
            return
        }
        pendingHover = Task {
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard !Task.isCancelled, hoveredProfileID == next.id else { return }
            profile = next
            anchorRect = rect
            isPopoverPresented = true
        }
    }

    private func handleTap(_ tag: TagReference) {
        onTagTap(tag)
        guard let next = ExampleMentionProfile.profile(for: tag) else { return }
        pendingHover?.cancel()
        if hoveredProfileID == next.id, let rect = hoveredRect {
            profile = next
            anchorRect = rect
            isPinned = true
            isPopoverPresented = true
        } else {
            dismissHoverPreview()
            selectedProfile = next
        }
    }

    private func handlePreviewHover(_ hovering: Bool) {
        isHoveringPreview = hovering
        if hovering { pendingHover?.cancel() }
        else { scheduleDismissal() }
    }

    private func scheduleDismissal() {
        pendingHover?.cancel()
        guard !isPinned, !isHoveringPreview else { return }
        pendingHover = Task {
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard !Task.isCancelled, hoveredProfileID == nil, !isHoveringPreview, !isPinned else { return }
            isPopoverPresented = false
        }
    }

    private func dismissHoverPreview() {
        pendingHover?.cancel()
        isPopoverPresented = false
        isHoveringPreview = false
        isPinned = false
        hoveredProfileID = nil
        hoveredRect = nil
        anchorRect = nil
    }

    private func dismiss() {
        dismissHoverPreview()
        selectedProfile = nil
    }
}
