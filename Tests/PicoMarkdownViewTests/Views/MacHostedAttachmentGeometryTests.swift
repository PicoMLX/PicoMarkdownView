#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PicoMarkdownView

@Suite("Hosted attachment geometry recovery")
@MainActor
struct MacHostedAttachmentGeometryTests {
    @Test("Size changes defer and coalesce native layout invalidation", .timeLimit(.minutes(1)))
    func sizeChangesDeferNativeInvalidation() async throws {
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed("| Header |\n| --- |\n| Cell |\n\n")
        _ = await pipeline.finish()
        let backend = TextKitStreamingBackend()
        let textView = StreamingTextKit2View(backend: backend)
        let (events, continuation) = AsyncStream<NSRange>.makeStream()
        defer { continuation.finish() }
        var changingSize = false
        var notifications = 0
        backend.onHostedContentSizeChanged = { range in
            #expect(!changingSize, "A size callback must not invalidate TextKit from inside its current layout pass")
            notifications += 1
            continuation.yield(range)
        }
        _ = backend.apply(blocks: await pipeline.blocksSnapshot(), selection: NSRange(location: 0, length: 0))
        var iterator = events.makeAsyncIterator()
        let originalRange = try #require(await iterator.next())
        let storage = try #require(textView.textStorage)
        let attachment = try #require(storage.attribute(.attachment, at: 0, effectiveRange: nil) as? PicoHostedAttachment)
        #expect(attachment.hostingView == nil)

        changingSize = true
        attachment.seedSizeBeforeViewCreation(CGSize(width: 240, height: 80))
        attachment.seedSizeBeforeViewCreation(CGSize(width: 240, height: 100))
        #expect(notifications == 1, "Repeated measurements must wait until the current native layout finishes")
        changingSize = false

        #expect(try #require(await iterator.next()) == originalRange)
        #expect(notifications == 2, "The latest size needs one block-local deferred invalidation")
        #expect(attachment.measuredSize == CGSize(width: 240, height: 100))
        #expect(attachment.hostingView == nil, "Measuring an offscreen attachment must not create its view")
    }

