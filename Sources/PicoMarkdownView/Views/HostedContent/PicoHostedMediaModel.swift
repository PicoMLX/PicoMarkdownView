#if os(macOS)
import AppKit
import Observation

/// Source and interaction state survive attachment measurement and redraws.
@MainActor
@Observable
final class PicoHostedMediaModel {
    enum Fit: Equatable { case diagram, width }
    enum LoadingActivity: Equatable { case receiving, paused, stopped }
    static let svgLoadingDelay: Duration = .milliseconds(350)
    static let svgLoadingHeight: CGFloat = 48
    enum Kind {
        case mermaid, svg, image

        var defaultLanguage: String {
            switch self { case .mermaid: "mermaid"; case .svg: "svg"; case .image: "" }
        }
        var accessibilityLabel: String {
            switch self { case .mermaid: "Mermaid diagram"; case .svg: "SVG graphic"; case .image: "Image" }
        }
        var copyTitle: String {
            switch self { case .mermaid: "Copy Mermaid"; case .svg: "Copy SVG"; case .image: "Copy Image Markdown" }
        }
        var copyHelp: String {
            switch self {
            case .mermaid: "Copies the diagram's Mermaid source as Markdown, including its code fences."
            case .svg: "Copies the graphic's SVG source as Markdown, including its code fences."
            case .image: "Copies the image's Markdown, including its source, alternative text and title."
            }
        }
        var copyToolTip: String {
            switch self {
            case .mermaid: "Copy Mermaid Markdown, including code fences."
            case .svg: "Copy SVG Markdown, including code fences."
            case .image: "Copy Image Markdown."
            }
        }
    }

    let kind: Kind
    private(set) var altText = ""
    private(set) var title: String?
    /// Optional activation belongs to the app; images remain static otherwise.
    var onImageTap: (@MainActor () -> Void)? {
        didSet { onPresentationChanged?() }
    }

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

    @ObservationIgnored private(set) var document: PicoHostedVectorDocument?
    @ObservationIgnored private var svg: String
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var image: NSImage?
    @ObservationIgnored private var viewport = CGSize(width: 1, height: 1)
    @ObservationIgnored var onPresentationChanged: (@MainActor () -> Void)?

    init(svg: String, source: String, language: String?, isClosed: Bool, maxWidth: CGFloat? = nil,
         kind: Kind = .mermaid, loadingTiming: SVGLoadingTiming = .continuous) {
        self.kind = kind
        self.svg = svg
        self.source = source
        self.language = language
        self.isClosed = isClosed
        self.maxWidth = Self.normalizedMaxWidth(maxWidth)
        if isLoadingSVG {
            scheduleLoadingReveal(using: loadingTiming)
        } else {
            parse(svg)
        }
    }

    deinit { loadingTask?.cancel() }

    init(image: NSImage, size: CGSize, markdown: String, altText: String,
         title: String? = nil, maxWidth: CGFloat? = nil) {
        self.kind = .image
        self.svg = ""
        self.image = image
        self.source = markdown
        self.language = nil
        self.isClosed = true
        self.altText = altText
        self.title = title
        self.intrinsicSize = Self.normalizedImageSize(size)
        self.maxWidth = Self.normalizedMaxWidth(maxWidth)
    }

    func update(image: NSImage, size: CGSize, markdown: String, altText: String,
                title: String? = nil, maxWidth: CGFloat? = nil) {
        let size = Self.normalizedImageSize(size)
        let maxWidth = Self.normalizedMaxWidth(maxWidth)
        guard self.image !== image || intrinsicSize != size || source != markdown
                || self.altText != altText || self.title != title || self.maxWidth != maxWidth else { return }
        self.image = image
        self.intrinsicSize = size
        self.source = markdown
        self.altText = altText
        self.title = title
        self.maxWidth = maxWidth
        changed()
    }

    func update(svg: String, source: String, language: String?, isClosed: Bool, maxWidth: CGFloat? = nil) {
        let maxWidth = Self.normalizedMaxWidth(maxWidth)
        guard self.svg != svg || self.source != source || self.language != language || self.isClosed != isClosed
                || self.maxWidth != maxWidth else { return }
        let shouldParse = kind == .svg
            ? isClosed && (self.svg != svg || !self.isClosed)
            : self.svg != svg
        self.svg = svg
        if shouldParse { parse(svg) }
        if kind == .svg, isClosed {
            loadingTask?.cancel()
            loadingTask = nil
            showsLoadingPlaceholder = false
        }
        self.source = source
        self.language = language
        self.isClosed = isClosed
        self.maxWidth = maxWidth
        pan = clamped(pan)
        changed()
    }

    var isImage: Bool { kind == .image }
    var isRenderable: Bool { isImage ? image != nil : document != nil }
    var isLoadingSVG: Bool { kind == .svg && !isClosed }

    func setLoadingActivity(_ activity: LoadingActivity) {
        guard isLoadingSVG, loadingActivity != activity else { return }
        loadingActivity = activity
        if activity == .stopped {
            loadingTask?.cancel()
            loadingTask = nil
            showsLoadingPlaceholder = true
        }
        changed()
    }

    /// Wait for the scheduled reveal, without depending on wall-clock polling.
    func waitForSVGLoadingDelay() async {
        await loadingTask?.value
    }

