#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS hosted file cards", .timeLimit(.minutes(1)))
@MainActor
struct MacHostedFileCardTests {
    private let reference = URL(string: "artifact://files/report")!
    private let markdown = "Before paragraph.\n\n[Report](artifact://files/report)\n\nAfter paragraph.\n\n"

    @Test("One registered standalone link becomes one attachment between native paragraphs")
    func standaloneLinkPromotesOnce() async throws {
        let file = makeFile()
        let fixture = await makeFixture(markdown: markdown, cards: [file])
        defer { fixture.window.close() }
        let storage = try #require(fixture.view.textStorage)
        let id = try await fileBlockID(in: fixture.pipeline)
        let attachment = try #require(fixture.backend.hostedAttachment(for: id))
        let model = try #require(fixture.backend.hostedFileCardModel(for: id))

        #expect(model.file === file)
        #expect(hostedAttachments(in: storage).count == 1)
        #expect(hostedAttachments(in: storage).first === attachment)
        #expect(storage.string.filter { $0 == "\u{FFFC}" }.count == 1)
        #expect(storage.string.contains("Before paragraph."))
        #expect(storage.string.contains("After paragraph."))
        #expect(!storage.string.contains("Report"))
        #expect(model.markdown == "[Report](artifact://files/report)")
        #expect(fixture.view.textLayoutManager != nil)
    }

    @Test("An open standalone link stays native until its paragraph closes")
    func openParagraphWaitsForClosure() async throws {
        let file = makeFile()
        let fixture = await makeFixture(markdown: "[Report](artifact://files/report)",
                                        cards: [file], finish: false)
        defer { fixture.window.close() }
        let storage = try #require(fixture.view.textStorage)
        #expect(hostedAttachments(in: storage).isEmpty)
        #expect(await fixture.pipeline.blocksSnapshot().allSatisfy { !$0.snapshot.isClosed })

        fixture.apply(await fixture.pipeline.feed("\n\nFollowing paragraph.\n\n"))

        let id = try await fileBlockID(in: fixture.pipeline)
        #expect(fixture.backend.hostedFileCardModel(for: id)?.file === file)
        #expect(hostedAttachments(in: storage).count == 1)
        #expect(storage.string.contains("Following paragraph."))
    }