    @Test("An unloaded hosted attachment never paints AppKit's file fallback at wide or tall bounds",
          arguments: [CGSize(width: 400, height: 48), CGSize(width: 100, height: 300)])
    func transparentFallbackBeforeHosting(size: CGSize) throws {
        _ = NSApplication.shared
        let source = "```swift\nlet answer = 42\n```\n"
        let attachment = PicoHostedAttachment(markdown: { source }) { _ in Text("Hosted content") }
        attachment.seedSizeBeforeViewCreation(size)
        let view = NSTextView(usingTextLayoutManager: true)
        let storage = try #require(view.textStorage)
        storage.setAttributedString(NSAttributedString(attachment: attachment))
        let content = try #require(view.textLayoutManager?.textContentManager)
        let attributes = storage.attributes(at: 0, effectiveRange: nil)
        let legacyImage = try #require(attachment.image(forBounds: attachment.bounds,
            textContainer: view.textContainer, characterIndex: 0))
        let modernImage = try #require(attachment.image(for: attachment.bounds, attributes: attributes,
            location: content.documentRange.location, textContainer: view.textContainer))

        for (getter, image) in [("legacy", legacyImage), ("TextKit 2", modernImage)] {
            #expect(try paintsNoPixels(image), "The \(getter) fallback must stay transparent at \(size)")
        }
        #expect(attachment.hostingView == nil, "Fallback lookup must not create the hosted content")
        #expect(attachment.attachmentCell == nil)
        #expect(attachment.measuredSize == size)
        #expect(attachment.bounds.size == size)
        #expect(attachment.markdownRepresentation() == source)
    }

    @Test("Reusing a provider restores a host reset to zero without changing its cached measurement",
          .timeLimit(.minutes(1)), arguments: ["update", "load", "resetAfterLoad"])
    func restoresResetHost(lifecycle: String) async throws {
        _ = NSApplication.shared
        let source = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 120">
        <title>A checkmark in a circle</title>
        <circle cx="160" cy="60" r="48" fill="#22c55e"/>
        <path d="M136,61 L153,78 L185,43" fill="none" stroke="white" stroke-width="9"/>
        </svg>
        """
        let model = PicoHostedMediaModel(svg: source, source: source, language: "svg",
                                         isClosed: true, kind: .svg)
        let attachment = PicoHostedAttachment(interaction: .selectableBlock,
                                               markdown: { model.markdownRepresentation() }) { context in
            PicoHostedMediaView(model: model, context: context)
        }
        // This is the measured geometry of the actual failing TextKit provider:
        // its canvas stayed 876.5 × 329 while the containing host became 0 × 0.
        let size = CGSize(width: 876.5, height: 329)
        attachment.update(availableWidth: size.width, isSelected: false)
        attachment.seedSizeBeforeViewCreation(size)
        let host = attachment.loadHostedView()
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        try await settle(host)
        let canvas = try #require(findCanvas(in: host))
        let originalMarkdown = attachment.markdownRepresentation()
        #expect(model.parseCount == 1)
        #expect(attachment.measuredSize == size)
        #expect(host.frame.size == size)
        #expect(host.bounds.size == size)
        #expect(abs(canvas.bounds.width - size.width) <= 0.5)
        #expect(canvas.bounds.height == size.height)
        let origin = CGPoint(x: 12, y: 20)
        host.setFrameOrigin(origin)
        var sizeNotifications = 0
        var layoutNotifications = 0
        attachment.onSizeChanged = { _ in sizeNotifications += 1 }
        attachment.onLayoutInvalidated = { _ in layoutNotifications += 1 }

        // A reused provider can be reset either before loading, or just after
        // loadHostedView returns. The latter needs the coalesced refresh.
        if lifecycle == "resetAfterLoad" {
            #expect(attachment.loadHostedView() === host)
        }
        host.setFrameSize(.zero)
        host.layoutSubtreeIfNeeded()
        try #require(host.frame.size == .zero)
        try #require(host.bounds.size == .zero)
        #expect(attachment.measuredSize == size)
        if lifecycle == "update" {
            attachment.update(availableWidth: size.width, isSelected: false)
        } else if lifecycle == "load" {
            #expect(attachment.loadHostedView() === host)
        } else {
            // Wait for actual recovery, without assuming a fixed number of
            // scheduler turns or a short wall-clock deadline under CI load.
            while host.frame.size != size || host.bounds.size != size {
                try await Task.sleep(for: .milliseconds(1))
            }
        }

        #expect(host.frame.size == size,
                "The native host must recover even when its cached attachment measurement is unchanged")
        #expect(host.bounds.size == size)
        #expect(host.frame.origin == origin, "Recovery must preserve TextKit's attachment position")
        host.layoutSubtreeIfNeeded()
        let recoveredCanvas = try #require(findCanvas(in: host))
        #expect(recoveredCanvas === canvas)
        #expect(attachment.hostingView === host)
        #expect(attachment.measuredSize == size)
        #expect(attachment.bounds.size == size)
        let canvasRect = canvas.convert(canvas.bounds, to: host)
        #expect(abs(canvasRect.minX) < 0.5 && abs(canvasRect.minY) < 0.5,
                "The drawing must stay inside its host rather than being centered around a zero-size origin")
        #expect(model.parseCount == 1)
        #expect(model.intrinsicSize == CGSize(width: 320, height: 120))
        #expect(model.source == source)
        #expect(attachment.markdownRepresentation() == originalMarkdown)
        #expect(sizeNotifications == 0, "Repairing the host does not change the attachment's measured size")
        #expect(layoutNotifications == 0, "Matching measurements must not cause another TextKit invalidation")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(model.copyMarkdown(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == originalMarkdown)
        #expect(model.copySource(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == source)
    }

    private func paintsNoPixels(_ image: NSImage) throws -> Bool {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: 32, height: 32)
        context.cgContext.clear(bounds)
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        return (0..<32).allSatisfy { y in
            (0..<32).allSatisfy { x in bitmap.colorAt(x: x, y: y)?.alphaComponent == 0 }
        }
    }

    private func settle(_ host: NSView) async throws {
        // Drain the initial load's measurement before testing provider reuse.
        // Observe stable geometry across a run-loop turn rather than leaving
        // the fresh-load refresh queued to accidentally repair the late reset.
        var previousFrame = host.frame
        var previousFitting = host.fittingSize
        while true {
            try await Task.sleep(for: .milliseconds(1))
            host.layoutSubtreeIfNeeded()
            let frame = host.frame
            let fitting = host.fittingSize
            if frame == previousFrame && fitting == previousFitting { return }
            previousFrame = frame
            previousFitting = fitting
        }
    }

    private func findCanvas(in view: NSView) -> PicoHostedMediaCanvasView? {
        if let canvas = view as? PicoHostedMediaCanvasView { return canvas }
        return view.subviews.lazy.compactMap { findCanvas(in: $0) }.first
    }
}
#endif
