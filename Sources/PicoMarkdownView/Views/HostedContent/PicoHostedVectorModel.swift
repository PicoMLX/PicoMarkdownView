#if os(macOS)
import AppKit
import Observation

/// Source and interaction state survive attachment measurement and redraws.
@MainActor
@Observable
final class PicoHostedVectorModel {
    enum Kind: Equatable {
        case mermaid, vegaLite

        var language: String { self == .mermaid ? "mermaid" : "vega-lite" }
        var formatName: String { self == .mermaid ? "Mermaid" : "Vega-Lite" }
        var label: String { self == .mermaid ? "Mermaid diagram" : "Vega-Lite chart" }
        var noun: String { self == .mermaid ? "Diagram" : "Chart" }
        var copyLabel: String { "Copy " + formatName }
    }
    enum Fit: Equatable { case diagram, width }
    enum LoadingActivity: Equatable { case receiving, paused, stopped }
    static let loadingDelay: Duration = .milliseconds(350)
    static let loadingHeight: CGFloat = 48

    private(set) var kind: Kind

    private(set) var source: String
    private(set) var language: String?
    private(set) var isClosed: Bool
    private(set) var intrinsicSize: CGSize = .zero
    private(set) var maxWidth: CGFloat?
    private(set) var zoom: CGFloat = 1
    private(set) var pan = CGPoint.zero
    private(set) var fit: Fit = .diagram
    private(set) var isExpanded = false
    private(set) var isNavigationActive = false
    private(set) var presentationRevision: UInt64 = 0
    private(set) var parseCount = 0
    private(set) var showsLoadingPlaceholder = false
    private(set) var loadingActivity: LoadingActivity = .receiving

    @ObservationIgnored private(set) var document: PeleSVGDocument?
    @ObservationIgnored private var svg: String
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var viewport = CGSize(width: 1, height: 1)
    @ObservationIgnored var onPresentationChanged: (@MainActor () -> Void)?

    init(svg: String, source: String, language: String?, isClosed: Bool, maxWidth: CGFloat? = nil,
         kind: Kind = .mermaid, loadingTiming: HostedLoadingTiming = .continuous) {
        self.kind = kind
        self.svg = svg
        self.source = source
        self.language = language
        self.isClosed = isClosed
        self.maxWidth = Self.normalizedMaxWidth(maxWidth)
        if isLoading {
            scheduleLoadingReveal(using: loadingTiming)
        } else {
            parse(svg)
        }
    }

    deinit { loadingTask?.cancel() }

    func update(svg: String, source: String, language: String?, isClosed: Bool, maxWidth: CGFloat? = nil, kind: Kind = .mermaid) {
        let maxWidth = Self.normalizedMaxWidth(maxWidth)
        guard self.svg != svg || self.source != source || self.language != language || self.isClosed != isClosed
                || self.maxWidth != maxWidth || self.kind != kind else { return }
        let shouldParse = kind == .vegaLite
            ? isClosed && (self.svg != svg || self.kind != kind || !self.isClosed)
            : self.svg != svg || self.kind != kind
        self.kind = kind
        self.svg = svg
        self.source = source
        self.language = language
        self.isClosed = isClosed
        self.maxWidth = maxWidth
        if shouldParse { parse(svg) }
        if !isLoading {
            loadingTask?.cancel()
            loadingTask = nil
            showsLoadingPlaceholder = false
        }
        pan = clamped(pan)
        changed()
    }

    var isRenderable: Bool { document != nil }
    var isLoading: Bool { kind == .vegaLite && !isClosed }

    /// The native hosting root exposes this status while SwiftUI supplies the chrome.
    var loadingAccessibilityLabel: String? {
        guard isLoading, showsLoadingPlaceholder else { return nil }
        switch loadingActivity {
        case .receiving:
            return String(localized: "Preparing chart…", table: "HostedLoading", bundle: .module,
                          comment: "Status while a chart's source is still arriving.")
        case .paused:
            return String(localized: "Chart paused", table: "HostedLoading", bundle: .module,
                          comment: "Status when displaying new chart source is paused.")
        case .stopped:
            return String(localized: "Chart incomplete", table: "HostedLoading", bundle: .module,
                          comment: "Status when a chart stream stops before completion.")
        }
    }

    func setLoadingActivity(_ activity: LoadingActivity) {
        guard isLoading, loadingActivity != activity else { return }
        loadingActivity = activity
        if activity == .stopped {
            loadingTask?.cancel()
            loadingTask = nil
            showsLoadingPlaceholder = true
        }
        changed()
    }

    /// Retired attachments must not reveal a delayed indicator or keep animating.
    func finishLoading() {
        guard kind == .vegaLite else { return }
        loadingTask?.cancel()
        loadingTask = nil
        let didChange = showsLoadingPlaceholder || loadingActivity != .stopped
        showsLoadingPlaceholder = false
        loadingActivity = .stopped
        if didChange { changed() }
    }

