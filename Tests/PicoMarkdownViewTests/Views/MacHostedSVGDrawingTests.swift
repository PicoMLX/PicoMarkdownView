#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PicoMarkdownView

@Suite("Hosted SVG drawing in a real window", .timeLimit(.minutes(1)))
@MainActor
struct MacHostedSVGDrawingTests {
    @Test("The example's list SVG paints its full centered circle and checkmark", arguments: [false, true])
    func listGraphicPixels(streamed: Bool) async throws {
        _ = NSApplication.shared
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MarkdownExample/MarkdownExample/markdown files/SVG.md")
        let document = try String(contentsOf: file, encoding: .utf8)
        let heading = try #require(document.range(of: "## A graphic as the first child of a list item"))
        let closing = try #require(document.range(of: "  ```", range: heading.upperBound..<document.endIndex))
        let sentinel = "List SVG drawing complete."
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        defer { continuation.finish() }
        let markdown: AnyView = streamed
            ? AnyView(PicoMarkdownView(stream: { stream }, theme: .default().withSVGRendering()))
            : AnyView(PicoMarkdownView(document + "\n\n" + sentinel + "\n", theme: .default().withSVGRendering()))
        let host = NSHostingView(rootView: ScrollView {
            markdown.frame(maxWidth: .infinity, alignment: .leading)
        }.environment(\.colorScheme, .light))
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        var originalAttachment: PicoHostedAttachment?
        var originalHost: NSView?
        var originalCanvas: PicoHostedVectorCanvasView?
        if streamed {
            continuation.yield(String(document[..<closing.lowerBound]))
            try await wait(window: window) { target(in: findTextView(in: host)?.textStorage) != nil }
            let (attachment, range) = try #require(target(in: findTextView(in: host)?.textStorage))
            originalAttachment = attachment
            let text = try #require(findTextView(in: host))
            scroll(to: range, in: text)
            try await wait(window: window) { attachment.hostingView?.superview != nil }
            #expect(attachment.measuredSize.height == 48)
            let loadingHost = try #require(attachment.hostingView)
            loadingHost.layoutSubtreeIfNeeded()
            let loadingCanvas = try #require(findCanvas(in: loadingHost),
                "The native canvas must stay mounted while the SVG loading row is visible")
            originalHost = loadingHost
            originalCanvas = loadingCanvas
            #expect(loadingCanvas.isHidden)
            #expect(loadingCanvas.model.isLoadingSVG)
            #expect(loadingCanvas.model.parseCount == 0)
            #expect(loadingCanvas.model.document == nil)
            let point = CGPoint(x: loadingCanvas.bounds.midX, y: loadingCanvas.bounds.midY)
            #expect(!loadingCanvas.acceptsHostedAttachmentHit(at: point))
            #expect(!loadingCanvas.acceptsHostedAttachmentMagnification(at: point))
            let controlsAreHidden = loadingCanvas.subviews.allSatisfy { $0.isHiddenOrHasHiddenAncestor }
            #expect(controlsAreHidden, "Native controls inherit the hidden canvas's input and accessibility exclusion")
            continuation.yield(String(document[closing.lowerBound...]) + "\n\n" + sentinel + "\n")
            continuation.finish()
        }
        try await wait(window: window) {
            findTextView(in: host)?.textStorage?.string.contains(sentinel) == true
        }
        let text = try #require(findTextView(in: host))
        let storage = try #require(text.textStorage)
        let (attachment, range) = try #require(target(in: storage))
        if let originalAttachment { #expect(attachment === originalAttachment) }
        scroll(to: range, in: text)
        try await wait(window: window) {
            guard let canvas = findCanvas(in: attachment.hostingView) else { return false }
            return canvas.window === window && canvas.model.isRenderable && canvas.bounds.width > 100
                && attachment.measuredSize.height >= 140
                && abs((attachment.hostingView?.bounds.height ?? 0) - canvas.bounds.height) < 1
        }
        let canvas = try #require(findCanvas(in: attachment.hostingView))
        let nativeHost = try #require(attachment.hostingView)
        if let originalHost { #expect(nativeHost === originalHost) }
        if let originalCanvas { #expect(canvas === originalCanvas) }
        #expect(!canvas.isHidden)
        #expect(!canvas.model.isLoadingSVG)
        #expect(canvas.model.parseCount == 1)
        #expect(canvas.acceptsHostedAttachmentMagnification(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)))
        let geometry = "attachment=\(attachment.measuredSize), host.frame=\(nativeHost.frame), host.bounds=\(nativeHost.bounds), canvas.frame=\(canvas.frame), canvas.bounds=\(canvas.bounds), intrinsic=\(canvas.model.intrinsicSize), zoom=\(canvas.model.zoom), pan=\(canvas.model.pan)"
        #expect(canvas.model.intrinsicSize == CGSize(width: 320, height: 120))
        #expect(canvas.model.zoom == 1)
        #expect(canvas.model.pan == .zero)
        #expect(attachment.measuredSize.height <= 360, "\(geometry)")
        #expect(canvas.bounds.height <= 360, "\(geometry)")
        #expect(abs(canvas.bounds.width - canvas.frame.width) < 1, "\(geometry)")
        #expect(abs(canvas.bounds.height - canvas.frame.height) < 1, "\(geometry)")
        #expect(abs(nativeHost.bounds.height - canvas.bounds.height) < 1, "\(geometry)")
        let expectedHeight = ceil(min(360, max(140, attachment.context.availableWidth * 120 / 320)))
        #expect(abs(attachment.measuredSize.height - expectedHeight) < 1, "\(geometry)")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        text.setSelectedRange(NSRange(location: 0, length: storage.length))
        #expect(text.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string)?.contains("viewBox=\"0 0 320 120\"") == true)
        #expect(pasteboard.string(forType: .string)?.contains("<circle cx=\"160\" cy=\"60\" r=\"48\"") == true)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        window.displayIfNeeded()

        let bitmap = try paintedStrips(in: canvas)
        let scale = min(canvas.bounds.width / 320, canvas.bounds.height / 120)
        let offset = CGPoint(x: (canvas.bounds.width - 320 * scale) / 2,
                             y: (canvas.bounds.height - 120 * scale) / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: offset.x + x * scale, y: offset.y + y * scale)
        }
        func color(at point: CGPoint) throws -> NSColor {
            let x = min(bitmap.pixelsWide - 1, max(0, Int(point.x * CGFloat(bitmap.pixelsWide) / canvas.bounds.width)))
            let y = min(bitmap.pixelsHigh - 1, max(0, Int(point.y * CGFloat(bitmap.pixelsHigh) / canvas.bounds.height)))
            return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }
        let green = try color(at: point(160, 30))
        #expect(green.greenComponent > 0.5 && green.greenComponent > green.redComponent + 0.2
                && green.greenComponent > green.blueComponent + 0.2, "The circle's upper interior is green: \(geometry)")
        let white = try color(at: point(153, 78))
        #expect(white.redComponent > 0.8 && white.greenComponent > 0.8 && white.blueComponent > 0.8,
                "The checkmark joint stays at its SVG coordinates: \(geometry)")
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.8,
                      color.greenComponent > 0.5, color.greenComponent > color.redComponent + 0.2,
                      color.greenComponent > color.blueComponent + 0.2 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        try #require(maxX >= minX && maxY >= minY, "The hosted view paints green SVG pixels: \(geometry)")
        let px = CGFloat(bitmap.pixelsWide) / canvas.bounds.width
        let py = CGFloat(bitmap.pixelsHigh) / canvas.bounds.height
        let expectedMin = point(112, 12), expectedMax = point(208, 108)
        #expect(abs(CGFloat(minX) / px - expectedMin.x) < 3, "Circle left edge: \(geometry)")
        #expect(abs(CGFloat(maxX + 1) / px - expectedMax.x) < 3, "Circle right edge: \(geometry)")
        #expect(abs(CGFloat(minY) / py - expectedMin.y) < 3, "Circle top edge: \(geometry)")
        #expect(abs(CGFloat(maxY + 1) / py - expectedMax.y) < 3, "Circle bottom edge: \(geometry)")
    }

    /// AppKit may first expose a scrolling attachment in several dirty strips.
    /// A full-bounds bitmap redraw can hide a wrong per-strip drawing origin.
    private func paintedStrips(in canvas: NSView) throws -> NSBitmapImageRep {
        let template = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        let result = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: template.pixelsWide, pixelsHigh: template.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let scale = CGFloat(result.pixelsHigh) / canvas.bounds.height
        let boundaries: [CGFloat] = [0, min(99.5, canvas.bounds.height), min(110, canvas.bounds.height),
                                     min(189, canvas.bounds.height), canvas.bounds.height]
        for (lower, upper) in zip(boundaries, boundaries.dropFirst()) where upper > lower {
            let rect = CGRect(x: canvas.bounds.minX, y: canvas.bounds.minY + lower,
                              width: canvas.bounds.width, height: upper - lower)
            let strip = try #require(canvas.bitmapImageRepForCachingDisplay(in: rect))
            canvas.cacheDisplay(in: rect, to: strip)
            let startY = Int((lower * scale).rounded())
            for y in 0..<min(strip.pixelsHigh, result.pixelsHigh - startY) {
                for x in 0..<min(strip.pixelsWide, result.pixelsWide) {
                    if let color = strip.colorAt(x: x, y: y) {
                        result.setColor(color, atX: x, y: startY + y)
                    }
                }
            }
        }
        return result
    }

    private func wait(window: NSWindow, until condition: () -> Bool) async throws {
        while !condition() {
            window.contentView?.layoutSubtreeIfNeeded()
            if let host = window.contentView, let view = findTextView(in: host),
               let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
                view.layoutSubtreeIfNeeded()
            }
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func scroll(to range: NSRange, in view: NSTextView) {
        guard let manager = view.textLayoutManager, let content = manager.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: range.location) else { return }
        manager.ensureLayout(for: content.documentRange)
        view.scrollRangeToVisible(range)
        guard let fragment = manager.textLayoutFragment(for: location) else { return }
        var ancestor: NSView? = view
        while let current = ancestor {
            if let clip = current as? NSClipView, let document = clip.documentView {
                let target = view.convert(fragment.layoutFragmentFrame, to: document)
                clip.scroll(to: CGPoint(x: clip.bounds.minX, y: max(0, target.minY - 100)))
                clip.enclosingScrollView?.reflectScrolledClipView(clip)
                break
            }
            ancestor = current.superview
        }
        manager.textViewportLayoutController.layoutViewport()
    }

    private func target(in storage: NSTextStorage?) -> (PicoHostedAttachment, NSRange)? {
        guard let storage else { return nil }
        var result: (PicoHostedAttachment, NSRange)?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let attachment = value as? PicoHostedAttachment,
                  attachment.markdownRepresentation().contains("A checkmark in a circle") else { return }
            result = (attachment, range)
            stop.pointee = true
        }
        return result
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { findTextView(in: $0) }.first
    }

    private func findCanvas(in view: NSView?) -> PicoHostedVectorCanvasView? {
        guard let view else { return nil }
        if let canvas = view as? PicoHostedVectorCanvasView { return canvas }
        return view.subviews.lazy.compactMap { findCanvas(in: $0) }.first
    }
}
#endif
