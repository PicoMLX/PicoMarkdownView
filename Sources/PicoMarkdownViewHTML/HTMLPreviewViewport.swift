#if os(macOS)
import AppKit
import Foundation

/// Tracks the native clipping hierarchy without retaining the attachment,
/// its ancestors, or its window. Geometry notifications share one UI update.
@MainActor
final class HTMLPreviewViewport {
    private final class WeakView {
        weak var value: NSView?
        init(_ value: NSView) { self.value = value }
    }

    private weak var view: NSView?
    private weak var observedWindow: NSWindow?
    private var ancestors: [WeakView] = []
    private var observations: [NotificationCenter.ObservationToken] = []
    private var firstResponderObservation: NSKeyValueObservation?
    private let onChange: @MainActor () -> Void
    private var isObserving = false
    private(set) var pendingUpdate: Task<Void, Never>?

    init(view: NSView, onChange: @escaping @MainActor () -> Void) {
        self.view = view
        self.onChange = onChange
        refreshHierarchy()
    }

    isolated deinit {
        pendingUpdate?.cancel()
        firstResponderObservation?.invalidate()
        for token in observations { NotificationCenter.default.removeObserver(token) }
    }

    /// Call after window/superview changes. Unchanged identities retain their
    /// registrations; a stopped tracker can be restarted with this method.
    func refreshHierarchy() {
        guard let view else { stop(); return }
        var chain: [NSView] = []
        var ancestor: NSView? = view
        while let current = ancestor {
            chain.append(current)
            ancestor = current.superview
        }
        let sameHierarchy = isObserving && observedWindow === view.window
            && ancestors.count == chain.count
            && zip(ancestors, chain).allSatisfy { $0.0.value === $0.1 }
        if sameHierarchy { scheduleUpdate(); return }

        removeObservations()
        isObserving = true
        ancestors = chain.map(WeakView.init)
        observedWindow = view.window
        let center = NotificationCenter.default
        for ancestor in chain {
            // Leave these enabled: another observer may also depend on them.
            ancestor.postsBoundsChangedNotifications = true
            ancestor.postsFrameChangedNotifications = true
            observations.append(center.addObserver(of: ancestor, for: .boundsDidChange) { [weak self] _ in
                self?.scheduleUpdate()
            })
            observations.append(center.addObserver(of: ancestor, for: .frameDidChange) { [weak self] _ in
                self?.scheduleUpdate()
            })
        }
        if let window = view.window {
            firstResponderObservation = window.observe(\.firstResponder) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.scheduleUpdate() }
            }
            observations.append(center.addObserver(of: window, for: .didResize) { [weak self] _ in self?.scheduleUpdate() })
            observations.append(center.addObserver(of: window, for: .didMove) { [weak self] _ in self?.scheduleUpdate() })
            observations.append(center.addObserver(of: window, for: .didMiniaturize) { [weak self] _ in self?.scheduleUpdate() })
            observations.append(center.addObserver(of: window, for: .didDeminiaturize) { [weak self] _ in self?.scheduleUpdate() })
            observations.append(center.addObserver(of: window, for: .didChangeOcclusionState) { [weak self] _ in self?.scheduleUpdate() })
            observations.append(center.addObserver(of: window, for: .didBecomeKey) { [weak self] _ in self?.scheduleUpdate() })
            observations.append(center.addObserver(of: window, for: .didResignKey) { [weak self] _ in self?.scheduleUpdate() })
            observations.append(center.addObserver(of: window, for: .willClose) { [weak self] _ in self?.scheduleUpdate() })
        }
        scheduleUpdate()
    }

    func scheduleUpdate() {
        guard isObserving, pendingUpdate == nil, view != nil else { return }
        pendingUpdate = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.pendingUpdate = nil
            self.onChange()
        }
    }

    func stop() {
        isObserving = false
        pendingUpdate?.cancel()
        pendingUpdate = nil
        removeObservations()
        ancestors.removeAll()
        observedWindow = nil
    }

    /// Focus pinning protects known keyboard/own-app accessibility focus. It
    /// does not claim to identify VoiceOver's independent reading cursor.
    func isEligible(pinning pageHost: NSView?) -> Bool {
        guard isObserving, let view, let window = view.window,
              window.isVisible, !window.isMiniaturized, !view.isHiddenOrHasHiddenAncestor,
              // Hosted attachments start at a one-point unresolved width.
              // Wait for the text column before asking WebKit to lay out HTML.
              view.bounds.width > 1, view.bounds.height > 0 else { return false }
        let visible = view.bounds.intersection(view.visibleRect)
        if !visible.isNull && visible.width > 0 && visible.height > 0 { return true }
        return pageHost.map { host in
            host.window === window && host.isDescendant(of: view) && hasFocusedDescendant(host, in: window)
        } ?? false
    }

    private func removeObservations() {
        firstResponderObservation?.invalidate()
        firstResponderObservation = nil
        for token in observations { NotificationCenter.default.removeObserver(token) }
        observations.removeAll()
    }

    private func hasFocusedDescendant(_ host: NSView, in window: NSWindow) -> Bool {
        if let first = window.firstResponder as? NSView, first.isDescendant(of: host) { return true }
        // Query only this application's public accessibility hierarchy. No
        // system-wide AX inspection or accessibility-trust request is needed.
        var focused = NSApplication.shared.accessibilityApplicationFocusedUIElement()
        var visited = Set<ObjectIdentifier>()
        while let element = focused as? any NSAccessibilityProtocol, visited.count < 64 {
            guard visited.insert(ObjectIdentifier(element)).inserted else { break }
            if let view = element as? NSView, view.isDescendant(of: host) { return true }
            focused = element.accessibilityParent()
        }
        return false
    }
}
#endif
