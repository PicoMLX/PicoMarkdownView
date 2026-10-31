#if os(macOS) && canImport(JavaScriptCore)
import AppKit
import SwiftUI
import Vision
import ImageIO
import CryptoKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS hosted chart loading integration", .timeLimit(.minutes(1)))
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

    @Test("The complete official grouped repeat source stays uncompiled until close, then shows its chart and following text")
    func groupedRepeatCompletesAfterItsFullSourceArrives() async throws {
        let source = try officialGroupedRepeatSource()
        #expect(source.utf8.count == 1_281_975)
        #expect(source.split(whereSeparator: \.isWhitespace).count == 72_270,
                "At the example's 30 words/second, this exact source needs about 40 minutes to arrive")
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 900)
        controller.setHostedStreamActive(true)
        defer { controller.setHostedStreamActive(false) }
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.updateMermaidContentWidth(336)
        func applyUpdate(_ update: StreamingUpdate?) {
            guard let update else { return }
            controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                              replaceToken: 1, configuration: .default(), documentIdentity: 1)
        }
        applyUpdate(await pipeline.feed("Before grouped repeat.\n\n```vega-lite\n"))
        let block = try #require(await pipeline.blocksSnapshot().first { $0.vegaLiteChart != nil })
        let model = try #require(controller.hostedVectorModel(for: block.id))
        let attachment = try #require(controller.hostedAttachment(for: block.id))
        let storage = try #require(view.textStorage)
        let initialStorage = storage.string
        var cursor = source.startIndex
        var delivered = ""
        for length in [137, 509, 4_096] {
            let end = source.index(cursor, offsetBy: length)
            let chunk = String(source[cursor..<end])
            delivered += chunk
            cursor = end
            applyUpdate(await pipeline.feed(chunk))
            #expect(model.source == delivered)
            #expect(model.source.utf8.count == delivered.utf8.count)
            #expect(model.parseCount == 0 && model.isLoading && !model.isClosed)
            let partial = try #require(await pipeline.blocksSnapshot().first { $0.id == block.id })
            #expect(partial.vegaLiteChart?.svg == "", "The compiler must not run on an incomplete official specification")
            #expect(storage.string == initialStorage)
            #expect(!storage.string.contains("Stacked Bar Chart"))
        }
        applyUpdate(await pipeline.feed(String(source[cursor...])))
        #expect(model.source == source && model.parseCount == 0 && model.isLoading)
        #expect(controller.hostedAttachment(for: block.id) === attachment)
        applyUpdate(await pipeline.feed("```\n\n#### Stacked Bar Chart\n\nFollowing text has arrived.\n\n"))
        applyUpdate(await pipeline.finish())
        await settle(view)
        let ready = try #require(await pipeline.blocksSnapshot().first { $0.id == block.id })
        let chart = try #require(ready.vegaLiteChart)
        #expect(ready.snapshot.isClosed && !chart.svg.isEmpty)
        #expect(chart.source == source)
        #expect(model.isClosed && model.isRenderable && !model.isLoading)
        #expect(model.parseCount == 1)
        #expect(controller.hostedAttachment(for: block.id) === attachment)
        #expect(storage.string.contains("Stacked Bar Chart"))
        #expect(storage.string.contains("Following text has arrived."))
        #expect(!storage.string.contains("Miles_per_Gallon"), "Inline dataset source stays out of visible native text")
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let copied = copySelection(view)
        let copiedExactSource = copied.contains(source)
        let copiedFollowingHeading = copied.contains("Stacked Bar Chart")
        #expect(copiedExactSource)
        #expect(copiedFollowingHeading)
    }

    @Test("A lazy controller-hosted loader keeps real status text during source-only streaming")
    func realWindowPreservesEstimatedLoadingHeight() async throws {
        _ = NSApplication.shared
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        controller.setHostedStreamActive(true)
        defer { controller.setHostedStreamActive(false) }
        let pipeline = MarkdownStreamingPipeline()
        func applyUpdate(_ update: StreamingUpdate?) {
            guard let update else { return }
            controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                              replaceToken: 1, configuration: .default(), documentIdentity: 1)
        }
        let prefix = String(repeating: "Native paragraph before the loading chart.\n\n", count: 20)
        applyUpdate(await pipeline.feed(prefix + "```vega-lite\n"))
        let block = try #require(await pipeline.blocksSnapshot().first { $0.vegaLiteChart != nil })
        let attachment = try #require(controller.hostedAttachment(for: block.id))
        let model = try #require(controller.hostedVectorModel(for: block.id))
        #expect(attachment.hostingView == nil)
        #expect(attachment.bounds.height == 48)
        let scroll = NSScrollView(frame: view.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.appearance = NSAppearance(named: .aqua)
        let screenOrigin = NSScreen.main?.visibleFrame.origin ?? .zero
        window.setFrameOrigin(NSPoint(x: screenOrigin.x + 20, y: screenOrigin.y + 20))
        window.orderFront(nil)
        defer { window.close() }
        view.setFrameSize(NSSize(width: 400, height: 2_000))
        await settle(view)
        let storage = try #require(view.textStorage)
        let marker = (storage.string as NSString).range(of: "\u{FFFC}")
        let manager = try #require(view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: marker.location))
        let beforeScroll = try #require(manager.textLayoutFragment(for: location))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, beforeScroll.layoutFragmentFrame.minY - 8)))
        scroll.reflectScrolledClipView(scroll.contentView)
        await model.waitForLoadingDelay()
        try await waitForNativeUpdate(in: scroll, window: window) {
            attachment.hostingView?.window === window
        }
        #expect(view.window === window && window.isVisible)
        let fragment = try #require(manager.textLayoutFragment(for: location))
        try #require(fragment.layoutFragmentFrame.intersects(view.visibleRect), "The loading marker must actually be in the native viewport")
        let host = try #require(attachment.hostingView, "TextKit must create the visible host without manual view loading")
        #expect(host.accessibilityLabel() == "Receiving chart…")
        #expect(host.accessibilityRole() == .staticText)
        #expect(host.isAccessibilityElement())
        try await expectLoadingTextPainted(in: host)

        let (progress, continuation) = AsyncStream<Int>.makeStream()
        let producer = Task { @MainActor in
            defer { continuation.finish() }
            for index in 1...30 {
                try Task.checkCancellation()
                applyUpdate(await pipeline.feed(" \"token\(index)\":\(index),"))
                continuation.yield(index)
                try await Task.sleep(for: .milliseconds(33))
            }
        }
        defer { producer.cancel() }
        for await index in progress where [1, 15, 30].contains(index) {
            await settle(view)
            #expect(controller.hostedAttachment(for: block.id) === attachment)
            #expect(controller.hostedVectorModel(for: block.id) === model)
            #expect(attachment.hostingView === host && host.window === window)
            #expect(!host.isHiddenOrHasHiddenAncestor)
            try await expectLoadingTextPainted(in: host)
        }
        try await producer.value
        #expect(model.source.contains("token30"))
        #expect(!storage.string.contains("token30"))
        #expect(attachment.measuredSize.height == 48)
        #expect(model.parseCount == 0)
    }

    @Test("A streamed loader draws inside an outer SwiftUI scroll view while source keeps arriving")
    func swiftUIScrollViewKeepsNativeLoadingStatusVisible() async throws {
        _ = NSApplication.shared
        let (stream, continuation) = AsyncStream<String>.makeStream()
        defer { continuation.finish() }
        let outer = NSHostingView(rootView: ScrollView {
            PicoMarkdownView(stream: { stream }, remoteImagesEnabled: false)
                .textSelection(.enabled)
                .padding(16)
        })
        outer.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: outer.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = outer
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        window.orderFront(nil)
        defer { window.close() }
        continuation.yield("Before the streaming chart.\n\n```vega-lite\n{\"usermeta\":{")
        try await waitForNativeUpdate(in: outer, window: window) {
            guard let view = self.firstDescendant(StreamingTextKit2View.self, in: outer) else { return false }
            return self.firstHostedAttachment(in: view) != nil
        }
        let view = try #require(firstDescendant(StreamingTextKit2View.self, in: outer))
        let attachment = try #require(firstHostedAttachment(in: view))
        try await waitForNativeUpdate(in: outer, window: window) {
            attachment.hostingView?.accessibilityLabel() != nil
        }
        let host = try #require(attachment.hostingView, "The SwiftUI scroll viewport must mount TextKit's attachment automatically")
        let storage = try #require(view.textStorage)
        let marker = (storage.string as NSString).range(of: "\u{FFFC}")
        let manager = try #require(view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: marker.location))
        let fragment = try #require(manager.textLayoutFragment(for: location))
        #expect(fragment.layoutFragmentFrame.intersects(view.visibleRect))
        #expect(host.window === window && !host.isHiddenOrHasHiddenAncestor)
        #expect(host.visibleRect.width > 0 && host.visibleRect.height > 0)
        #expect(host.accessibilityRole() == .staticText)
        #expect(host.isAccessibilityElement())
        try await expectLoadingTextPainted(in: host)
        let originalStorage = storage.string
        let (progress, updates) = AsyncStream<Int>.makeStream()
        let producer = Task { @MainActor in
            defer { updates.finish() }
            for index in 1...30 {
                try Task.checkCancellation()
                continuation.yield("\"token\(index)\":\(index),")
                updates.yield(index)
                try await Task.sleep(for: .milliseconds(33))
            }
        }
        defer { producer.cancel() }
        for await index in progress where [1, 15, 30].contains(index) {
            try await waitForNativeUpdate(in: outer, window: window) {
                attachment.markdownRepresentation().contains("\"token\(index)\":")
            }
            #expect(firstHostedAttachment(in: view) === attachment)
            #expect(attachment.hostingView === host && host.window === window)
            #expect(!host.isHiddenOrHasHiddenAncestor)
            #expect(host.accessibilityLabel() == "Receiving chart…")
            #expect(attachment.measuredSize.height == 48)
            #expect(storage.string == originalStorage)
            try await expectLoadingTextPainted(in: host)
        }
        try await producer.value
        #expect(attachment.markdownRepresentation().contains("\"token30\":30,"))
    }

    @Test("Loading paint verification rejects blank and indicator-only rows")
    func loadingPaintCheckRequiresStatusGlyphs() async throws {
        let blank = try await loadingPaintFixture(Color.clear)
        let indicatorOnly = try await loadingPaintFixture(
            PicoHostedLoadingView(activity: .receiving, isSelected: false) { EmptyView() })
        let withText = try await loadingPaintFixture(
            PicoHostedLoadingView(activity: .receiving, isSelected: false) { Text("Receiving chart…") })
        let size = CGSize(width: 400, height: 48)
        #expect(try loadingLabelInk(in: blank, logicalSize: size).pixels == 0)
        #expect(try loadingLabelInk(in: indicatorOnly, logicalSize: size).pixels == 0,
                "The loading card and its indicator must not satisfy the text-paint check")
        let textInk = try loadingLabelInk(in: withText, logicalSize: size)
        #expect(textInk.pixels >= 16 && textInk.width >= 40)
    }

    private func loadingPaintFixture<Content: View>(_ content: Content) async throws -> Data {
        let host = NSHostingView(rootView: content.frame(width: 400, height: 48)
            .environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 48)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.orderFront(nil)
        defer { window.close() }
        await layout(host, window: window)
        return try snapshot(host)
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

    private func officialGroupedRepeatSource() throws -> String {
        struct Manifest: Decodable {
            struct Entry: Decodable {
                let id: String
                let fenceIndex: Int?
                let sourceSHA256: String
            }
            let entries: [Entry]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf:
            root.appendingPathComponent("Tests/Fixtures/VegaLiteGallery/preview-manifest.json")))
        let entry = try #require(manifest.entries.first { $0.id == "bar_grouped_repeated" })
        let fenceIndex = try #require(entry.fenceIndex)
        let compressed = try Data(contentsOf: root.appendingPathComponent(
            "MarkdownExample/MarkdownExample/markdown files/Charts-Gallery-Preview.md.deflate"))
        let decoded = try (compressed as NSData).decompressed(using: .zlib) as Data
        let markdown = String(decoding: decoded, as: UTF8.self)
        var cursor = markdown.startIndex
        for index in 0...fenceIndex {
            let opening = try #require(markdown.range(of: "```vega-lite\n", range: cursor..<markdown.endIndex))
            let closing = try #require(markdown.range(of: "\n```\n", range: opening.upperBound..<markdown.endIndex))
            if index == fenceIndex {
                let source = String(markdown[opening.upperBound...closing.lowerBound])
                let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
                try #require(digest == entry.sourceSHA256, "Use the exact official source, with every inline data row")
                return source
            }
            cursor = closing.upperBound
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private func firstDescendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { firstDescendant(type, in: $0) }.first
    }

    private func firstHostedAttachment(in view: NSTextView) -> PicoHostedAttachment? {
        guard let storage = view.textStorage else { return nil }
        var attachment: PicoHostedAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let hosted = value as? PicoHostedAttachment else { return }
            attachment = hosted
            stop.pointee = true
        }
        return attachment
    }

    private func waitForNativeUpdate(in outer: NSView, window: NSWindow,
                                     condition: () -> Bool) async throws {
        // TextKit mounts attachment views asynchronously after viewport layout.
        // Await native readiness under the test's time limit, not a fixed number
        // of yields or an independent wall-clock deadline.
        while !condition() {
            try Task.checkCancellation()
            await layout(outer, window: window)
            if let view = firstDescendant(StreamingTextKit2View.self, in: outer) { await settle(view) }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        try Task.checkCancellation()
        await layout(outer, window: window)
    }

    private func markerCount(_ storage: NSTextStorage) -> Int { storage.string.filter { $0 == "\u{FFFC}" }.count }

    private func copySelection(_ view: NSTextView) -> String {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        return pasteboard.string(forType: .string) ?? ""
    }

    private func snapshot(_ view: NSView) throws -> Data {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func expectLoadingTextPainted(in host: NSView,
                                          sourceLocation: SourceLocation = #_sourceLocation) async throws {
        #expect(host.accessibilityLabel() == "Receiving chart…", sourceLocation: sourceLocation)
        let png = try snapshot(host)
        let ink = try loadingLabelInk(in: png, logicalSize: host.bounds.size)
        #expect(ink.pixels >= 16 && ink.width >= 40,
                "The mounted loading label painted \(ink.pixels) dark pixels over \(ink.width) points", sourceLocation: sourceLocation)
        // Vision may lack a working inference backend on headless CI. Keep
        // exact OCR available for local window verification without hiding errors.
        if ProcessInfo.processInfo.environment["PICO_VERIFY_CHART_LOADING_OCR"] == "1" {
            let text = try await Self.recognizedText(in: png)
            #expect(text.lowercased().contains("receiving chart"), "Native loading OCR: \(text)", sourceLocation: sourceLocation)
        }
    }

    private func loadingLabelInk(in png: Data, logicalSize: CGSize) throws -> (pixels: Int, width: CGFloat) {
        let bitmap = try #require(NSBitmapImageRep(data: png))
        try #require(logicalSize.width > 52 && logicalSize.height > 16)
        let scaleX = CGFloat(bitmap.pixelsWide) / logicalSize.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / logicalSize.height
        // Exclude the indicator at the left and the faint card background.
        // Sample the text band in logical points, independent of Retina scale.
        let left = Int(40 * scaleX)
        let right = Int(min(240, logicalSize.width - 12) * scaleX)
        let bottom = Int(8 * scaleY)
        let top = Int((logicalSize.height - 8) * scaleY)
        var ink = 0
        var firstColumn = right
        var lastColumn = left
        for y in bottom..<top {
            for x in left..<right {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let alpha = color.alphaComponent
                let darkest = max(color.redComponent, color.greenComponent, color.blueComponent) * alpha + (1 - alpha)
                if darkest < 0.7 {
                    ink += 1
                    firstColumn = min(firstColumn, x)
                    lastColumn = max(lastColumn, x)
                }
            }
        }
        return (ink, ink == 0 ? 0 : CGFloat(lastColumn - firstColumn + 1) / scaleX)
    }

    @concurrent
    private static func recognizedText(in png: Data) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Hosted bitmaps are transparent; composite them before OCR so dark
        // status glyphs cannot disappear against an implicit black background.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let opaque = try #require(context.makeImage())
        try VNImageRequestHandler(cgImage: opaque, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func layout(_ host: NSView, window: NSWindow) async {
        for _ in 0..<6 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
        }
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
