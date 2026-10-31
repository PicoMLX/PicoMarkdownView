#if os(macOS) && canImport(JavaScriptCore)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS hosted chart loading integration")
@MainActor
struct MacHostedChartLoadingIntegrationTests {
    @Test("An empty opening fence immediately reserves one fixed native marker")
    func openingAndSourceGrowthNeverInsertJSONIntoTextStorage() async throws {
        let fixture = makeFixture()
        fixture.backend.setHostedStreamActive(true)
        apply(await fixture.pipeline.feed("Before paragraph with 🧭.\n\n```vega-lite\n"), to: fixture)
        let storage = try #require(fixture.view.textStorage)
        let block = try #require(await fixture.pipeline.blocksSnapshot().first { $0.vegaLiteChart != nil })
        let attachment = try #require(fixture.backend.hostedAttachment(for: block.id))
        let model = try #require(fixture.backend.hostedVectorModel(for: block.id))
        #expect(block.vegaLiteChart?.svg == "")
        #expect(block.vegaLiteChart?.intrinsicSize == .zero)
        #expect(model.source.isEmpty)
        #expect(attachment.markdownRepresentation() == "```vega-lite\n```")
        #expect(model.isLoading && !model.isClosed)
        #expect(model.parseCount == 0)
        #expect(markerCount(storage) == 1)
        #expect(attachment.bounds.height == 48)
        let originalText = storage.string
        let originalLength = storage.length
        fixture.view.setSelectedRange(NSRange(location: 0, length: originalLength))
        let selection = fixture.view.selectedRange()
        let edits = CharacterEditCount(storage: storage)
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if edits.storage.editedMask.contains(.editedCharacters) { edits.value += 1 }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var source = ""
        for chunk in ["{\n", "  \"description\": \"Keep  spaces, 🧭 and \\n.\",\n",
                      String(repeating: "  {\"x\":1,\"y\":2},\n", count: 512),
                      "  \"next\": \"partial"] {
            source += chunk
            apply(await fixture.pipeline.feed(chunk), to: fixture)
            #expect(fixture.backend.hostedAttachment(for: block.id) === attachment)
            #expect(fixture.backend.hostedVectorModel(for: block.id) === model)
            #expect(model.source == source)
            #expect(model.parseCount == 0)
            #expect(storage.string == originalText && storage.length == originalLength)
            #expect(fixture.view.selectedRange() == selection)
            #expect(attachment.bounds.height == 48)
            let fencedBody = source.hasSuffix("\n") ? source : source + "\n"
            #expect(copySelection(fixture.view).contains("```vega-lite\n" + fencedBody + "```"))
        }
        #expect(edits.value == 0, "Only hosted source metadata may change while the fence is open")
        await model.waitForLoadingDelay()
        #expect(model.showsLoadingPlaceholder)
        #expect(model.loadingActivity == .receiving)
        #expect(model.viewportHeight(availableWidth: 700) == 48)
        fixture.backend.setHostedStreamActive(false)
    }

    @Test("Closure upgrades the same attachment once and preserves continuous Markdown copy")
    func closureKeepsAttachmentModelSelectionAndSource() async throws {
        let fixture = makeFixture()
        fixture.backend.setHostedStreamActive(true)
        apply(await fixture.pipeline.feed("Before native paragraph.\n\n```vega-lite\n"), to: fixture)
        let block = try #require(await fixture.pipeline.blocksSnapshot().first { $0.vegaLiteChart != nil })
        let attachment = try #require(fixture.backend.hostedAttachment(for: block.id))
        let model = try #require(fixture.backend.hostedVectorModel(for: block.id))
        apply(await fixture.pipeline.feed(VegaLiteRenderingFixture.source), to: fixture)
        #expect(model.source == VegaLiteRenderingFixture.source)
        #expect(model.parseCount == 0)
        apply(await fixture.pipeline.feed("``"), to: fixture)
        #expect(model.isLoading)
        apply(await fixture.pipeline.feed("`\n\nAfter native paragraph.\n\n"), to: fixture)
        apply(await fixture.pipeline.finish(), to: fixture)
        await settle(fixture.view)
        let storage = try #require(fixture.view.textStorage)
        #expect(fixture.backend.hostedAttachment(for: block.id) === attachment)
        #expect(fixture.backend.hostedVectorModel(for: block.id) === model)
        #expect(model.isClosed && model.isRenderable && !model.isLoading)
        #expect(model.parseCount == 1)
        #expect(!model.showsLoadingPlaceholder)
        #expect(markerCount(storage) == 1)
        #expect(!storage.string.contains(VegaLiteRenderingFixture.source))
        fixture.view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let copied = copySelection(fixture.view)
        let fenced = "```vega-lite\n" + VegaLiteRenderingFixture.source + "```"
        #expect(copied.contains("Before native paragraph."))
        #expect(copied.contains("After native paragraph."))
        #expect(copied.components(separatedBy: fenced).count == 2)
        #expect(!copied.contains("\u{FFFC}"))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(model.copySource(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == VegaLiteRenderingFixture.source)
    }

