#if os(macOS) && canImport(JavaScriptCore)
import AppKit
import SwiftUI
import Testing
@testable import PicoMarkdownView

/// Desktop windows share AppKit presentation; exercise one visible transition at a time.
@Suite("Hosted loading publishes ready charts without scrolling", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MacHostedLoadingPublicationTests {
    @Test("A visible loading row becomes a correctly sized painted chart through native events",
          arguments: [ChartShape.wide, .tall, .tallAtViewportEdge])
    private func readyChartAppearsWithoutViewportIntervention(shape: ChartShape) async throws {
        _ = NSApplication.shared
        let source = shape.source
        let contentSizes = ContentSizeObservations()
        let (stream, continuation) = AsyncStream<String>.makeStream()
        defer { continuation.finish() }
        let outer = NSHostingView(rootView: ScrollView {
            PicoMarkdownView(stream: { stream }, remoteImagesEnabled: false)
                .textSelection(.enabled)
                .onContentSize { contentSizes.latest = $0 }
                .frame(width: 336)
                .padding(16)
        })
        outer.frame = NSRect(x: 0, y: 0, width: 368, height: 620)
        let window = NSWindow(contentRect: outer.frame,
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "No-scroll chart publication — " + shape.rawValue
        window.contentView = outer
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        window.orderFront(nil)
        defer { window.close() }
        // Bootstrap the CLI's initial SwiftUI hosting tree once. After the
        // loading row mounts, native events alone must publish its ready chart.
        outer.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        continuation.yield(shape.prefix + "Before chart.\n\n```vega-lite\n" + source)
        try await nativeEvents("initial loading marker") { firstAttachment(in: outer) != nil }
        let text = try #require(descendant(StreamingTextKit2View.self, in: outer))
        let attachment = try #require(firstAttachment(in: outer))
        // The CLI host needs one initial viewport bootstrap. This occurs only
        // while the fence is open; it is never repeated after closure.
        outer.layoutSubtreeIfNeeded()
        if let manager = text.textLayoutManager, let content = manager.textContentManager {
            manager.ensureLayout(for: content.documentRange)
            manager.textViewportLayoutController.layoutViewport()
        }
        text.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await nativeEvents("initial loading host mounting") { attachment.hostingView?.window === window }
        let host = try #require(attachment.hostingView)
        let canvas = try #require(descendant(PicoHostedMediaCanvasView.self, in: host))
        let model = canvas.model
        await model.waitForLoadingDelay()
        try await nativeEvents("visible loading geometry") { model.showsLoadingPlaceholder && host.bounds.width > 100 }
        #expect(model.isLoading && !model.isClosed && model.parseCount == 0)
        #expect(attachment.measuredSize.height == 48)
        #expect(canvas.isHidden)
        #expect(host.window === window && !host.isHiddenOrHasHiddenAncestor)
        #expect(host.visibleRect.width > 100 && host.visibleRect.height >= 47)
        #expect(try statusInk(in: host) >= 16, "The initial loader must actually paint before closure")
        if shape == .tallAtViewportEdge {
            let row = host.convert(host.bounds, to: outer)
            let top = outer.isFlipped ? row.minY : outer.bounds.maxY - row.maxY
            let height = min(620, max(120, ceil(top + row.height + 8)))
            window.setContentSize(CGSize(width: 368, height: height))
            try await nativeEvents("pre-close viewport edge") {
                abs(outer.bounds.height - height) < 1 && host.visibleRect.height >= 47
            }
            let placed = host.convert(host.bounds, to: outer)
            let gap = outer.isFlipped ? outer.bounds.maxY - placed.maxY : placed.minY - outer.bounds.minY
            #expect(gap >= 0 && gap <= 12, "The loading row must sit at the viewport bottom, gap=\(gap)")
        }
        #expect(abs(attachment.context.availableWidth - 336) < 1)
        try await nativeEvents("initial content-size notification") { contentSizes.latest != nil }
        let loadingHeight = try #require(contentSizes.latest?.height)

        // From this point onward there is no scroll, frame mutation, manual host
        // loading, layoutIfNeeded, ensureLayout or viewport-layout request.
        continuation.yield("```\n\nAfter chart.\n\n")
        continuation.finish()
        try await nativeEvents("completed chart model") { model.isClosed && model.isRenderable }
        #expect(model.parseCount == 1)
        #expect(model.source == source)
        #expect(!model.isLoading && !model.showsLoadingPlaceholder)
        let expectedHeight = model.viewportHeight(availableWidth: attachment.context.availableWidth)
        do {
            try await nativeEvents("ready native chart geometry") {
                !canvas.isHiddenOrHasHiddenAncestor && canvas.window === window
                    && abs(canvas.bounds.height - expectedHeight) < 1
                    && abs(host.bounds.height - expectedHeight) < 1
                    && abs(attachment.measuredSize.height - expectedHeight) < 1
            }
        } catch {
            Issue.record("Ready model did not publish native geometry: \(geometry(attachment, host, canvas))")
            throw error
        }
        let minimumGrowth = expectedHeight - PicoHostedMediaModel.loadingHeight - 1
        try await nativeEvents("ready content-size notification") {
            (contentSizes.latest?.height ?? 0) >= loadingHeight + minimumGrowth
        }
        #expect(firstAttachment(in: outer) === attachment)
        #expect(attachment.hostingView === host)
        #expect(descendant(PicoHostedMediaCanvasView.self, in: host) === canvas)
        #expect(canvas.model === model)
        #expect(expectedHeight >= 140)
        #expect(canvas.visibleRect.width > 0 && canvas.visibleRect.height > 0)
        #expect(abs(canvas.frame.width - canvas.bounds.width) < 1)
        #expect(abs(canvas.frame.height - canvas.bounds.height) < 1)
        #expect(abs(host.frame.height - host.bounds.height) < 1)

        // Capture only after geometry has published naturally. The distinctive
        // solid green mark also rejects a stretched generic attachment icon.
        let painted = try greenBounds(in: canvas, visibleOnly: shape == .tallAtViewportEdge)
        #expect(painted.width > 10 && painted.height > 10, "\(geometry(attachment, host, canvas))")
        if shape != .tallAtViewportEdge {
            #expect(abs(painted.width / painted.height - shape.aspectRatio) < 0.12,
                    "Chart paint must retain its source aspect: \(painted); \(geometry(attachment, host, canvas))")
        }
        #expect(text.string.contains("Before chart.") && text.string.contains("After chart."))
        #expect(!text.string.contains(source))
        #expect(attachment.markdownRepresentation() == "```vega-lite\n" + source + "```")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(model.copySource(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == source)
    }

    private func nativeEvents(_ phase: String, until condition: () -> Bool) async throws {
        do {
            while !condition() {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
        } catch {
            Issue.record("Native events did not complete \(phase)")
            throw error
        }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }

    private func firstAttachment(in outer: NSView) -> PicoHostedAttachment? {
        guard let text = descendant(StreamingTextKit2View.self, in: outer), let storage = text.textStorage else { return nil }
        var result: PicoHostedAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if let attachment = value as? PicoHostedAttachment { result = attachment; stop.pointee = true }
        }
        return result
    }

    private func bitmap(in view: NSView, rect: CGRect? = nil) throws -> NSBitmapImageRep {
        let capture = rect ?? view.bounds
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: capture))
        view.cacheDisplay(in: capture, to: bitmap)
        return bitmap
    }

    private func statusInk(in host: NSView) throws -> Int {
        let image = try bitmap(in: host)
        let sx = CGFloat(image.pixelsWide) / host.bounds.width
        let sy = CGFloat(image.pixelsHigh) / host.bounds.height
        var count = 0
        for y in Int(8 * sy)..<Int(40 * sy) {
            for x in Int(40 * sx)..<Int(min(240, host.bounds.width - 12) * sx) {
                let color = try #require(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let opaque = max(color.redComponent, color.greenComponent, color.blueComponent) * color.alphaComponent
                    + 1 - color.alphaComponent
                if opaque < 0.7 { count += 1 }
            }
        }
        return count
    }

    private func greenBounds(in canvas: NSView, visibleOnly: Bool) throws -> CGRect {
        let capture = visibleOnly ? canvas.visibleRect : canvas.bounds
        let image = try bitmap(in: canvas, rect: capture)
        var minX = image.pixelsWide, minY = image.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                let color = try #require(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if color.alphaComponent > 0.8 && color.greenComponent > 0.4
                    && color.greenComponent > color.redComponent + 0.2
                    && color.greenComponent > color.blueComponent + 0.15 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        try #require(maxX >= minX && maxY >= minY, "The native chart must paint its green source mark")
        let sx = CGFloat(image.pixelsWide) / capture.width
        let sy = CGFloat(image.pixelsHigh) / capture.height
        return CGRect(x: CGFloat(minX) / sx, y: CGFloat(minY) / sy,
                      width: CGFloat(maxX - minX + 1) / sx, height: CGFloat(maxY - minY + 1) / sy)
    }

    private func geometry(_ attachment: PicoHostedAttachment, _ host: NSView,
                          _ canvas: PicoHostedMediaCanvasView) -> String {
        "attachment=\(attachment.measuredSize), host.frame=\(host.frame), host.bounds=\(host.bounds), "
            + "canvas.frame=\(canvas.frame), canvas.bounds=\(canvas.bounds), hidden=\(canvas.isHidden), "
            + "intrinsic=\(canvas.model.intrinsicSize)"
    }
}

/// Receiving the real callback does not mutate SwiftUI state or cause auto-scroll.
@MainActor
private final class ContentSizeObservations {
    var latest: CGSize?
}

private enum ChartShape: String, Sendable {
    case wide, tall, tallAtViewportEdge
    var prefix: String { self == .tallAtViewportEdge ? String(repeating: "Prior native paragraph.\n\n", count: 8) : "" }
    var aspectRatio: CGFloat { self == .wide ? 300.0 / 80 : 90.0 / 300 }
    var source: String {
        let width = self == .wide ? 300 : 90
        let height = self == .wide ? 80 : 300
        return """
        {"width":\(width),"height":\(height),"padding":0,"data":{"values":[{"x":0,"x2":1,"y":0,"y2":1}]},
        "mark":{"type":"rect","color":"#16a34a"},"encoding":{
        "x":{"field":"x","type":"quantitative","scale":{"domain":[0,1]},"axis":null},"x2":{"field":"x2"},
        "y":{"field":"y","type":"quantitative","scale":{"domain":[0,1]},"axis":null},"y2":{"field":"y2"}}}
        """ + "\n"
    }
}
#endif
