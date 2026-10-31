#if os(macOS)
import AppKit
import Observation

/// Source and interaction state survive attachment measurement and redraws.
@MainActor
@Observable
final class PicoHostedVectorModel {
    enum Fit: Equatable { case diagram, width }
    enum Kind {
        case mermaid, svg

        var defaultLanguage: String { self == .mermaid ? "mermaid" : "svg" }
        var accessibilityLabel: String { self == .mermaid ? "Mermaid diagram" : "SVG graphic" }
        var copyTitle: String { self == .mermaid ? "Copy Mermaid" : "Copy SVG" }
        var copyHelp: String {
            self == .mermaid
                ? "Copies the diagram's Mermaid source as Markdown, including its code fences."
                : "Copies the graphic's SVG source as Markdown, including its code fences."
        }
        var copyToolTip: String {
            self == .mermaid ? "Copy Mermaid Markdown, including code fences." : "Copy SVG Markdown, including code fences."
        }
    }

    let kind: Kind

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

    @ObservationIgnored private(set) var document: PicoHostedVectorDocument?
    @ObservationIgnored private var svg: String
    @ObservationIgnored private var viewport = CGSize(width: 1, height: 1)
    @ObservationIgnored var onPresentationChanged: (@MainActor () -> Void)?

    init(svg: String, source: String, language: String?, isClosed: Bool, maxWidth: CGFloat? = nil, kind: Kind = .mermaid) {
        self.kind = kind
        self.svg = svg
        self.source = source
        self.language = language
        self.isClosed = isClosed
        self.maxWidth = Self.normalizedMaxWidth(maxWidth)
        parse(svg)
    }

    func update(svg: String, source: String, language: String?, isClosed: Bool, maxWidth: CGFloat? = nil) {
        let maxWidth = Self.normalizedMaxWidth(maxWidth)
        guard self.svg != svg || self.source != source || self.language != language || self.isClosed != isClosed
                || self.maxWidth != maxWidth else { return }
        if self.svg != svg {
            self.svg = svg
            parse(svg)
        }
        self.source = source
        self.language = language
        self.isClosed = isClosed
        self.maxWidth = maxWidth
        pan = clamped(pan)
        changed()
    }

    var isRenderable: Bool { document != nil }

    func viewportWidth(availableWidth: CGFloat) -> CGFloat {
        let available = availableWidth.isFinite ? max(1, availableWidth) : 1
        return min(available, maxWidth ?? available)
    }

    func viewportHeight(availableWidth: CGFloat) -> CGFloat {
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

    private static func normalizedMaxWidth(_ width: CGFloat?) -> CGFloat? {
        width.flatMap { $0.isFinite && $0 > 0 ? max(1, $0) : nil }
    }

    private func changed() {
        presentationRevision &+= 1
        onPresentationChanged?()
    }
}
/// Both sources use the same viewport and controls; their decoders stay separate.
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
