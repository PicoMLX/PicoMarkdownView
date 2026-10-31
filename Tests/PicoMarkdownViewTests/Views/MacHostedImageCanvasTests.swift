#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS hosted image canvas")
@MainActor
struct MacHostedImageCanvasTests {
    private let markdown = "![Four colored corners](https://example.test/corners.png \"Corner sample\")"

    @Test("Images retain natural size and aspect ratio without diagram height limits")
    func naturalImageGeometry() throws {
        let (image, _) = try makeImage()
        let model = PicoHostedMediaModel(image: image, size: CGSize(width: 800, height: 1600),
                                         markdown: markdown, altText: "Four colored corners", maxWidth: 600)
        #expect(model.viewportWidth(availableWidth: 1000) == 600)
        #expect(model.viewportHeight(availableWidth: 1000) == 1200)
        #expect(model.viewportWidth(availableWidth: 200) == 200)
        #expect(model.viewportHeight(availableWidth: 200) == 400)
        let viewport = CGSize(width: 200, height: 400)
        model.updateViewport(viewport)
        #expect(model.drawingRect(in: viewport) == CGRect(origin: .zero, size: viewport))
        #expect(!model.capturesScroll)
        model.zoom(by: 2)
        #expect(model.drawingRect(in: viewport) == CGRect(x: -100, y: -200, width: 400, height: 800))
        #expect(model.viewportHeight(availableWidth: 200) == 400, "Zoom never expands the text attachment")
        #expect(model.capturesScroll)
        #expect(model.pan(by: CGPoint(x: 100_000, y: -100_000)))
        #expect(model.pan == CGPoint(x: 100, y: -200))
        model.fitDiagram()
        #expect(model.zoom == 1 && model.pan == .zero && !model.capturesScroll)
        #expect(model.parseCount == 0)
        #expect(model.document == nil)
        #expect(model.markdownRepresentation() == markdown)

        let natural = PicoHostedMediaModel(image: image, size: image.size, markdown: markdown, altText: "Corners")
        #expect(natural.viewportWidth(availableWidth: 1000) == 80, "Small images are not enlarged by default")
        #expect(natural.viewportHeight(availableWidth: 1000) == 40, "Images have no minimum diagram height")
    }

    @Test("Image drawing preserves top and bottom colors, transparency and the source image")
    func imageOrientationAndSourceIdentity() throws {
        _ = NSApplication.shared
        let (image, source) = try makeImage()
        let model = PicoHostedMediaModel(image: image, size: image.size, markdown: markdown, altText: "Corners")
        let canvas = PicoHostedMediaCanvasView(model: model)
        canvas.frame = CGRect(origin: .zero, size: image.size)
        canvas.layoutSubtreeIfNeeded()
        let native = NSImageView(frame: canvas.frame)
        native.image = image
        native.imageScaling = .scaleNone
        let rendered = try bitmap(of: canvas)
        let reference = try bitmap(of: native)
        // Compare with AppKit's image view so display color management does not
        // become a test assumption. The asymmetric corners detect either flip.
        for point in [CGPoint(x: 10, y: 10), CGPoint(x: 70, y: 10), CGPoint(x: 10, y: 30), CGPoint(x: 70, y: 30)] {
            try expectSameColor(at: point, in: rendered, as: reference, canvas: canvas)
        }
        let topLeft = try color(at: CGPoint(x: 10, y: 10), in: rendered, canvas: canvas)
        let bottomLeft = try color(at: CGPoint(x: 10, y: 30), in: rendered, canvas: canvas)
        #expect(topLeft.redComponent > topLeft.blueComponent + 0.5)
        #expect(bottomLeft.blueComponent > bottomLeft.redComponent + 0.5)
        #expect(try color(at: CGPoint(x: 40, y: 20), in: rendered, canvas: canvas).alphaComponent < 0.01,
                "The host adds no card or background behind transparent source pixels")