    @Test("Inline links and unregistered file-looking URLs keep native link rendering", arguments: [
        "See [Report](artifact://files/report) in this paragraph.\n\n",
        "[First](artifact://files/report) [Second](artifact://files/report)\n\n",
        "[Manual](https://example.com/manual.pdf)\n\n",
        "[Other](artifact://files/unregistered)\n\n"
    ])
    func linksWithoutStandaloneRegistrationStayNative(_ source: String) async throws {
        let fixture = await makeFixture(markdown: source, cards: [makeFile()])
        defer { fixture.window.close() }
        let storage = try #require(fixture.view.textStorage)
        #expect(hostedAttachments(in: storage).isEmpty)
        #expect(!storage.string.contains("\u{FFFC}"))
        var links = 0
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { links += 1 }
        }
        #expect(links > 0)
    }

    @Test("Registered links in actual list and quote paragraph children stay native", arguments: [
        "1. Intro\n\n   [Report](artifact://files/report)\n\nAfter.\n\n",
        "> Intro\n>\n> [Report](artifact://files/report)\n\nAfter.\n\n"
    ])
    func nestedParagraphLinksStayNative(_ source: String) async throws {
        let fixture = await makeFixture(markdown: source, cards: [makeFile()])
        defer { fixture.window.close() }
        let storage = try #require(fixture.view.textStorage)
        let blocks = await fixture.pipeline.blocksSnapshot()
        let linkParagraph = try #require(blocks.first {
            $0.kind == .paragraph && $0.snapshot.inlineRuns?.contains {
                $0.linkURL == reference.absoluteString
            } == true
        })
        #expect(linkParagraph.snapshot.parentID != nil,
                "The fixture must exercise a paragraph child, not the list or quote's initial inline text")
        #expect(hostedAttachments(in: storage).isEmpty)
        #expect(!storage.string.contains("\u{FFFC}"))
        #expect(storage.string.contains("Report"))
        #expect(fixture.backend.hostedFileCardModel(for: linkParagraph.id) == nil)
    }

    @Test("Observed file updates do not edit the text document or restart streaming")
    func metadataUpdatesPreserveStorageSelectionAndParserState() async throws {
        let file = makeFile(state: .creating)
        let fixture = await makeFixture(markdown: markdown, cards: [file], finish: false) { _ in }
        defer { fixture.window.close() }
        let storage = try #require(fixture.view.textStorage)
        let id = try await fileBlockID(in: fixture.pipeline)
        let attachment = try #require(fixture.backend.hostedAttachment(for: id))
        let model = try #require(fixture.backend.hostedFileCardModel(for: id))
        var buttons = try await mountedButtons(for: attachment, in: fixture, enabled: false)
        #expect(buttons.allSatisfy { !$0.isEnabled })
        fixture.view.setSelectedRange(try markerRange(of: attachment, in: storage))
        let selection = fixture.view.selectedRange()
        let text = NSAttributedString(attributedString: storage)
        let blocks = await fixture.pipeline.blocksSnapshot()
        let host = attachment.loadHostedView()
        let delegate = storage.delegate
        let edits = StorageEdits(storage: storage)
        defer { edits.stop() }

        file.filename = "Completed report.md"
        file.typeDescription = "Markdown"
        file.byteCount = 4_096
        file.state = .ready
        buttons = try await mountedButtons(for: attachment, in: fixture, enabled: true)

        #expect(edits.ranges.isEmpty, "Metadata and availability update the hosted view, not NSTextStorage")
        #expect(fixture.view.textStorage === storage)
        #expect(storage.delegate === delegate, "The test must not replace the production storage delegate")
        #expect(storage.isEqual(to: text))
        #expect(fixture.view.selectedRange() == selection)
        #expect(fixture.backend.hostedAttachment(for: id) === attachment)
        #expect(fixture.backend.hostedFileCardModel(for: id) === model)
        #expect(attachment.loadHostedView() === host)
        #expect(await fixture.pipeline.blocksSnapshot() == blocks)
        #expect(model.file === file)
        #expect(model.file.filename == "Completed report.md")
        #expect(buttons.allSatisfy { $0.toolTip?.contains("Completed report.md") == true })

        fixture.apply(await fixture.pipeline.feed("Streaming continues after the card.\n\n"))
        #expect(fixture.backend.hostedAttachment(for: id) === attachment)
        #expect(fixture.backend.hostedFileCardModel(for: id) === model)
        #expect(storage.string.hasPrefix(text.string))
        #expect(storage.string.contains("Streaming continues after the card."))
    }

    @Test("Native controls request the correct ready artifact and background hits pass through")
    func nativeActionsRespectAvailabilityAndSelectionHitTesting() async throws {
        let file = makeFile(state: .creating)
        var actions: [PicoFileCardAction] = []
        let fixture = await makeFixture(markdown: markdown, cards: [file]) { actions.append($0) }
        defer { fixture.window.close() }
        let storage = try #require(fixture.view.textStorage)
        let id = try await fileBlockID(in: fixture.pipeline)
        let attachment = try #require(fixture.backend.hostedAttachment(for: id))
        var buttons = try await mountedButtons(for: attachment, in: fixture, enabled: false)
        let host = attachment.loadHostedView()
        #expect(Set(buttons.map(\.title)).count == 2)
        for button in buttons {
            #expect(!button.isEnabled)
            #expect(!(button.accessibilityLabel() ?? button.title).isEmpty)
            #expect(!(button.accessibilityHelp() ?? "").isEmpty)
            #expect(!(button.toolTip ?? "").isEmpty)
            sendAction(to: button)
        }
        #expect(actions.isEmpty)
        #expect(host.hitTest(host.convert(NSPoint(x: 8, y: host.bounds.midY), to: host.superview)) == nil)

        file.state = .ready
        buttons = try await mountedButtons(for: attachment, in: fixture, enabled: true)
        fixture.view.setSelectedRange(try markerRange(of: attachment, in: storage))
        let selection = fixture.view.selectedRange()
        for button in buttons {
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: host.superview)
            #expect(host.hitTest(point) === button)
            sendAction(to: button)
        }
        #expect(actions.count == 2)
        #expect(actions.contains { $0.kind == .preview })
        #expect(actions.contains { $0.kind == .download })
        #expect(actions.allSatisfy { $0.file === file })
        #expect(fixture.view.selectedRange() == selection)

        fixture.backend.setFileCards([file], actionHandler: nil)
        buttons = try await mountedButtons(for: attachment, in: fixture, enabled: false)
        for button in buttons { sendAction(to: button) }
        #expect(actions.count == 2, "A ready card without an app handler must not advertise active actions")
    }

    @Test("Copy exports canonical Markdown and preserves paragraph boundaries")
    func copyCardAndMixedSelectionRoundTrip() async throws {
        let fixture = await makeFixture(markdown: markdown, cards: [makeFile()])
        defer { fixture.window.close() }
        let storage = try #require(fixture.view.textStorage)
        let attachment = try #require(hostedAttachments(in: storage).first)
        fixture.view.setSelectedRange(try markerRange(of: attachment, in: storage))
        #expect(copySelection(from: fixture.view) == "[Report](artifact://files/report)")
        fixture.view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let copied = copySelection(from: fixture.view)
        #expect(copied.trimmingCharacters(in: .whitespacesAndNewlines) ==
                markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        for unwanted in ["\u{FFFC}", "Creating", "Ready", "Preview", "Download", "/private/", "/tmp/"] {
            #expect(!copied.contains(unwanted), "Copy leaked presentation content: \(unwanted)")
        }
        let roundTrip = MarkdownStreamingPipeline()
        _ = await roundTrip.feed(copied)
        _ = await roundTrip.finish()
        let paragraphs = await roundTrip.blocksSnapshot().filter { $0.kind == .paragraph }
        #expect(paragraphs.count == 3)
        #expect(paragraphs.map { $0.snapshot.inlineRuns?.map(\.text).joined() ?? "" } ==
                ["Before paragraph.", "Report", "After paragraph."])
    }

    @Test("Resize and text scaling retain the file occurrence and source identity")
    func resizingAndScalingKeepIdentity() async throws {
        let fixture = await makeFixture(markdown: markdown, cards: [makeFile()])
        defer { fixture.window.close() }
        let storage = try #require(fixture.view.textStorage)
        let id = try await fileBlockID(in: fixture.pipeline)
        let attachment = try #require(fixture.backend.hostedAttachment(for: id))
        let model = try #require(fixture.backend.hostedFileCardModel(for: id))
        _ = try await mountedButtons(for: attachment, in: fixture)
        let host = attachment.loadHostedView()
        let snapshots = await fixture.pipeline.blocksSnapshot().map(\.snapshot)
        let fontSize = model.bodyFontSize
        fixture.view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let selection = fixture.view.selectedRange()

        for width: CGFloat in [300, 800] {
            fixture.window.setContentSize(NSSize(width: width, height: 900))
            fixture.view.setFrameSize(NSSize(width: width, height: 900))
            fixture.layout()
            try await waitUntil(in: fixture) { abs(attachment.context.availableWidth - (width - 24)) <= 1 }
            #expect(fixture.backend.hostedAttachment(for: id) === attachment)
            #expect(fixture.backend.hostedFileCardModel(for: id) === model)
            #expect(attachment.loadHostedView() === host)
            #expect(fixture.view.selectedRange() == selection)
        }
        let scaled = try #require(await fixture.pipeline.updateTextScale(1.5))
        fixture.view.setSelectedRange(fixture.backend.apply(blocks: scaled, selection: selection))
        try await waitUntil(in: fixture) { model.bodyFontSize > fontSize }
        #expect(fixture.view.textStorage === storage)
        #expect(fixture.backend.hostedAttachment(for: id) === attachment)
        #expect(fixture.backend.hostedFileCardModel(for: id) === model)
        #expect(fixture.view.selectedRange() == selection)
        #expect(await fixture.pipeline.blocksSnapshot().map(\.snapshot) == snapshots)
        #expect(model.markdown == "[Report](artifact://files/report)")
    }

    @Test("Repeated links share an artifact but retain distinct attachment occurrences")
    func repeatedArtifactOccurrencesAreDistinct() async throws {
        let file = makeFile()
        let source = "[First copy](artifact://files/report)\n\nBetween.\n\n[Second copy](artifact://files/report)\n\n"
        let fixture = await makeFixture(markdown: source, cards: [file])
        defer { fixture.window.close() }
        let storage = try #require(fixture.view.textStorage)
        let ids = await fixture.pipeline.blocksSnapshot().filter {
            $0.snapshot.inlineRuns?.contains { $0.linkURL == reference.absoluteString } == true
        }.map(\.id)
        try #require(ids.count == 2)
        let first = try #require(fixture.backend.hostedAttachment(for: ids[0]))
        let second = try #require(fixture.backend.hostedAttachment(for: ids[1]))
        let firstModel = try #require(fixture.backend.hostedFileCardModel(for: ids[0]))
        let secondModel = try #require(fixture.backend.hostedFileCardModel(for: ids[1]))
        #expect(first !== second)
        #expect(firstModel !== secondModel)
        #expect(firstModel.file === file && secondModel.file === file)
        #expect(hostedAttachments(in: storage).count == 2)
        fixture.view.setSelectedRange(try markerRange(of: first, in: storage))
        #expect(copySelection(from: fixture.view) == "[First copy](artifact://files/report)")
        fixture.view.setSelectedRange(try markerRange(of: second, in: storage))
        #expect(copySelection(from: fixture.view) == "[Second copy](artifact://files/report)")
    }

    @Test("A reset rejects stale controls even when the new document reuses the block ID")
    func resetRejectsStaleActions() async throws {
        let original = makeFile()
        let replacement = PicoFileAttachment(id: "replacement", referenceURL: URL(string: "artifact://files/replacement")!,
                                             filename: "Replacement.md", state: .ready)
        var actions: [PicoFileCardAction] = []
        let fixture = await makeFixture(markdown: markdown, cards: [original, replacement]) { actions.append($0) }
        defer { fixture.window.close() }
        let oldID = try await fileBlockID(in: fixture.pipeline)
        let oldAttachment = try #require(fixture.backend.hostedAttachment(for: oldID))
        let oldModel = try #require(fixture.backend.hostedFileCardModel(for: oldID))
        let oldButtons = try await mountedButtons(for: oldAttachment, in: fixture, enabled: true)
        let next = MarkdownStreamingPipeline()
        _ = await next.feed("Before paragraph.\n\n[Replacement](artifact://files/replacement)\n\nAfter paragraph.\n\n")
        _ = await next.finish()
        let blocks = await next.blocksSnapshot()
        let newID = try #require(blocks.first { $0.snapshot.inlineRuns?.contains {
            $0.linkURL == replacement.referenceURL.absoluteString
        } == true }?.id)
        #expect(newID == oldID)
        fixture.backend.resetDocumentOnNextApply()
        fixture.view.setSelectedRange(fixture.backend.apply(blocks: blocks, selection: fixture.view.selectedRange()))

        oldModel.perform(.preview)
        oldModel.perform(.download)
        for button in oldButtons { sendAction(to: button) }
        #expect(actions.isEmpty)
        let newModel = try #require(fixture.backend.hostedFileCardModel(for: newID))
        #expect(newModel !== oldModel)
        #expect(newModel.file === replacement)
        newModel.perform(.preview)
        #expect(actions.count == 1)
        #expect(actions.first?.file === replacement)
    }

    @Test("Late membership changes patch the affected link and preserve another card")
    func membershipUpdatesStayLocalAndClampSelection() async throws {
        let first = makeFile()
        let otherURL = URL(string: "artifact://files/other")!
        let other = PicoFileAttachment(id: "other", referenceURL: otherURL, filename: "Other.md", state: .ready)
        let source = "Before.\n\n[Report](artifact://files/report)\n\nBetween.\n\n[Other](artifact://files/other)\n\nAfter.\n\n"
        let fixture = await makeFixture(markdown: source, cards: [other])
        defer { fixture.window.close() }
        let storage = try #require(fixture.view.textStorage)
        let blocks = await fixture.pipeline.blocksSnapshot()
        let firstID = try await fileBlockID(in: fixture.pipeline)
        let otherID = try #require(blocks.first { $0.snapshot.inlineRuns?.contains {
            $0.linkURL == otherURL.absoluteString
        } == true }?.id)
        let untouched = try #require(fixture.backend.hostedAttachment(for: otherID))
        #expect(fixture.backend.hostedAttachment(for: firstID) == nil)
        fixture.view.setSelectedRange(NSRange(location: max(0, storage.length - 6), length: min(6, storage.length)))
        let edits = StorageEdits(storage: storage)
        defer { edits.stop() }

        fixture.backend.setFileCards([first, other])
        fixture.view.setSelectedRange(fixture.backend.applyPendingFileCardUpdates(selection: fixture.view.selectedRange()))
        let promoted = try #require(fixture.backend.hostedAttachment(for: firstID))
        #expect(fixture.backend.hostedAttachment(for: otherID) === untouched)
        #expect(hostedAttachments(in: storage).count == 2)
        #expect(NSMaxRange(fixture.view.selectedRange()) <= storage.length)
        let otherMarker = try markerRange(of: untouched, in: storage)
        #expect(!edits.ranges.isEmpty)
        #expect(edits.ranges.allSatisfy { NSIntersectionRange($0, otherMarker).length == 0 })
        edits.ranges.removeAll()

        fixture.backend.setFileCards([other])
        fixture.view.setSelectedRange(fixture.backend.applyPendingFileCardUpdates(selection: fixture.view.selectedRange()))
        #expect(fixture.backend.hostedAttachment(for: firstID) == nil)
        #expect(fixture.backend.hostedAttachment(for: otherID) === untouched)
        #expect(hostedAttachments(in: storage).count == 1)
        #expect(!hostedAttachments(in: storage).contains { $0 === promoted })
        #expect(NSMaxRange(fixture.view.selectedRange()) <= storage.length)
        #expect(storage.string.contains("Report"))
        #expect(await fixture.pipeline.blocksSnapshot() == blocks)
    }

    private func makeFile(state: PicoFileAttachment.State = .ready) -> PicoFileAttachment {
        PicoFileAttachment(id: "report", referenceURL: reference, filename: "Report.md",
                           typeDescription: "Markdown", byteCount: 1_024, state: state)
    }

    private func fileBlockID(in pipeline: MarkdownStreamingPipeline) async throws -> BlockID {
        try #require(await pipeline.blocksSnapshot().first { $0.snapshot.inlineRuns?.contains {
            $0.linkURL == reference.absoluteString
        } == true }?.id)
    }

    private func makeFixture(markdown: String, cards: [PicoFileAttachment], finish: Bool = true,
                             actionHandler: (@MainActor (PicoFileCardAction) -> Void)? = nil) async -> Fixture {
        _ = NSApplication.shared
        let backend = TextKitStreamingBackend()
        backend.setFileCards(cards, actionHandler: actionHandler)
        let view = StreamingTextKit2View(backend: backend)
        view.frame = NSRect(x: 0, y: 0, width: 680, height: 900)
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.textContainer?.lineFragmentPadding = 0
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        let fixture = Fixture(backend: backend, view: view, window: window, pipeline: MarkdownStreamingPipeline())
        fixture.apply(await fixture.pipeline.feed(markdown))
        if finish { fixture.apply(await fixture.pipeline.finish()) }
        fixture.layout()
        return fixture
    }

    private func mountedButtons(for attachment: PicoHostedAttachment, in fixture: Fixture,
                                enabled: Bool? = nil) async throws -> [NSButton] {
        _ = attachment.loadHostedView()
        try await waitUntil(in: fixture) {
            guard let host = attachment.hostingView, host.isDescendant(of: fixture.view),
                  host.bounds.width > 0, host.bounds.height > 0 else { return false }
            let buttons = visibleButtons(in: host)
            return buttons.count == 2 && (enabled.map { state in buttons.allSatisfy { $0.isEnabled == state } } ?? true)
        }
        return visibleButtons(in: attachment.loadHostedView())
    }

    private func waitUntil(in fixture: Fixture, _ predicate: @MainActor () -> Bool) async throws {
        while true {
            try Task.checkCancellation()
            // SwiftUI defers native control updates in windows occluded by other tests.
            fixture.window.orderFront(nil)
            fixture.layout()
            if predicate() { return }
            // Poll actual native layout/state; the suite time limit catches a hang.
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func visibleButtons(in view: NSView) -> [NSButton] {
        guard !view.isHidden, view.alphaValue > 0 else { return [] }
        if let button = view as? NSButton, button.visibleRect.width > 0, button.visibleRect.height > 0 { return [button] }
        return view.subviews.flatMap { visibleButtons(in: $0) }
    }

    private func sendAction(to button: NSButton) {
        guard let selector = button.action else { Issue.record("Native file-card button has no action"); return }
        #expect(NSApp.sendAction(selector, to: button.target, from: button))
    }

    private func hostedAttachments(in storage: NSTextStorage) -> [PicoHostedAttachment] {
        var result: [PicoHostedAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { result.append(attachment) }
        }
        return result
    }

    private func markerRange(of attachment: PicoHostedAttachment, in storage: NSTextStorage) throws -> NSRange {
        var marker: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let candidate = value as? PicoHostedAttachment, candidate === attachment { marker = range }
        }
        return try #require(marker)
    }

    private func copySelection(from view: NSTextView) -> String {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        return pasteboard.string(forType: .string) ?? ""
    }

    @MainActor
    private final class Fixture {
        let backend: TextKitStreamingBackend
        let view: StreamingTextKit2View
        let window: NSWindow
        let pipeline: MarkdownStreamingPipeline

        init(backend: TextKitStreamingBackend, view: StreamingTextKit2View,
             window: NSWindow, pipeline: MarkdownStreamingPipeline) {
            self.backend = backend
            self.view = view
            self.window = window
            self.pipeline = pipeline
        }

        func apply(_ update: StreamingUpdate?) {
            guard let update else { return }
            view.setSelectedRange(backend.apply(blocks: update.blocks, diffs: [update.diff], selection: view.selectedRange()))
        }

        func layout() {
            backend.updateHostedAttachments(width: max(1, view.bounds.width - view.textContainerInset.width * 2),
                                            selection: [view.selectedRange()])
            if let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
            }
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    @MainActor
    private final class StorageEdits {
        var ranges: [NSRange] = []
        private var token: (any NSObjectProtocol)?

        init(storage: NSTextStorage) {
            token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                            object: storage, queue: nil) { [weak self] notification in
                let range = (notification.object as? NSTextStorage)?.editedRange
                MainActor.assumeIsolated {
                    if let range { self?.ranges.append(range) }
                }
            }
        }

        func stop() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
    }
}
#endif
