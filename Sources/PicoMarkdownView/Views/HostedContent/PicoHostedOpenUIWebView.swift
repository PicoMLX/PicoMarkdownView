#if os(macOS)
import AppKit
@preconcurrency import WebKit

struct PicoHostedOpenUIScrollRegion: Sendable, Equatable {
    let rect: CGRect
    let canScrollUp: Bool
    let canScrollDown: Bool
}

/// Give scrollable web controls their gesture before forwarding to the transcript.
@MainActor
final class PicoHostedOpenUIWebView: WKWebView {
    private enum WheelAxis { case horizontal, vertical }
    private enum VerticalTarget { case web, transcript }
    private static var wheelMonitor: Any?
    private static var registeredViews = 0
    static var registeredScrollHostCount: Int { registeredViews }
    private var hasRegisteredMonitor = false
    private var forwardsScroll = true
    private var wheelAxis: WheelAxis?
    private var verticalTarget: VerticalTarget?
    private(set) var scrollRegions: [PicoHostedOpenUIScrollRegion] = []
    private var scrollRegionScale: CGFloat = 1

    func updateScrollRegions(_ regions: [PicoHostedOpenUIScrollRegion], pageZoom: CGFloat) {
        guard pageZoom.isFinite, pageZoom > 0 else {
            scrollRegions = []
            return
        }
        scrollRegions = regions
        scrollRegionScale = pageZoom
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, forwardsScroll, !hasRegisteredMonitor {
            hasRegisteredMonitor = true
            Self.registerMonitor()
        } else if window == nil {
            unregisterMonitor()
        }
    }

    isolated deinit { unregisterMonitor() }

    func stopForwardingScroll() {
        forwardsScroll = false
        wheelAxis = nil
        verticalTarget = nil
        scrollRegions = []
        unregisterMonitor()
    }

    private func unregisterMonitor() {
        guard hasRegisteredMonitor else { return }
        hasRegisteredMonitor = false
        wheelAxis = nil
        verticalTarget = nil
        Self.registeredViews -= 1
        if Self.registeredViews == 0, let monitor = Self.wheelMonitor {
            NSEvent.removeMonitor(monitor)
            Self.wheelMonitor = nil
        }
    }

    private static func registerMonitor() {
        registeredViews += 1
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let consumed = MainActor.assumeIsolated { routeWheel(event) }
            return consumed ? nil : event
        }
    }

    private static func routeWheel(_ event: NSEvent) -> Bool {
        guard let content = event.window?.contentView else { return false }
        let point = content.convert(event.locationInWindow, from: nil)
        var candidate = content.hitTest(content.convert(point, to: content.superview))
        while let view = candidate {
            if let webView = view as? PicoHostedOpenUIWebView,
               webView.forwardVerticalWheel(event) { return true }
            candidate = view.superview
        }
        return false
    }

    override func scrollWheel(with event: NSEvent) {
        if !forwardVerticalWheel(event) { super.scrollWheel(with: event) }
    }

    func forwardVerticalWheel(_ event: NSEvent) -> Bool {
        guard forwardsScroll, window === event.window else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.intersection(visibleRect).contains(point) else { return false }
        let phase = event.phase
        let momentum = event.momentumPhase
        let isPhased = !phase.isEmpty || !momentum.isEmpty
        if !isPhased || phase.contains(.began) || phase.contains(.mayBegin) {
            wheelAxis = nil
            verticalTarget = nil
        }
        defer {
            if !isPhased || phase.contains(.cancelled) || momentum.contains(.ended) || momentum.contains(.cancelled) {
                wheelAxis = nil
                verticalTarget = nil
            }
        }
        if event.modifierFlags.contains(.shift) { wheelAxis = .horizontal }
        if wheelAxis == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            wheelAxis = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? .vertical : .horizontal
        }
        // Keep the established axis through zero-delta endings and the handoff
        // from the physical gesture to momentum. A new gesture resets it.
        guard wheelAxis == .vertical else { return false }
        if verticalTarget == nil {
            let nativeY = isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
            let cssPoint = CGPoint(x: (point.x - bounds.minX) / scrollRegionScale,
                                   y: nativeY / scrollRegionScale)
            let canScroll = scrollRegions.contains { region in
                region.rect.contains(cssPoint) &&
                    (event.scrollingDeltaY > 0 ? region.canScrollUp : region.canScrollDown)
            }
            verticalTarget = canScroll ? .web : .transcript
        }
        guard verticalTarget == .transcript else { return false }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView {
                scroll.scrollWheel(with: event)
                return true
            }
            ancestor = view.superview
        }
        return false
    }
}
#endif