        let sourceBytes = try #require(source.bitmapData)
        for y in 0..<source.pixelsHigh {
            for x in 0..<source.pixelsWide {
                let offset = y * source.bytesPerRow + x * source.samplesPerPixel
                for (channel, byte) in [UInt8(255), 0, 255, 255].enumerated() { sourceBytes[offset + channel] = byte }
            }
        }
        image.recache()
        canvas.needsDisplay = true
        let changed = try bitmap(of: canvas)
        native.needsDisplay = true
        let updatedReference = try bitmap(of: native)
        try expectSameColor(at: CGPoint(x: 10, y: 10), in: changed, as: updatedReference, canvas: canvas)
        #expect(try color(at: CGPoint(x: 10, y: 10), in: changed, canvas: canvas).blueComponent > topLeft.blueComponent + 0.5)
        #expect(model.parseCount == 0, "The canvas redraws the original NSImage, not an SVG or resized snapshot")
    }

    @Test("Image controls and accessibility describe the image and copy its Markdown")
    func imageAccessibilityAndCopy() throws {
        _ = NSApplication.shared
        let (image, _) = try makeImage()
        let model = PicoHostedMediaModel(image: image, size: CGSize(width: 320, height: 160),
                                         markdown: markdown, altText: "Four colored corners", title: "Corner sample")
        let canvas = PicoHostedMediaCanvasView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 320, height: 160)
        canvas.layoutSubtreeIfNeeded()
        #expect(canvas.accessibilityLabel() == "Four colored corners")
        #expect(canvas.accessibilityHelp()?.contains("Corner sample") == true)
        #expect(Set(canvas.accessibilityCustomActions()?.map(\.name) ?? []) == Set(["Zoom in", "Zoom out", "Copy Image Markdown"]))
        let (zoom, copy) = try controls(in: canvas)
        #expect(zoom.segmentCount == 2 && zoom.trackingMode == .momentary)
        #expect(zoom.accessibilityLabel() == "Image zoom")
        #expect(zoom.accessibilityHelp()?.contains("image frame") == true)
        #expect(zoom.toolTip(forSegment: 0)?.contains("Zoom out") == true)
        #expect(zoom.toolTip(forSegment: 1)?.contains("Zoom in") == true)
        #expect(copy.accessibilityLabel() == "Copy Image Markdown")
        #expect(copy.toolTip?.contains("Image Markdown") == true)
        #expect(copy.accessibilityHelp()?.contains("alternative text") == true)
        #expect(copy.bezelStyle == .glass)
        let menu = try #require(canvas.menu(for: try mouse(.rightMouseDown)))
        #expect(menu.items.map(\.title) == ["Copy Image Markdown"])

        let pasteboard = NSPasteboard(name: .init("PicoImageCanvasTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(model.copyMarkdown(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == markdown)
        model.update(image: image, size: CGSize(width: 320, height: 160), markdown: markdown,
                     altText: "Updated description", title: "New caption")
        #expect(canvas.accessibilityLabel() == "Updated description")
        #expect(canvas.accessibilityHelp()?.contains("New caption") == true)
    }

    @Test("Small images keep available controls inside their natural frame", arguments: [
        CGSize(width: 24, height: 24), CGSize(width: 60, height: 60),
        CGSize(width: 100, height: 50), CGSize(width: 100, height: 100),
        CGSize(width: 200, height: 50)
    ])
    func compactControls(size: CGSize) throws {
        _ = NSApplication.shared
        let (image, _) = try makeImage()
        let model = PicoHostedMediaModel(image: image, size: size, markdown: markdown, altText: "Corners")
        let canvas = PicoHostedMediaCanvasView(model: model)
        canvas.frame = CGRect(origin: .zero, size: size)
        canvas.layoutSubtreeIfNeeded()
        canvas.mouseEntered(with: try mouse(.mouseEntered))
        let (zoom, copy) = try controls(in: canvas)
        for control in [zoom, copy] as [NSView] where isVisible(control, in: canvas) {
            #expect(canvas.bounds.contains(control.convert(control.bounds, to: canvas)),
                    "Native controls are never partially clipped to fit a small image")
        }
        if size.width < 48 || size.height < 48 {
            #expect(!isVisible(zoom, in: canvas) && !isVisible(copy, in: canvas))
        } else if size.width < 80 {
            #expect(!isVisible(zoom, in: canvas) && isVisible(copy, in: canvas))
        } else {
            #expect(isVisible(zoom, in: canvas))
            #expect(zoom.segmentCount == 2, "Zoom remains a connected pair")
            let alignment = zoom.alignmentRect(forFrame: zoom.frame)
            #expect(alignment.width == 64)
            if size.width >= 120 || size.height >= 88 { #expect(isVisible(copy, in: canvas)) }
        }
        #expect(canvas.accessibilityCustomActions()?.contains { $0.name == "Zoom in" } == true,
                "Actions remain available even when the image is too small for floating controls")
        canvas.keyDown(with: try key("+"))
        #expect(model.zoom == 1.25)
        #expect(model.parseCount == 0)
    }

    @Test("Image zoom uses the shared ease-out transition and respects Reduce Motion", .timeLimit(.minutes(1)), arguments: [false, true])
    func imageZoomAnimation(reduceMotion: Bool) async throws {
        _ = NSApplication.shared
        let (image, _) = try makeImage()
        let model = PicoHostedMediaModel(image: image, size: CGSize(width: 320, height: 160),
                                         markdown: markdown, altText: "Corners")
        let canvas = PicoHostedMediaCanvasView(model: model, reducesMotion: { reduceMotion })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        let start = model.drawingRect(in: canvas.bounds.size)
        let revision = model.presentationRevision
        canvas.keyDown(with: try key("+", window: window))
        #expect(model.zoom == 1.25)
        #expect(canvas.presentedDrawingRect == (reduceMotion ? nil : start))
        await canvas.waitForZoomAnimation()
        #expect(canvas.presentedDrawingRect == nil)
        #expect(model.presentationRevision == revision + 1, "Animation frames do not publish document changes")
        #expect(model.parseCount == 0)
        #expect(model.markdownRepresentation() == markdown)
        #expect(canvas.frame.size == CGSize(width: 320, height: 160))
    }

    private func makeImage() throws -> (NSImage, NSBitmapImageRep) {
        let storage = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 40,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bitmap = try #require(storage.retagging(with: .sRGB))
        let bytes = try #require(bitmap.bitmapData)
        for y in 0..<40 {
            for x in 0..<80 {
                let pixel: [UInt8] = (35..<45).contains(x) ? [0, 0, 0, 0]
                    : y < 20 ? (x < 40 ? [255, 0, 0, 255] : [0, 255, 0, 255])
                    : (x < 40 ? [0, 0, 255, 255] : [255, 255, 0, 255])
                let offset = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel
                for (channel, byte) in pixel.enumerated() { bytes[offset + channel] = byte }
            }
        }
        let image = NSImage(size: CGSize(width: 80, height: 40))
        image.addRepresentation(bitmap)
        image.cacheMode = .never
        return (image, bitmap)
    }

    private func bitmap(of view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func color(at point: CGPoint, in bitmap: NSBitmapImageRep, canvas: NSView) throws -> NSColor {
        let x = Int(point.x * CGFloat(bitmap.pixelsWide) / canvas.bounds.width)
        let y = Int(point.y * CGFloat(bitmap.pixelsHigh) / canvas.bounds.height)
        return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func expectSameColor(at point: CGPoint, in bitmap: NSBitmapImageRep, as reference: NSBitmapImageRep, canvas: NSView) throws {
        let actual = try color(at: point, in: bitmap, canvas: canvas)
        let expected = try color(at: point, in: reference, canvas: canvas)
        #expect(abs(actual.redComponent - expected.redComponent) < 0.02)
        #expect(abs(actual.greenComponent - expected.greenComponent) < 0.02)
        #expect(abs(actual.blueComponent - expected.blueComponent) < 0.02)
        #expect(actual.alphaComponent > 0.99)
    }

    private func controls(in view: NSView) throws -> (NSSegmentedControl, NSButton) {
        let views = descendants(of: view)
        return try (#require(views.compactMap { $0 as? NSSegmentedControl }.first),
                    #require(views.compactMap { $0 as? NSButton }.first))
    }

    private func descendants(of view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants(of: $0) } }

    private func isVisible(_ control: NSView, in canvas: NSView) -> Bool {
        var current: NSView? = control
        while let view = current, view !== canvas {
            if view.isHidden || view.alphaValue == 0 { return false }
            current = view.superview
        }
        return current === canvas
    }

    private func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        if type == .mouseEntered {
            return try #require(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil, eventNumber: 0,
                                                      trackingNumber: 0, userData: nil))
        }
        return try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    }

    private func key(_ character: String, window: NSWindow? = nil) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window?.windowNumber ?? 0, context: nil, characters: character,
                                     charactersIgnoringModifiers: character, isARepeat: false, keyCode: 24))
    }
}
#endif
