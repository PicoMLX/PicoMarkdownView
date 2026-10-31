#if os(macOS)
import AppKit
import Observation

/// Source and interaction state survive attachment measurement and redraws.
@MainActor
@Observable
final class PicoHostedMediaModel {
    enum Fit: Equatable { case diagram, width }
    private enum Content { case mermaid, image }

    private let content: Content
    private(set) var altText = ""
    private(set) var title: String?

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

    @ObservationIgnored private(set) var document: PeleSVGDocument?
    @ObservationIgnored private var svg: String
    @ObservationIgnored private var image: NSImage?
    @ObservationIgnored private var viewport = CGSize(width: 1, height: 1)
    @ObservationIgnored var onPresentationChanged: (@MainActor () -> Void)?

    init(svg: String, source: String, language: String?, isClosed: Bool, maxWidth: CGFloat? = nil) {
        self.content = .mermaid
        self.svg = svg
        self.source = source
        self.language = language
        self.isClosed = isClosed
        self.maxWidth = Self.normalizedMaxWidth(maxWidth)
        parse(svg)
    }

    init(image: NSImage, size: CGSize, markdown: String, altText: String,
         title: String? = nil, maxWidth: CGFloat? = nil) {
        self.content = .image
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
        pan = clamped(pan)
        changed()
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

    var isImage: Bool { content == .image }
    var isRenderable: Bool { isImage ? image != nil : document != nil }

    var accessibilityLabel: String {
        guard isImage else { return "Mermaid diagram" }
        return !altText.isEmpty ? altText : title.flatMap { $0.isEmpty ? nil : $0 } ?? "Image"
    }

    var accessibilityHelp: String {
        guard isImage else { return "Diagram source: " + source }
        let caption = title.flatMap { $0.isEmpty ? nil : $0 }.map { $0 + ". " } ?? ""
        return caption + "Image Markdown: " + source
    }

    var copyLabel: String { isImage ? "Copy Image Markdown" : "Copy Mermaid" }
    var copyHelp: String {
        isImage ? "Copies the image's Markdown, including its source, alternative text and title."
            : "Copies the diagram's Mermaid source as Markdown, including its code fences."
    }
    var copyToolTip: String {
        isImage ? "Copy Image Markdown." : "Copy Mermaid Markdown, including code fences."
    }
    var zoomLabel: String { isImage ? "Image zoom" : "Diagram zoom" }
    var zoomHelp: String {
        "Zoom within the \(isImage ? "image" : "diagram") frame. Press Escape to reset zoom and return to the text."
    }

    /// Draw directly from the source image or parsed vector document at the
    /// current zoom; attachment sizing never creates another bitmap.
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
            document.draw(in: context, strokesAsFills: true)
            context.restoreGState()
        }
    }

    func viewportWidth(availableWidth: CGFloat) -> CGFloat {
        let available = availableWidth.isFinite ? max(1, availableWidth) : 1
        let capped = min(available, maxWidth ?? available)
        return isImage ? min(capped, intrinsicSize.width) : capped
    }

    func viewportHeight(availableWidth: CGFloat) -> CGFloat {
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
        if isImage { return source }
        let info = language ?? "mermaid"
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
        guard let parsed = PeleSVGDocument(svg: svg) else { return }
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
// Mermaid uses the same navigation state and canvas as block images.
typealias PicoHostedMermaidModel = PicoHostedMediaModel
#endif