    @Test("Pause defers source, stream inactivity stops animation, and replacement retires loading")
    func pauseInactivityAndReplacementRetireLoadingState() async throws {
        let fixture = makeFixture()
        fixture.backend.setHostedStreamActive(true)
        apply(await fixture.pipeline.feed("Before.\n\n```vega-lite\n{\n"), to: fixture)
        let block = try #require(await fixture.pipeline.blocksSnapshot().first { $0.vegaLiteChart != nil })
        let attachment = try #require(fixture.backend.hostedAttachment(for: block.id))
        let model = try #require(fixture.backend.hostedVectorModel(for: block.id))
        fixture.backend.setPaused(true)
        #expect(model.loadingActivity == .paused)
        apply(await fixture.pipeline.feed("  \"mark\": \"bar\",\n"), to: fixture)
        #expect(model.source == "{\n")
        fixture.backend.setPaused(false)
        apply(blocks: await fixture.pipeline.blocksSnapshot(), to: fixture)
        #expect(model.source == "{\n  \"mark\": \"bar\",\n")
        #expect(model.loadingActivity == .receiving)
        #expect(fixture.backend.hostedAttachment(for: block.id) === attachment)
        fixture.backend.setHostedStreamActive(false)
        #expect(model.loadingActivity == .stopped)
        fixture.backend.setHostedStreamActive(true)
        #expect(model.loadingActivity == .receiving)
        fixture.backend.resetDocumentOnNextApply()
        let replacement = MarkdownStreamingPipeline()
        apply(await replacement.feed("Only replacement prose remains.\n\n"), to: fixture)
        await model.waitForLoadingDelay()
        #expect(model.loadingActivity == .stopped)
        #expect(!model.showsLoadingPlaceholder)
        #expect(model.parseCount == 0)
        #expect(fixture.backend.hostedVectorModel(for: block.id) == nil)
        #expect(fixture.backend.hostedAttachment(for: block.id) == nil)
        let storage = try #require(fixture.view.textStorage)
        #expect(markerCount(storage) == 0)
        fixture.view.setSelectedRange(NSRange(location: 0, length: storage.length))
        #expect(copySelection(fixture.view) == "Only replacement prose remains.\n")
    }

    @Test("An invalid or unsupported close retires its loader and returns exact native code", arguments: [
        "{broken JSON}\n",
        "{\"mark\":\"bar\",\"data\":{\"url\":\"https://example.com/data.json\"}}\n"
    ])
    func invalidClosureFallsBackWithoutStaleLoading(_ source: String) async throws {
        let fixture = makeFixture()
        fixture.backend.setHostedStreamActive(true)
        apply(await fixture.pipeline.feed("```vega-lite\n" + source), to: fixture)
        let block = try #require(await fixture.pipeline.blocksSnapshot().first { $0.vegaLiteChart != nil })
        let model = try #require(fixture.backend.hostedVectorModel(for: block.id))
        #expect(model.isLoading && model.parseCount == 0)
        apply(await fixture.pipeline.feed("```\n\n"), to: fixture)
        apply(await fixture.pipeline.finish(), to: fixture)
        await model.waitForLoadingDelay()
        let closed = try #require(await fixture.pipeline.blocksSnapshot().first)
        #expect(closed.snapshot.isClosed && closed.vegaLiteChart == nil)
        #expect(closed.codeBlock?.code == source)
        #expect(fixture.backend.hostedVectorModel(for: block.id) == nil)
        #expect(model.loadingActivity == .stopped && !model.showsLoadingPlaceholder)
        let storage = try #require(fixture.view.textStorage)
        #expect(storage.string.contains(source))
        #expect(markerCount(storage) == 0)
    }