    private func scheduleLoadingReveal(using timing: SVGLoadingTiming) {
        let sleep = timing.sleep
        loadingTask = Task { [weak self] in
            do { try await sleep(Self.svgLoadingDelay) }
            catch { return }
            guard !Task.isCancelled, let self, self.isLoadingSVG else { return }
            self.showsLoadingPlaceholder = true
            self.loadingTask = nil
            self.changed()
        }
    }

    var canActivateImage: Bool { isImage && image != nil && onImageTap != nil }

    var accessibilityLabel: String {
        if isImage { return !altText.isEmpty ? altText : title.flatMap { $0.isEmpty ? nil : $0 } ?? "Image" }
        let description = document?.accessibilityDescription
        return description.map { kind.accessibilityLabel + ": " + $0 } ?? kind.accessibilityLabel
    }

    var imageAccessibilityHelp: String? {
        let caption = title.flatMap { $0.isEmpty ? nil : $0 }
        let activation = canActivateImage ? "Open image. Press Space or Return to activate." : nil
        let parts = [caption, activation].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    @discardableResult
    func activateImage() -> Bool {
        guard canActivateImage, let onImageTap else { return false }
        onImageTap()
        return true
    }

    /// Source images retain their own resolution; vector decoders stay separate.
    func draw(in context: CGContext, destination: CGRect) {
        guard destination.width > 0, destination.height > 0 else { return }
        if let image {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            context.interpolationQuality = .high
            image.draw(in: destination, from: .zero, operation: .sourceOver,
                       fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else if let document {
            context.saveGState()
            context.translateBy(x: destination.minX, y: destination.minY)
            context.scaleBy(x: destination.width / document.width, y: destination.height / document.height)
            document.draw(in: context)
            context.restoreGState()
        }
    }

    func viewportWidth(availableWidth: CGFloat) -> CGFloat {
        let available = availableWidth.isFinite ? max(1, availableWidth) : 1
        let capped = min(available, maxWidth ?? available)
        return isImage ? min(capped, intrinsicSize.width) : capped
    }

    func viewportHeight(availableWidth: CGFloat) -> CGFloat {
        if isLoadingSVG { return Self.svgLoadingHeight }
        if !isImage && isExpanded { return 600 }
        let width = viewportWidth(availableWidth: availableWidth)
        let height = intrinsicSize.height * width / max(1, intrinsicSize.width)
        return isImage ? max(1, height) : min(360, max(140, height))
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
        guard !isImage else { return false }
        let rect = drawingRect(in: viewport)
        return isNavigationActive && (rect.width > viewport.width + 0.5 || rect.height > viewport.height + 0.5)
    }

    func activateNavigation() {
        guard !isImage, !isNavigationActive else { return }
        isNavigationActive = true
        changed()
    }

    func zoom(by factor: CGFloat) {
        guard !isImage, factor.isFinite, factor > 0 else { return }
        let next = min(8, max(0.25, zoom * factor))
        guard next != zoom else { return }
        zoom = next
        isNavigationActive = true
        pan = clamped(pan)
        changed()
    }

    func fitDiagram() {
        guard !isImage else { return }
        fit = .diagram
        zoom = 1
        pan = .zero
        isNavigationActive = false
        changed()
    }

    func fitWidth() {
        guard !isImage else { return }
        fit = .width
        zoom = 1
        pan = .zero
        isNavigationActive = true
        changed()
    }

    func toggleExpanded() {
        guard !isImage else { return }
        isExpanded.toggle()
        changed()
    }

    @discardableResult
    func pan(by delta: CGPoint) -> Bool {
        guard !isImage, delta.x.isFinite, delta.y.isFinite else { return false }
        let next = clamped(CGPoint(x: pan.x + delta.x, y: pan.y + delta.y))
        guard next != pan else { return false }
        pan = next
        changed()
        return true
    }

    func markdownRepresentation() -> String {
        if isImage { return source }
        let info = language ?? kind.defaultLanguage
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
        switch kind {
        case .mermaid:
            // A streaming Mermaid preview keeps its last successful drawing.
            guard let parsed = PeleSVGDocument(svg: svg) else { return }
            document = .pele(parsed)
        case .svg:
            // User-supplied SVG must fall back to source if a later update is invalid.
            document = NativeSVGDocument(svg: svg).map(PicoHostedVectorDocument.svg)
        case .image: return
        }
        intrinsicSize = document.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
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

    private static func normalizedImageSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        return size
    }

    private static func normalizedMaxWidth(_ width: CGFloat?) -> CGFloat? {
        width.flatMap { $0.isFinite && $0 > 0 ? max(1, $0) : nil }
    }

    private func changed() {
        presentationRevision &+= 1
        onPresentationChanged?()
    }
}
typealias PicoHostedVectorModel = PicoHostedMediaModel
typealias PicoHostedMermaidModel = PicoHostedMediaModel

/// Vector sources share a viewport and controls; their decoders stay separate.
@MainActor
enum PicoHostedVectorDocument {
    case pele(PeleSVGDocument)
    case svg(NativeSVGDocument)

    var width: CGFloat {
        switch self { case .pele(let document): document.width; case .svg(let document): document.width }
    }
    var height: CGFloat {
        switch self { case .pele(let document): document.height; case .svg(let document): document.height }
    }
    var accessibilityDescription: String? {
        if case .svg(let document) = self { return document.accessibilityDescription }
        return nil
    }
    func draw(in context: CGContext) {
        switch self {
        case .pele(let document): document.draw(in: context, strokesAsFills: true)
        case .svg(let document): document.draw(in: context)
        }
    }
}
#endif
