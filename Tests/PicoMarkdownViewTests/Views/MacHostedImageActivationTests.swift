#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS hosted image activation")
@MainActor
struct MacHostedImageActivationTests {
    @Test("A parent-text click targets one image and preserves its loaded source and Markdown", .timeLimit(.minutes(1)))
    func clickTargetsLoadedImage() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.close() }
        var activations: [MarkdownImageActivation] = []
        fixture.controller.installImageTapHandler(on: fixture.view) { activations.append($0) }
        let storage = try #require(fixture.view.textStorage)
        let first = try #require(canvas(in: fixture.attachments[0].loadHostedView()))
        let second = try #require(canvas(in: fixture.attachments[1].loadHostedView()))
        let firstSource = first.model.source
        let secondSource = second.model.source
        let originalText = storage.string
        let originalAttachments = fixture.attachments
        fixture.view.setSelectedRange(NSRange(location: 0, length: 0))
        try click(second, in: fixture)
        let activation = try #require(activations.first)
        #expect(activations.count == 1)
        #expect(activation.image === fixture.image)
        #expect(activation.sourceURL.absoluteString == "https://example.com/two.png?literal=&amp;")
        #expect(activation.altText == "Second image")
        #expect(activation.title == "Literal &copy;")
        #expect(storage.string == originalText)
        #expect(attachments(in: storage).elementsEqual(originalAttachments, by: { $0 === $1 }))
        #expect(first.model.source == firstSource && second.model.source == secondSource)
        #expect(first.model.zoom == 1 && second.model.zoom == 1)
        fixture.view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(fixture.view.writeSelection(to: board, types: [.string]))
        let copied = try #require(board.string(forType: .string))
        #expect(copied.contains("Before paragraph."))
        #expect(copied.contains(firstSource) && copied.contains(secondSource))
        #expect(!copied.contains("\u{FFFC}"))
    }

    @Test("Image callbacks can be installed, replaced and removed without rebuilding attachments", .timeLimit(.minutes(1)))
    func callbackLifecycle() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.close() }
        let image = try #require(canvas(in: fixture.attachments[0].loadHostedView()))
        #expect(!image.accessibilityPerformPress())
        var first = 0
        var second = 0
        fixture.controller.installImageTapHandler(on: fixture.view) { _ in first += 1 }
        #expect(image.accessibilityPerformPress())
        fixture.controller.installImageTapHandler(on: fixture.view) { _ in second += 1 }
        #expect(image.accessibilityPerformPress())
        fixture.controller.installImageTapHandler(on: fixture.view, nil)
        #expect(!image.accessibilityPerformPress())
        #expect(first == 1 && second == 1)
        #expect(image.model.zoom == 1 && !image.model.capturesScroll)
        let storage = try #require(fixture.view.textStorage)
        #expect(attachments(in: storage).elementsEqual(fixture.attachments, by: { $0 === $1 }))
    }

    @Test("Callback installation patches only image link attributes and keeps selection and ordinary links", .timeLimit(.minutes(1)))
    func nativeLinkRoutingAndSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.close() }
        let storage = try #require(fixture.view.textStorage)
        let image = try #require(canvas(in: fixture.attachments[0].loadHostedView()))
        let range = try imageRange(image, in: fixture)
        #expect(storage.attribute(.link, at: range.location, effectiveRange: nil) == nil)
        let original = storage.string
        let selection = NSRange(location: 0, length: storage.length)
        fixture.view.setSelectedRange(selection)
        var activations = 0
        var links: [URL] = []
        fixture.controller.installLinkHandler(on: fixture.view) { url, _ in links.append(url) }
        fixture.controller.installImageTapHandler(on: fixture.view) { _ in activations += 1 }
        #expect(fixture.view.selectedRange() == selection)
        #expect(storage.string == original)
        let token = try #require(storage.attribute(.link, at: range.location, effectiveRange: nil))
        let tooltip = try #require(storage.attribute(.toolTip, at: range.location, effectiveRange: nil) as? String)
        #expect(!tooltip.contains("pico-image-activation"))
        #expect(!tooltip.isEmpty)
        let imagePoint = image.convert(CGPoint(x: image.bounds.midX, y: image.bounds.midY), to: fixture.view)
        #expect(fixture.view.hoverLink(at: imagePoint) == nil, "Image activation tokens are not public link hovers")
        // NSTextView owns click-vs-selection tracking, as for ordinary links.
        // Invoke the same delegate route without AppKit's nested mouse loop.
        fixture.view.clicked(onLink: token, at: range.location)
        #expect(activations == 1 && links.isEmpty)
        let ordinary = (storage.string as NSString).range(of: "ordinary link")
        try #require(ordinary.location != NSNotFound)
        let url = try #require(storage.attribute(.link, at: ordinary.location, effectiveRange: nil))
        fixture.view.clicked(onLink: url, at: ordinary.location)
        #expect(links.map(\.absoluteString) == ["https://example.com/page"])
        #expect(activations == 1)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(fixture.view.writeSelection(to: board, types: [.string]))
        let copied = try #require(board.string(forType: .string))
        #expect(copied.contains(image.model.source))
        #expect(!copied.contains("pico-image"), "Private activation tokens never leak into copied Markdown")
        fixture.controller.installImageTapHandler(on: fixture.view, nil)
        #expect(storage.attribute(.link, at: range.location, effectiveRange: nil) == nil)
        #expect(storage.attribute(.toolTip, at: range.location, effectiveRange: nil) == nil)
        #expect(fixture.view.selectedRange() == selection)
        #expect(storage.string == original)
        #expect(attachments(in: storage).elementsEqual(fixture.attachments, by: { $0 === $1 }))
    }

    @Test("Document replacement retires image links and retained accessibility callbacks", .timeLimit(.minutes(1)))
    func documentReplacementRetiresActivation() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.close() }
        var activations = 0
        var links = 0
        fixture.controller.installImageTapHandler(on: fixture.view) { _ in activations += 1 }
        fixture.controller.installLinkHandler(on: fixture.view) { _, _ in links += 1 }
        let image = try #require(canvas(in: fixture.attachments[0].loadHostedView()))
        let range = try imageRange(image, in: fixture)
        let storage = try #require(fixture.view.textStorage)
        let token = try #require(storage.attribute(.link, at: range.location, effectiveRange: nil))
        let replacement = MarkdownStreamingPipeline()
        for update in [await replacement.feed("Replacement document.\n\n"), await replacement.finish()] {
            if let update {
                fixture.controller.update(textView: fixture.view, blocks: update.blocks, diffs: [update.diff],
                                          replaceToken: 2, configuration: .default())
            }
        }
        fixture.view.clicked(onLink: token, at: range.location)
        _ = image.accessibilityPerformPress()
        #expect(activations == 0 && links == 0)
        #expect(attachments(in: storage).isEmpty)
        #expect(storage.string.contains("Replacement document."))
    }

    @Test("The parent context menu offers image Markdown copying even without an activation callback", .timeLimit(.minutes(1)))
    func parentImageContextMenu() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.close() }
        let image = try #require(canvas(in: fixture.attachments[0].loadHostedView()))
        let point = image.convert(CGPoint(x: image.bounds.midX, y: image.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                   windowNumber: fixture.window.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 0))
        let menu = try #require(fixture.view.menu(for: event))
        #expect(menu.items.contains { $0.title == "Copy Image Markdown" })
        #expect(!menu.items.contains { $0.title == "Zoom in" || $0.title == "Zoom out" })
        fixture.controller.installImageTapHandler(on: fixture.view) { _ in }
        let enabledMenu = try #require(fixture.view.menu(for: event))
        #expect(enabledMenu.items.map(\.title) == ["Copy Image Markdown"],
                "Private activation links have no browser or Copy Link menu actions")
    }

    @Test("Image activation links paint no underline while ordinary links stay underlined", .timeLimit(.minutes(1)), arguments: [false, true])
    func imageActivationDoesNotPaintLinkUnderline(initiallyEnabled: Bool) async throws {
        var activations = 0
        let handler: @MainActor (MarkdownImageActivation) -> Void = { _ in activations += 1 }
        let fixture = try await makeFixture(imageTapHandler: initiallyEnabled ? handler : nil)
        defer { fixture.window.close() }
        fixture.window.appearance = NSAppearance(named: .aqua)
        fixture.view.usesAdaptiveColorMappingForDarkAppearance = false
        fixture.view.drawsBackground = true
        fixture.view.backgroundColor = .white
        let storage = try #require(fixture.view.textStorage)
        let selection = NSRange(location: 0, length: "Before".utf16.count)
        fixture.view.setSelectedRange(selection)
        if !initiallyEnabled { fixture.controller.installImageTapHandler(on: fixture.view, handler) }
        let manager = try #require(fixture.view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        manager.ensureLayout(for: content.documentRange)
        manager.textViewportLayoutController.layoutViewport()
        fixture.view.layoutSubtreeIfNeeded()
        fixture.window.displayIfNeeded()
        let captureRect = fixture.view.bounds
        let bitmap = try #require(fixture.view.bitmapImageRepForCachingDisplay(in: captureRect))
        fixture.view.effectiveAppearance.performAsCurrentDrawingAppearance {
            fixture.view.cacheDisplay(in: captureRect, to: bitmap)
        }
        if let directory = ProcessInfo.processInfo.environment["PICO_IMAGE_UNDERLINE_SNAPSHOT_DIRECTORY"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try png.write(to: url.appendingPathComponent(initiallyEnabled ? "initial-handler.png" : "late-handler.png"))
        }
        for attachment in fixture.attachments {
            let image = try #require(canvas(in: attachment.loadHostedView()))
            let range = try imageRange(image, in: fixture)
            let token = try #require(storage.attribute(.link, at: range.location, effectiveRange: nil))
            let location = try #require(content.location(content.documentRange.location, offsetBy: range.location))
            let rendering = manager.renderingAttributes(forLink: token, at: location)
            #expect((rendering[.underlineStyle] as? Int ?? 0) == 0,
                    "A private image activation link must not inherit AppKit's single underline")
            let row = try textRect(range, in: fixture.view)
            let strip = CGRect(x: captureRect.maxX - 90, y: row.minY - 6, width: 60, height: row.height + 12)
            #expect(bluePixelCount(in: strip, bitmap: bitmap, captureRect: captureRect) == 0,
                    "The blank far-right image row must not contain the default full-width blue underline")
        }
        let ordinary = (storage.string as NSString).range(of: "ordinary link")
        try #require(ordinary.location != NSNotFound)
        let link = try #require(storage.attribute(.link, at: ordinary.location, effectiveRange: nil))
        let location = try #require(content.location(content.documentRange.location, offsetBy: ordinary.location))
        let rendering = manager.renderingAttributes(forLink: link, at: location)
        #expect(rendering[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(bluePixelCount(in: try textRect(ordinary, in: fixture.view).insetBy(dx: -2, dy: -3),
                               bitmap: bitmap, captureRect: captureRect) > 0,
                "The ordinary Markdown link must remain visibly blue")
        #expect(fixture.view.selectedRange() == selection)
        #expect(attachments(in: storage).elementsEqual(fixture.attachments, by: { $0 === $1 }))
        let image = try #require(canvas(in: fixture.attachments[0].loadHostedView()))
        #expect(image.accessibilityPerformPress())
        #expect(activations == 1)
        fixture.view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(fixture.view.writeSelection(to: board, types: [.string]))
        #expect(board.string(forType: .string)?.contains(image.model.source) == true)
        #expect(board.string(forType: .string)?.contains("pico-image-activation") == false)
        #expect(fixture.view.textLayoutManager != nil)
    }

    private func textRect(_ range: NSRange, in view: NSTextView) throws -> CGRect {
        let manager = try #require(view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let start = try #require(content.location(content.documentRange.location, offsetBy: range.location))
        let end = try #require(content.location(start, offsetBy: range.length))
        let textRange = try #require(NSTextRange(location: start, end: end))
        var rect = CGRect.null
        manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
            rect = rect.union(segment)
            return true
        }
        try #require(!rect.isNull)
        return rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    }

    private func bluePixelCount(in rect: CGRect, bitmap: NSBitmapImageRep, captureRect: CGRect) -> Int {
        let area = rect.intersection(captureRect)
        guard !area.isEmpty else { return 0 }
        let scaleX = CGFloat(bitmap.pixelsWide) / captureRect.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / captureRect.height
        var count = 0
        for y in Int((area.minY - captureRect.minY) * scaleY)..<Int((area.maxY - captureRect.minY) * scaleY) {
            for x in Int((area.minX - captureRect.minX) * scaleX)..<Int((area.maxX - captureRect.minX) * scaleX) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.blueComponent - color.redComponent > 0.2 && color.blueComponent - color.greenComponent > 0.1 {
                    count += 1
                }
            }
        }
        return count
    }

    private typealias Fixture = (controller: TextKitStreamingController, view: StreamingTextKit2View,
                                 window: NSWindow, attachments: [PicoHostedAttachment], image: NSImage)

    private func makeFixture(imageTapHandler: (@MainActor (MarkdownImageActivation) -> Void)? = nil) async throws -> Fixture {
        _ = NSApplication.shared
        let controller = TextKitStreamingController()
        let view = try #require(controller.makeTextKit2View(configuration: .default()) as? StreamingTextKit2View)
        controller.installImageTapHandler(on: view, imageTapHandler)
        view.frame = CGRect(x: 0, y: 0, width: 700, height: 1200)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        var fixtureReady = false
        defer { if !fixtureReady { window.close() } }
        window.orderFront(nil)
        let image = NSImage(size: CGSize(width: 120, height: 60))
        let pipeline = MarkdownStreamingPipeline(imageProvider: ActivationImageProvider(result: MarkdownImageResult(image: image)))
        let markdown = "Before paragraph.\n\n![First image](https://example.com/one.png)\n\nBetween images and [ordinary link](https://example.com/page).\n\n![Second image](https://example.com/two.png?literal=&amp;amp; \"Literal &amp;copy;\")\n\nAfter paragraph.\n\n"
        for update in [await pipeline.feed(markdown), await pipeline.finish()] {
            if let update {
                controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                                  replaceToken: 1, configuration: .default())
            }
        }
        let storage = try #require(view.textStorage)
        let images = attachments(in: storage)
        try #require(images.count == 2)
        var markerOffsets: [ObjectIdentifier: Int] = [:]
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attachment = value as? PicoHostedAttachment { markerOffsets[ObjectIdentifier(attachment)] = range.location }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while true {
            if let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
            }
            view.layoutSubtreeIfNeeded()
            for attachment in images { attachment.hostingView?.layoutSubtreeIfNeeded() }
            window.displayIfNeeded()
            if images.allSatisfy({ attachment in
                guard let host = attachment.hostingView, host.isDescendant(of: view),
                      let canvas = self.canvas(in: host),
                      abs(host.fittingSize.height - attachment.measuredSize.height) <= 1,
                      let offset = markerOffsets[ObjectIdentifier(attachment)],
                      let manager = view.textLayoutManager, let content = manager.textContentManager,
                      let location = content.location(content.documentRange.location, offsetBy: offset),
                      let fragment = manager.textLayoutFragment(for: location),
                      fragment.layoutFragmentFrame.height >= attachment.measuredSize.height - 1 else { return false }
                return canvas.window === window && canvas.bounds.width > 0 && canvas.bounds.height > 0
            }) { break }
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for TextKit to mount the hosted image canvases")
                throw FixtureTimeout()
            }
            // SwiftUI materializes its AppKit children asynchronously. Wait for
            // that actual hierarchy instead of assuming a fixed number of yields.
            try await Task.sleep(for: .milliseconds(10))
        }
        fixtureReady = true
        return (controller, view, window, images, image)
    }

    private struct FixtureTimeout: Error {}

    private func click(_ canvas: NSView, in fixture: Fixture) throws {
        let range = try imageRange(canvas, in: fixture)
        let storage = try #require(fixture.view.textStorage)
        let token = try #require(storage.attribute(.link, at: range.location, effectiveRange: nil))
        fixture.view.clicked(onLink: token, at: range.location)
    }

    private func imageRange(_ view: NSView, in fixture: Fixture) throws -> NSRange {
        let storage = try #require(fixture.view.textStorage)
        var result: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attachment = value as? PicoHostedAttachment,
               view.isDescendant(of: attachment.loadHostedView()) { result = range }
        }
        return try #require(result)
    }

    private func attachments(in storage: NSTextStorage) -> [PicoHostedAttachment] {
        var result: [PicoHostedAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { result.append(attachment) }
        }
        return result
    }

    private func canvas(in view: NSView) -> PicoHostedMediaCanvasView? {
        if let result = view as? PicoHostedMediaCanvasView { return result }
        return view.subviews.lazy.compactMap { canvas(in: $0) }.first
    }
}

private actor ActivationImageProvider: MarkdownImageProvider {
    let result: MarkdownImageResult
    init(result: MarkdownImageResult) { self.result = result }
    func image(for url: URL) async -> MarkdownImageResult? { result }
}
#endif