    @Test("Loading first children preserve native list and quote indentation", arguments: [false, true])
    func loadingContainersKeepMarkersAndAvailableWidth(quoted: Bool) async throws {
        let fixture = makeFixture()
        let prefix = quoted ? "> ```vega-lite\n" : "1. ```vega-lite\n"
        apply(await fixture.pipeline.feed(prefix), to: fixture)
        let block = try #require(await fixture.pipeline.blocksSnapshot().first { $0.vegaLiteChart != nil })
        let attachment = try #require(fixture.backend.hostedAttachment(for: block.id))
        let storage = try #require(fixture.view.textStorage)
        let marker = (storage.string as NSString).range(of: "\u{FFFC}")
        try #require(marker.location != NSNotFound)
        let paragraph = try #require(storage.attribute(.paragraphStyle, at: marker.location,
                                                       effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.headIndent > 0)
        #expect(paragraph.textBlocks.isEmpty)
        if quoted {
            #expect(storage.attribute(.picoBlockquoteLevel, at: marker.location, effectiveRange: nil) as? Int == 1)
        } else {
            #expect(storage.string.contains("1. \u{FFFC}"))
            #expect(paragraph.firstLineHeadIndent < paragraph.headIndent)
        }
        let expectedWidth = fixture.view.bounds.width - fixture.view.textContainerInset.width * 2 - paragraph.headIndent
        #expect(abs(attachment.context.availableWidth - expectedWidth) < 0.5)
        #expect(attachment.bounds.height == 48)
        apply(await fixture.pipeline.feed((quoted ? "> " : "   ") + "{\"mark\":\"bar\"}\n"), to: fixture)
        #expect(fixture.backend.hostedAttachment(for: block.id) === attachment)
        #expect(attachment.markdownRepresentation() == "```vega-lite\n{\"mark\":\"bar\"}\n```")
    }

    @Test("Opted-out charts and ordinary JSON retain their existing open code presentation", arguments: [false, true])
    func ordinaryCodeAndOptOutStayNative(disabled: Bool) async throws {
        let theme = MarkdownRenderTheme.default().withVegaLiteRendering(!disabled)
        let fixture = makeFixture(theme: theme)
        let language = disabled ? "vega-lite" : "json"
        let source = "{\"mark\":\"bar\"}\n"
        apply(await fixture.pipeline.feed("```" + language + "\n" + source), to: fixture)
        let block = try #require(await fixture.pipeline.blocksSnapshot().first)
        #expect(!block.snapshot.isClosed && block.vegaLiteChart == nil)
        #expect(block.codeBlock?.code == source)
        #expect(fixture.backend.hostedAttachment(for: block.id) == nil)
        #expect(fixture.view.string.contains(source))
    }

    @Test("An offscreen loader reserves 48 points before a real window lazily mounts it")
    func realWindowPreservesEstimatedLoadingHeight() async throws {
        let fixture = makeFixture()
        fixture.view.setFrameSize(NSSize(width: 400, height: 120))
        fixture.backend.setHostedStreamActive(true)
        let prefix = String(repeating: "Native paragraph before the loading chart.\n\n", count: 20)
        apply(await fixture.pipeline.feed(prefix + "```vega-lite\n"), to: fixture)
        let block = try #require(await fixture.pipeline.blocksSnapshot().first { $0.vegaLiteChart != nil })
        let attachment = try #require(fixture.backend.hostedAttachment(for: block.id))
        let model = try #require(fixture.backend.hostedVectorModel(for: block.id))
        #expect(attachment.hostingView == nil)
        #expect(attachment.bounds.height == 48)
        let scroll = NSScrollView(frame: fixture.view.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = fixture.view
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let screenOrigin = NSScreen.main?.visibleFrame.origin ?? .zero
        window.setFrameOrigin(NSPoint(x: screenOrigin.x + 20, y: screenOrigin.y + 20))
        window.orderFront(nil)
        defer { window.close() }
        fixture.view.setFrameSize(NSSize(width: 400, height: 2_000))
        await settle(fixture.view)
        let storage = try #require(fixture.view.textStorage)
        let marker = (storage.string as NSString).range(of: "\u{FFFC}")
        let manager = try #require(fixture.view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: marker.location))
        let beforeScroll = try #require(manager.textLayoutFragment(for: location))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, beforeScroll.layoutFragmentFrame.minY - 8)))
        scroll.reflectScrolledClipView(scroll.contentView)
        await model.waitForLoadingDelay()
        await settle(fixture.view)
        #expect(fixture.view.window === window && window.isVisible)
        let fragment = try #require(manager.textLayoutFragment(for: location))
        try #require(fragment.layoutFragmentFrame.intersects(fixture.view.visibleRect), "The loading marker must actually be in the native viewport")
        let diagnostics = "providers=\(fragment.textAttachmentViewProviders.count), visible=\(fixture.view.visibleRect), marker=\(fragment.layoutFragmentFrame), usesView=\(attachment.usesTextAttachmentView), hasImage=\(attachment.image != nil), activity=\(model.loadingActivity), revealed=\(model.showsLoadingPlaceholder)"
        let host = try #require(attachment.hostingView, "Visible viewport layout must lazily create the real loading host: \(diagnostics)")
        #expect(host.accessibilityLabel() == "Preparing chart…", "Mounted loading status missing: \(diagnostics)")
        #expect(host.accessibilityRole() == .staticText)
        #expect(host.isAccessibilityElement())
        #expect(host.accessibilityChildren()?.isEmpty != false, "Loading must not expose chart source or unfinished controls")
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(centralTextColors(in: bitmap).count > 1,
                "The real native host must draw text ink beyond its spinner and uniform loading-card background")
        #expect(attachment.measuredSize.height == 48)
        #expect(model.parseCount == 0)
        fixture.backend.setHostedStreamActive(false)
    }

    private struct Fixture {
        let backend: TextKitStreamingBackend
        let view: StreamingTextKit2View
        let pipeline: MarkdownStreamingPipeline
    }

    private func makeFixture(theme: MarkdownRenderTheme = .default()) -> Fixture {
        _ = NSApplication.shared
        let backend = TextKitStreamingBackend()
        let view = StreamingTextKit2View(backend: backend)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.textContainerInset = .zero
        view.isSelectable = true
        return Fixture(backend: backend, view: view, pipeline: MarkdownStreamingPipeline(theme: theme))
    }

    private func apply(_ update: StreamingUpdate?, to fixture: Fixture) {
        guard let update else { return }
        let selection = fixture.backend.apply(blocks: update.blocks, diffs: [update.diff], selection: fixture.view.selectedRange())
        fixture.view.setSelectedRange(selection)
        fixture.backend.updateHostedAttachments(width: fixture.view.bounds.width, selection: [selection])
    }

    private func apply(blocks: [RenderedBlock], to fixture: Fixture) {
        let selection = fixture.backend.apply(blocks: blocks, selection: fixture.view.selectedRange())
        fixture.view.setSelectedRange(selection)
        fixture.backend.updateHostedAttachments(width: fixture.view.bounds.width, selection: [selection])
    }

    private func markerCount(_ storage: NSTextStorage) -> Int { storage.string.filter { $0 == "\u{FFFC}" }.count }

    private func copySelection(_ view: NSTextView) -> String {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        return pasteboard.string(forType: .string) ?? ""
    }

    private func centralTextColors(in bitmap: NSBitmapImageRep) -> Set<UInt32> {
        // Exclude the spinner and rounded corners; a blank card is uniform here.
        let scaleX = CGFloat(bitmap.pixelsWide) / 400
        let scaleY = CGFloat(bitmap.pixelsHigh) / 48
        var colors: Set<UInt32> = []
        for y in Int(8 * scaleY)..<min(bitmap.pixelsHigh, Int(40 * scaleY)) {
            for x in Int(48 * scaleX)..<max(Int(48 * scaleX), bitmap.pixelsWide - Int(12 * scaleX)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let components = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                let packed = components.reduce(UInt32(0)) { ($0 << 8) | UInt32(clamping: Int(($1 * 255).rounded())) }
                colors.insert(packed)
            }
        }
        return colors
    }

    private func settle(_ view: NSTextView) async {
        for _ in 0..<6 {
            if let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
            }
            view.layoutSubtreeIfNeeded()
            await Task.yield()
        }
    }
}

@MainActor
private final class CharacterEditCount {
    let storage: NSTextStorage
    var value = 0
    init(storage: NSTextStorage) { self.storage = storage }
}
#endif