    func waitForLoadingDelay() async {
        await loadingTask?.value
    }

    private func scheduleLoadingReveal(using timing: HostedLoadingTiming) {
        let sleep = timing.sleep
        loadingTask = Task { [weak self] in
            do { try await sleep(Self.loadingDelay) }
            catch { return }
            guard !Task.isCancelled, let self, self.isLoading else { return }
            self.showsLoadingPlaceholder = true
            self.loadingTask = nil
            self.changed()
        }
    }

    func viewportWidth(availableWidth: CGFloat) -> CGFloat {
        let available = availableWidth.isFinite ? max(1, availableWidth) : 1
        return min(available, maxWidth ?? available)
    }

    func viewportHeight(availableWidth: CGFloat) -> CGFloat {
        if isLoading { return Self.loadingHeight }
        if isExpanded { return 600 }
        let width = viewportWidth(availableWidth: availableWidth)
        let height = intrinsicSize.height * width / max(1, intrinsicSize.width)
        return min(360, max(140, height))
    }

    func updateViewport(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        viewport = size
        let next = clamped(pan)
        if pan != next { pan = next }
    }

    func drawingRect(in size: CGSize) -> CGRect {
        let base = baseScale(in: size)
        let drawn = CGSize(width: intrinsicSize.width * base * zoom,
                           height: intrinsicSize.height * base * zoom)
        let offset = clamped(pan, in: size)
        return CGRect(x: (size.width - drawn.width) / 2 + offset.x,
                      y: (size.height - drawn.height) / 2 + offset.y,
                      width: drawn.width, height: drawn.height)
    }

    var capturesScroll: Bool {
        let rect = drawingRect(in: viewport)
        return isNavigationActive && (rect.width > viewport.width + 0.5 || rect.height > viewport.height + 0.5)
    }

    func activateNavigation() {
        guard !isNavigationActive else { return }
        isNavigationActive = true
        changed()
    }

    func zoom(by factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        let next = min(8, max(0.25, zoom * factor))
        guard next != zoom else { return }
        zoom = next
        isNavigationActive = true
        pan = clamped(pan)
        changed()
    }

    func fitDiagram() {
        fit = .diagram
        zoom = 1
        pan = .zero
        isNavigationActive = false
        changed()
    }

    func fitWidth() {
        fit = .width
        zoom = 1
        pan = .zero
        isNavigationActive = true
        changed()
    }

    func toggleExpanded() {
        isExpanded.toggle()
        changed()
    }

    @discardableResult
    func pan(by delta: CGPoint) -> Bool {
        guard delta.x.isFinite, delta.y.isFinite else { return false }
        let next = clamped(CGPoint(x: pan.x + delta.x, y: pan.y + delta.y))
        guard next != pan else { return false }
        pan = next
        changed()
        return true
    }

    func markdownRepresentation() -> String {
        let info = language ?? kind.language
        let marker: Character = info.contains("`") ? "~" : "`"
        var longest = 0
        var run = 0
        for character in source {
            if character == marker {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        let fence = String(repeating: String(marker), count: max(3, longest + 1))
        let body = source.hasSuffix("\n") || source.isEmpty ? source : source + "\n"
        return fence + info + "\n" + body + fence
    }

    @discardableResult
    func copyMarkdown(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(markdownRepresentation(), forType: .string)
    }

    @discardableResult
    func copySource(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(source, forType: .string)
    }

    private func parse(_ svg: String) {
        parseCount += 1
        guard let parsed = PeleSVGDocument(svg: svg, dialect: kind == .vegaLite ? .vega : .pele) else { return }
        document = parsed
        intrinsicSize = CGSize(width: parsed.width, height: parsed.height)
    }

    private func baseScale(in size: CGSize) -> CGFloat {
        guard intrinsicSize.width > 0, intrinsicSize.height > 0 else { return 1 }
        let widthScale = viewportWidth(availableWidth: size.width) / intrinsicSize.width
        if fit == .width { return widthScale }
        return min(widthScale, max(1, size.height) / intrinsicSize.height)
    }

    private func clamped(_ point: CGPoint, in size: CGSize? = nil) -> CGPoint {
        let size = size ?? viewport
        let scale = baseScale(in: size) * zoom
        let x = max(0, (intrinsicSize.width * scale - size.width) / 2)
        let y = max(0, (intrinsicSize.height * scale - size.height) / 2)
        return CGPoint(x: min(x, max(-x, point.x)), y: min(y, max(-y, point.y)))
    }

    private static func normalizedMaxWidth(_ width: CGFloat?) -> CGFloat? {
        width.flatMap { $0.isFinite && $0 > 0 ? max(1, $0) : nil }
    }

    private func changed() {
        presentationRevision &+= 1
        onPresentationChanged?()
    }
}
#endif
