#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PicoMarkdownView

@Suite("Progressive standalone image presentation", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MacProgressiveImageTests {
    @Test("Preview frames and the final image reuse the visible host without character edits or scrolling",
          arguments: [true, false])
    func visibleFramesRetainIdentitySelectionAndSource(deliverBeforeLayout: Bool) async throws {
        _ = NSApplication.shared
        let firstFrame = preview(.systemRed, pixels: CGSize(width: 120, height: 45))
        let provider = ControlledProgressiveImageProvider(initialPreview: deliverBeforeLayout ? firstFrame : nil)
        let outer = NSHostingView(rootView: ScrollView {
            PicoMarkdownView(document, imageProvider: provider, remoteImagesEnabled: false).padding(16)
        })
        outer.frame = CGRect(x: 0, y: 0, width: 368, height: 620)
        let window = NSWindow(contentRect: outer.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = outer
        window.level = .floating
        window.orderFront(nil)
        defer { window.close() }
        outer.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await observe("initial prose before preview delivery") { textView(in: outer)?.string.contains("After image.") == true }
        let text = try #require(textView(in: outer))
        let storage = try #require(text.textStorage)
        await provider.waitForRequest(url)
        if !deliverBeforeLayout {
            #expect(hostedAttachments(in: storage).isEmpty)
            await provider.emit(firstFrame, for: url)
        }

        // The early case emits from the prefetch request itself, before the
        // canonical document's first viewport pass. Both timings use native
        // events alone after the initial empty-window bootstrap above.
        try await observe("first preview native mounting and presentation", diagnostics: {
            presentationState(window: window, outer: outer, text: text, storage: storage)
        }) {
            guard let attachment = hostedAttachments(in: storage).first,
                  let host = attachment.hostingView, let canvas = canvas(in: host) else { return false }
            return host.window === window && canvas.window === window && !canvas.isHiddenOrHasHiddenAncestor
                && canvas.visibleRect.height > 0 && canvas.bounds.width > 100 && !canvas.needsDisplay
        }
        let attachment = try #require(hostedAttachments(in: storage).first)
        let host = try #require(attachment.hostingView)
        let canvas = try #require(canvas(in: host))
        let model = canvas.model
        #expect(try centerColor(of: model).redComponent > 0.7)
        let initialText = storage.string
        text.setSelectedRange(NSRange(location: 0, length: storage.length))
        let selection = text.selectedRange()
        let characterEdits = CharacterEditCounter(storage: storage)
        let token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
            object: storage, queue: .main) { _ in
                MainActor.assumeIsolated {
                    characterEdits.recordEditing()
                }
            }
        defer { NotificationCenter.default.removeObserver(token) }

        for color in [NSColor.systemBlue, .systemOrange] {
            let revision = model.presentationRevision
            await provider.emit(preview(color, pixels: CGSize(width: 240, height: 90)), for: url)
            try await observe("subsequent preview native presentation") { model.presentationRevision > revision && !canvas.needsDisplay }
            #expect(hostedAttachments(in: storage).first === attachment)
            #expect(attachment.hostingView === host)
            #expect(self.canvas(in: host) === canvas && canvas.model === model)
            #expect(storage.string == initialText && text.selectedRange() == selection)
            #expect(abs(attachment.measuredSize.width / attachment.measuredSize.height - 480.0 / 180) < 0.01)
            #expect(abs(canvas.bounds.width / canvas.bounds.height - 480.0 / 180) < 0.01)
        }
        #expect(characterEdits.count == 0, "Later preview frames update only the retained image model")

        let revision = model.presentationRevision
        await provider.finish(url, with: preview(.systemGreen, pixels: CGSize(width: 480, height: 180)))
        try await observe("final image native presentation") { model.presentationRevision > revision && !canvas.needsDisplay }
        #expect(try centerColor(of: model).greenComponent > 0.5)
        #expect(hostedAttachments(in: storage).first === attachment)
        #expect(attachment.hostingView === host && self.canvas(in: host) === canvas && canvas.model === model)
        #expect(storage.string == initialText && text.selectedRange() == selection)
        #expect(attachment.markdownRepresentation() == imageMarkdown)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(text.writeSelection(to: pasteboard, types: [.string]))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.components(separatedBy: imageMarkdown).count == 2)
        #expect(copied.contains("Before image.") && copied.contains("After image."))
        #expect(!copied.contains("\u{FFFC}"))
    }

    @Test("A failed final download removes the provisional image and keeps canonical alt text")
    func failedFinalReturnsToAlt() async throws {
        let provider = ControlledProgressiveImageProvider()
        let model = MarkdownStreamingViewModel(imageProvider: provider)
        await model.consume(.text(document))
        try await observe { model.blocks.contains { !$0.images.isEmpty } }
        await provider.waitForRequest(url)
        let (controller, text) = makeTextView()
        sync(model, controller: controller, text: text)
        let canonical = model.blocks
        await provider.emit(preview(.systemRed), for: url)
        try await observe { model.imagePreviews[url] != nil }
        sync(model, controller: controller, text: text)
        #expect(hostedAttachments(in: try #require(text.textStorage)).count == 1)
        #expect(model.blocks == canonical, "Preview delivery does not rewrite canonical rendered blocks")

        await provider.finish(url, with: nil)
        try await observe { model.imagePreviews[url] == nil }
        sync(model, controller: controller, text: text)
        #expect(hostedAttachments(in: try #require(text.textStorage)).isEmpty)
        #expect(text.string.contains("figure") && text.string.contains("Before image.") && text.string.contains("After image."))
        #expect(model.blocks == canonical)
    }

    @Test("Replacement rejects callbacks from an older request even when the URL is reused")
    func replacementRejectsStalePreview() async throws {
        let provider = ControlledProgressiveImageProvider()
        let model = MarkdownStreamingViewModel(imageProvider: provider)
        await model.consume(.text(document))
        await provider.waitForRequest(url)
        await provider.emit(preview(.systemRed), for: url, request: 0)
        try await observe { model.imagePreviews[url] != nil }
        let oldRevision = try #require(model.imagePreviews[url]?.revision)

        await model.consume(.text("Replacement before.\n\n" + imageMarkdown + "\n\nReplacement after.\n\n"))
        await provider.waitForRequest(url, count: 2)
        try await observe { model.blocks.contains { String($0.content.characters).contains("Replacement after.") } }
        #expect(model.imagePreviews.isEmpty)
        await provider.emit(preview(.systemRed), for: url, request: 0)
        await provider.emit(preview(.systemBlue), for: url, request: 1)
        try await observe { model.imagePreviews[url] != nil }
        let current = try #require(model.imagePreviews[url])
        #expect(current.revision != oldRevision)
        #expect(try centerColor(of: current.result).blueComponent > 0.7)
        #expect(model.blocks.allSatisfy { !String($0.content.characters).contains("Before image.") })
        await provider.finish(url, with: nil)
        try await observe { model.imagePreviews.isEmpty }
    }

    @Test("Inline, heading, table and open-paragraph images never install provisional media hosts",
          arguments: ["inline", "heading", "table", "open"])
    func onlyClosedStandaloneImagesPreview(kind: String) async throws {
        let markdown: String
        switch kind {
        case "inline": markdown = "Prefix " + imageMarkdown + " suffix.\n\n"
        case "heading": markdown = "# " + imageMarkdown + "\n\n"
        case "table": markdown = "| Image |\n| --- |\n| " + imageMarkdown + " |\n\n"
        default: markdown = imageMarkdown + "\n"
        }
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed(markdown)
        let blocks = await pipeline.blocksSnapshot()
        let (controller, text) = makeTextView()
        controller.update(textView: text, blocks: blocks, diffs: [], replaceToken: 1,
                          configuration: .default(), documentIdentity: 1)
        let before = text.string
        let storage = try #require(text.textStorage)
        let priorHosts = hostedAttachments(in: storage)
        controller.receiveImagePreview(url: url, preview: MarkdownImagePreview(result: preview(.systemRed)), documentIdentity: 1)
        #expect(text.string == before)
        #expect(hostedAttachments(in: storage).map(\.hostedContentID) == priorHosts.map(\.hostedContentID))
        #expect(hostedAttachments(in: storage).allSatisfy { $0.markdownRepresentation() != imageMarkdown })
    }

    @Test("Paused presentation buffers preview frames and resumes with the latest frame")
    func pauseKeepsCurrentFrameUntilResume() async throws {
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed(document)
        _ = await pipeline.finish()
        let blocks = await pipeline.blocksSnapshot()
        let (controller, text) = makeTextView()
        controller.update(textView: text, blocks: blocks, diffs: [], replaceToken: 1,
                          configuration: .default(), documentIdentity: 1)
        controller.receiveImagePreview(url: url, preview: MarkdownImagePreview(result: preview(.systemRed)), documentIdentity: 1)
        let storage = try #require(text.textStorage)
        let attachment = try #require(hostedAttachments(in: storage).first)
        let host = attachment.loadHostedView()
        host.layoutSubtreeIfNeeded()
        let model = try #require(canvas(in: host)?.model)
        let revision = model.presentationRevision
        let before = storage.string
        text.setSelectedRange(NSRange(location: 0, length: storage.length))
        let selection = text.selectedRange()
        var paused = PicoTextKitConfiguration.default()
        paused.isPaused = true
        controller.update(textView: text, blocks: blocks, diffs: [], replaceToken: 1,
                          configuration: paused, documentIdentity: 1)
        controller.receiveImagePreview(url: url, preview: MarkdownImagePreview(result: preview(.systemBlue)), documentIdentity: 1)
        let latest = MarkdownImagePreview(result: preview(.systemGreen))
        controller.receiveImagePreview(url: url, preview: latest, documentIdentity: 1)
        #expect(model.presentationRevision == revision)
        #expect(try centerColor(of: model).redComponent > 0.7)
        #expect(storage.string == before && text.selectedRange() == selection)

        controller.update(textView: text, blocks: blocks, diffs: [], replaceToken: 1,
                          configuration: .default(), documentIdentity: 1)
        #expect(model.presentationRevision > revision)
        #expect(try centerColor(of: model).greenComponent > 0.5)
        #expect(hostedAttachments(in: storage).first === attachment && attachment.hostingView === host)
        #expect(storage.string == before && text.selectedRange() == selection)
    }

    @Test("An opt-out provider keeps final-only prefetch delivery")
    func disabledProviderKeepsExistingPath() async throws {
        let provider = ControlledProgressiveImageProvider(enabled: false)
        let model = MarkdownStreamingViewModel(imageProvider: provider)
        await model.consume(.text(document))
        await provider.waitForRequest(url)
        #expect(await provider.progressiveRequestCount == 0)
        #expect(await provider.finalOnlyRequestCount == 1)
        #expect(model.imagePreviews.isEmpty)
        await provider.finish(url, with: preview(.systemGreen))
        try await observe { model.blocks.contains { String($0.content.characters).contains("\u{FFFC}") } }
        #expect(model.imagePreviews.isEmpty)
    }

    @Test("A paused document replacement retains its pending preview until the new document is applied",
          arguments: [false, true])
    func pausedDocumentReplacementKeepsNewPreview(identicalSource: Bool) async throws {
        let oldPipeline = MarkdownStreamingPipeline()
        _ = await oldPipeline.feed("Old document.\n\n" + imageMarkdown + "\n\n")
        _ = await oldPipeline.finish()
        let oldBlocks = await oldPipeline.blocksSnapshot()
        let newPipeline = MarkdownStreamingPipeline()
        _ = await newPipeline.feed("New document.\n\n" + imageMarkdown + "\n\nNew tail.\n\n")
        _ = await newPipeline.finish()
        let newBlocks = identicalSource ? oldBlocks : await newPipeline.blocksSnapshot()
        let (controller, text) = makeTextView()
        controller.update(textView: text, blocks: oldBlocks, diffs: [], replaceToken: 1,
                          configuration: .default(), documentIdentity: 1)
        controller.receiveImagePreview(url: url, preview: MarkdownImagePreview(result: preview(.systemRed)), documentIdentity: 1)
        let storage = try #require(text.textStorage)
        let oldAttachment = try #require(hostedAttachments(in: storage).first)
        let oldText = storage.string
        var paused = PicoTextKitConfiguration.default()
        paused.isPaused = true
        controller.update(textView: text, blocks: newBlocks, diffs: [], replaceToken: 2,
                          configuration: paused, documentIdentity: 2)
        controller.receiveImagePreview(url: url, preview: MarkdownImagePreview(result: preview(.systemBlue)), documentIdentity: 2)
        controller.receiveImagePreview(url: url, preview: MarkdownImagePreview(result: preview(.systemGreen)), documentIdentity: 2)
        #expect(storage.string == oldText)
        #expect(hostedAttachments(in: storage).first === oldAttachment)

        // Only canonical resume is delivered; the caller does not replay any
        // preview after the backend resets the old document's records.
        controller.update(textView: text, blocks: newBlocks, diffs: [], replaceToken: 2,
                          configuration: .default(), documentIdentity: 2)
        let attachment = try #require(hostedAttachments(in: storage).first)
        #expect(attachment !== oldAttachment)
        let host = attachment.loadHostedView()
        host.layoutSubtreeIfNeeded()
        let model = try #require(canvas(in: host)?.model)
        #expect(try centerColor(of: model).greenComponent > 0.5)
        if identicalSource {
            #expect(storage.string == oldText, "Identical source still starts a new document identity")
        } else {
            #expect(storage.string.contains("New document.") && storage.string.contains("New tail."))
            #expect(!storage.string.contains("Old document."))
        }
        #expect(attachment.markdownRepresentation() == imageMarkdown)
    }

    @Test("A large offscreen preview reserves its aspect-correct height without creating its host")
    func offscreenPreviewReservesScaledGeometry() async throws {
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed(String(repeating: "Earlier native paragraph.\n\n", count: 60) + document)
        _ = await pipeline.finish()
        let blocks = await pipeline.blocksSnapshot()
        let (controller, text) = makeTextView()
        controller.update(textView: text, blocks: blocks, diffs: [], replaceToken: 1,
                          configuration: .default(), documentIdentity: 1)
        var frame = preview(.systemRed, pixels: CGSize(width: 384, height: 192))
        frame.size = CGSize(width: 1536, height: 768)
        controller.receiveImagePreview(url: url, preview: MarkdownImagePreview(result: frame), documentIdentity: 1)
        let storage = try #require(text.textStorage)
        let attachment = try #require(hostedAttachments(in: storage).first)
        #expect(attachment.hostingView == nil)
        text.layoutSubtreeIfNeeded()
        #expect(attachment.hostingView == nil, "Reserving offscreen geometry must not mount the media view")
        #expect(attachment.measuredSize == CGSize(width: 336, height: 168))
        #expect(attachment.bounds.size == attachment.measuredSize)
        #expect(attachment.markdownRepresentation() == imageMarkdown)
    }

    @Test("A real progressive JPEG reaches the public view before its response completes")
    func realProviderPublishesPreviewAndFinalInSameHost() async throws {
        _ = NSApplication.shared
        let fixture = try ProgressiveImageFixture.jpeg.get()
        let transfer = ControlledProgressiveImageTransfer(fixture: fixture)
        defer { transfer.unregister() }
        let session = progressiveImageSession()
        defer { session.invalidateAndCancel() }
        let provider = URLSessionMarkdownImageProvider(session: session, progressiveJPEGPreviews: true)
        let markdown = "Before real image.\n\n![real](\(transfer.url.absoluteString))\n\nAfter real image.\n\n"
        let outer = NSHostingView(rootView: ScrollView {
            PicoMarkdownView(markdown, imageProvider: provider, remoteImagesEnabled: false).padding(16)
        })
        outer.frame = CGRect(x: 0, y: 0, width: 368, height: 620)
        let window = NSWindow(contentRect: outer.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = outer
        window.level = .floating
        window.orderFront(nil)
        defer { window.close() }
        outer.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await observe("initial prose before JPEG byte delivery") { textView(in: outer)?.string.contains("After real image.") == true }
        let text = try #require(textView(in: outer))
        let storage = try #require(text.textStorage)
        if let manager = text.textLayoutManager, let content = manager.textContentManager {
            manager.ensureLayout(for: content.documentRange)
            manager.textViewportLayoutController.layoutViewport()
        }
        text.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await transfer.waitForStart()

        // The response is gated halfway through a generated progressive JPEG.
        // No native layout, display or scroll request follows byte delivery.
        let split = fixture.data.count / 2
        await transfer.send(fixture.data.prefix(split))
        try await observe("real JPEG preview native mounting and presentation") {
            guard let attachment = hostedAttachments(in: storage).first,
                  let host = attachment.hostingView, let native = canvas(in: host) else { return false }
            return host.window === window && native.visibleRect.height > 0
                && abs(attachment.measuredSize.height - 168) < 1 && !native.needsDisplay
        }
        #expect(!transfer.hasCompleted)
        #expect(await provider.image(for: transfer.url) == nil)
        let attachment = try #require(hostedAttachments(in: storage).first)
        let host = try #require(attachment.hostingView)
        let native = try #require(canvas(in: host))
        let model = native.model
        let revision = model.presentationRevision
        let before = storage.string
        text.setSelectedRange(NSRange(location: 0, length: storage.length))
        let selection = text.selectedRange()
        await transfer.send(fixture.data.suffix(from: split))
        await transfer.finish()
        try await observe("real JPEG final native presentation") { model.presentationRevision > revision && !native.needsDisplay }
        let final = try #require(await provider.image(for: transfer.url))
        #expect(final.size == fixture.size && transfer.requestCount == 1)
        #expect(hostedAttachments(in: storage).first === attachment)
        #expect(attachment.hostingView === host && self.canvas(in: host) === native && native.model === model)
        #expect(storage.string == before && text.selectedRange() == selection)
        #expect(attachment.markdownRepresentation() == "![real](\(transfer.url.absoluteString))")
    }

    @Test("A partial callback delivered after failure cannot revive that request's preview")
    func latePartialAfterFailureStaysRemoved() async throws {
        let controlURL = URL(string: "https://example.invalid/control.jpg")!
        let provider = ControlledProgressiveImageProvider()
        let model = MarkdownStreamingViewModel(imageProvider: provider)
        await model.consume(.text(document + "\n![control](\(controlURL.absoluteString))\n\n"))
        await provider.waitForRequest(url)
        await provider.waitForRequest(controlURL)
        await provider.emit(preview(.systemRed), for: url)
        try await observe { model.imagePreviews[url] != nil }
        await provider.finish(url, with: nil)
        try await observe { model.imagePreviews[url] == nil }
        var delivered: [URL] = []
        model.onImagePreview = { url, preview, _ in
            if preview != nil { delivered.append(url) }
        }

        // The failed request intentionally retains its producer callback. A
        // separate active request provides a positive, event-driven delivery
        // checkpoint rather than assuming a fixed number of scheduler turns.
        await provider.emit(preview(.systemOrange), for: url)
        await provider.emit(preview(.systemBlue), for: controlURL)
        try await observe { delivered.contains(controlURL) }
        await provider.finish(controlURL, with: nil)
        try await observe { model.imagePreviews[controlURL] == nil }
        #expect(model.imagePreviews[url] == nil)
        #expect(!delivered.contains(url), "Failure seals this generation's request against queued or late partial frames")
        #expect(model.blocks.contains { String($0.content.characters).contains("After image.") })
    }

    @Test("First previews and final images preserve native list and quote containers",
          arguments: ["list", "quote", "nestedFirstChild"])
    func standaloneContainerMetadataSurvives(kind: String) async throws {
        let source: String
        switch kind {
        case "list": source = "- " + imageMarkdown + "\n\nAfter image.\n\n"
        case "quote": source = "> " + imageMarkdown + "\n\nAfter image.\n\n"
        default: source = "- Parent item\n  - > " + imageMarkdown + "\n\nAfter image.\n\n"
        }
        let provider = ControlledProgressiveImageProvider()
        let pipeline = MarkdownStreamingPipeline(imageProvider: provider)
        _ = await pipeline.feed(source)
        _ = await pipeline.finish()
        let blocks = await pipeline.blocksSnapshot()
        let imageBlock = try #require(blocks.first { !$0.images.isEmpty })
        let (controller, text) = makeTextView()
        controller.update(textView: text, blocks: blocks, diffs: [], replaceToken: 1,
                          configuration: .default(), documentIdentity: 1)
        controller.receiveImagePreview(url: url, preview: MarkdownImagePreview(result: preview(.systemRed)), documentIdentity: 1)
        let storage = try #require(text.textStorage)
        let attachment = try #require(hostedAttachments(in: storage).first)
        let host = attachment.loadHostedView()
        host.layoutSubtreeIfNeeded()
        let model = try #require(canvas(in: host)?.model)

        func checkContainer() throws {
            var marker: NSRange?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let value = value as? PicoHostedAttachment, value === attachment { marker = range }
            }
            let range = try #require(marker)
            let paragraph = try #require(storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
            #expect(paragraph.headIndent > 0)
            if kind != "quote" {
                let bullets = storage.string.components(separatedBy: "• ").count - 1
                #expect(bullets == (kind == "list" ? 1 : 2), "The first preview must retain the image item's native bullet")
            }
            if kind != "list" {
                #expect((storage.attribute(.picoBlockquoteLevel, at: range.location, effectiveRange: nil) as? Int ?? 0) > 0)
            } else {
                #expect(paragraph.headIndent > paragraph.firstLineHeadIndent)
            }
            #expect(attachment.markdownRepresentation() == imageMarkdown)
            text.setSelectedRange(NSRange(location: 0, length: storage.length))
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            #expect(text.writeSelection(to: pasteboard, types: [.string]))
            let copied = try #require(pasteboard.string(forType: .string))
            #expect(copied.components(separatedBy: imageMarkdown).count == 2)
            #expect(copied.contains("After image.") && !copied.contains("\u{FFFC}"))
            if kind == "nestedFirstChild" { #expect(copied.contains("Parent item")) }
        }
        try checkContainer()
        let previewText = storage.string
        let selection = text.selectedRange()
        await provider.finish(url, with: preview(.systemGreen, pixels: CGSize(width: 480, height: 180)))
        let final = try #require(await pipeline.refreshBlocks([imageBlock.id]))
        controller.update(textView: text, blocks: final.blocks, diffs: [final.diff], replaceToken: 1,
                          configuration: .default(), documentIdentity: 1)
        #expect(hostedAttachments(in: storage).first === attachment)
        #expect(attachment.hostingView === host && canvas(in: host)?.model === model)
        #expect(storage.string == previewText && text.selectedRange() == selection)
        #expect(try centerColor(of: model).greenComponent > 0.5)
        try checkContainer()
    }

    private let url = URL(string: "https://example.invalid/progressive.jpg")!
    private var imageMarkdown: String { "![figure](\(url.absoluteString))" }
    private var document: String { "Before image.\n\n" + imageMarkdown + "\n\nAfter image.\n\n" }

    private func preview(_ color: NSColor, pixels: CGSize = CGSize(width: 120, height: 45)) -> MarkdownImageResult {
        let image = NSImage(size: pixels, flipped: false) { bounds in color.setFill(); bounds.fill(); return true }
        return MarkdownImageResult(image: image, size: CGSize(width: 480, height: 180))
    }

    private func observe(_ phase: String = #function, diagnostics: (() -> String)? = nil,
                         until condition: () -> Bool) async throws {
        do {
            while !condition() {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
        } catch {
            Issue.record("Passive native events did not complete \(phase). \(diagnostics?() ?? "")")
            throw error
        }
    }

    private func presentationState(window: NSWindow, outer: NSView, text: NSTextView,
                                   storage: NSTextStorage) -> String {
        let currentText = textView(in: outer)
        let attachment = hostedAttachments(in: storage).first
        let host = attachment?.hostingView
        let native = host.flatMap { canvas(in: $0) }
        let viewport = text.textLayoutManager?.textViewportLayoutController
        var fragments: [String] = []
        if let manager = text.textLayoutManager {
            manager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
                guard fragment.state == .layoutAvailable else { return true }
                let paragraph = (fragment.textElement as? NSTextParagraph)?.attributedString.string.debugDescription ?? "nil"
                let providers = fragment.textAttachmentViewProviders.map { provider in
                    "\(type(of: provider)) sameAttachment=\(provider.textAttachment === attachment) sameManager=\(provider.textLayoutManager === manager)"
                }
                fragments.append("paragraph=\(paragraph) frame=\(fragment.layoutFragmentFrame) providers=\(providers)")
                return true
            }
        }
        return "window visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) level=\(window.level.rawValue) "
            + "textID=\(ObjectIdentifier(text)) storageID=\(ObjectIdentifier(storage)) "
            + "outer=\(outer.frame) text=\(text.frame)/\(text.bounds) visible=\(text.visibleRect) sameText=\(currentText === text) "
            + "text.needsLayout=\(text.needsLayout) text.needsDisplay=\(text.needsDisplay) viewportBounds=\(String(describing: viewport?.viewportBounds)) viewportRange=\(String(describing: viewport?.viewportRange)) "
            + "sameStorage=\(currentText?.textStorage === storage) textWindow=\(text.window === window) characters=\(storage.string.debugDescription) "
            + "attachment=\(String(describing: attachment?.measuredSize)) uses=\(String(describing: attachment?.usesTextAttachmentView)) allows=\(String(describing: attachment?.allowsTextAttachmentView)) contents=\(String(describing: attachment?.contents?.count)) fileType=\(String(describing: attachment?.fileType)) fragments=\(fragments) host.frame=\(String(describing: host?.frame)) "
            + "host.bounds=\(String(describing: host?.bounds)) host.window=\(host?.window === window) host.superview=\(host?.superview != nil) "
            + "host.visible=\(String(describing: host?.visibleRect)) host.hidden=\(String(describing: host?.isHiddenOrHasHiddenAncestor)) "
            + "canvas.frame=\(String(describing: native?.frame)) canvas.bounds=\(String(describing: native?.bounds)) "
            + "canvas.window=\(native?.window === window) canvas.hidden=\(String(describing: native?.isHiddenOrHasHiddenAncestor)) "
            + "canvas.visible=\(String(describing: native?.visibleRect)) canvas.dirty=\(String(describing: native?.needsDisplay)) "
            + "model.revision=\(String(describing: native?.model.presentationRevision)) renderable=\(String(describing: native?.model.isRenderable))"
    }

    private func textView(in view: NSView) -> StreamingTextKit2View? {
        if let text = view as? StreamingTextKit2View { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    private func canvas(in view: NSView) -> PicoHostedMediaCanvasView? {
        if let canvas = view as? PicoHostedMediaCanvasView { return canvas }
        return view.subviews.lazy.compactMap { canvas(in: $0) }.first
    }

    private func hostedAttachments(in storage: NSAttributedString) -> [PicoHostedAttachment] {
        var result: [PicoHostedAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { result.append(attachment) }
        }
        return result
    }

    private func makeTextView() -> (TextKitStreamingController, NSTextView) {
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = CGRect(x: 0, y: 0, width: 336, height: 620)
        return (controller, view)
    }

    private func sync(_ model: MarkdownStreamingViewModel, controller: TextKitStreamingController, text: NSTextView) {
        controller.update(textView: text, blocks: model.blocks, diffs: model.diffQueue,
                          replaceToken: model.replaceToken, configuration: .default(), documentIdentity: model.documentIdentity)
        controller.receiveImagePreview(url: url, preview: model.imagePreviews[url], documentIdentity: model.documentIdentity)
    }

    private func centerColor(of model: PicoHostedMediaModel) throws -> NSColor {
        try renderedCenter { context, bounds in model.draw(in: context, destination: bounds) }
    }

    private func centerColor(of result: MarkdownImageResult) throws -> NSColor {
        try renderedCenter { context, bounds in
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            result.image.draw(in: bounds)
        }
    }

    private func renderedCenter(_ draw: (CGContext, CGRect) -> Void) throws -> NSColor {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        draw(context.cgContext, CGRect(x: 0, y: 0, width: 32, height: 12))
        return try #require(bitmap.colorAt(x: 16, y: 6)?.usingColorSpace(.sRGB))
    }
}

@MainActor
private final class CharacterEditCounter {
    private weak var storage: NSTextStorage?
    var count = 0
    init(storage: NSTextStorage) { self.storage = storage }
    func recordEditing() {
        if storage?.editedMask.contains(.editedCharacters) == true { count += 1 }
    }
}

private actor ControlledProgressiveImageProvider: MarkdownProgressiveImagePrefetchingProvider {
    nonisolated let progressiveJPEGPreviewsEnabled: Bool
    private struct Request {
        var callback: (@Sendable (MarkdownImageResult) -> Void)?
        var continuation: AsyncStream<MarkdownImageResult?>.Continuation
    }
    private var requests: [URL: [Request]] = [:]
    private var requestWaiters: [URL: [UUID: AsyncStream<Void>.Continuation]] = [:]
    private var cache: [URL: MarkdownImageResult] = [:]
    private let initialPreview: MarkdownImageResult?
    private(set) var progressiveRequestCount = 0
    private(set) var finalOnlyRequestCount = 0

    init(enabled: Bool = true, initialPreview: MarkdownImageResult? = nil) {
        progressiveJPEGPreviewsEnabled = enabled
        self.initialPreview = initialPreview
    }
    func image(for url: URL) async -> MarkdownImageResult? { cache[url] }

    func prefetch(_ url: URL) async -> MarkdownImageResult? {
        finalOnlyRequestCount += 1
        return await deliver(url, callback: nil)
    }

    func prefetch(_ url: URL, onPreview: @escaping @Sendable (MarkdownImageResult) -> Void) async -> MarkdownImageResult? {
        progressiveRequestCount += 1
        return await deliver(url, callback: onPreview)
    }

    private func deliver(_ url: URL, callback: (@Sendable (MarkdownImageResult) -> Void)?) async -> MarkdownImageResult? {
        let (stream, continuation) = AsyncStream<MarkdownImageResult?>.makeStream()
        requests[url, default: []].append(Request(callback: callback, continuation: continuation))
        for waiter in requestWaiters[url, default: [:]].values { waiter.yield(()) }
        if let initialPreview { callback?(initialPreview) }
        for await result in stream { return result }
        return nil
    }

    func waitForRequest(_ url: URL, count: Int = 1) async {
        guard requests[url, default: []].count < count else { return }
        let id = UUID()
        let (events, continuation) = AsyncStream<Void>.makeStream()
        requestWaiters[url, default: [:]][id] = continuation
        defer {
            requestWaiters[url]?[id] = nil
            continuation.finish()
        }
        for await _ in events {
            if requests[url, default: []].count >= count { return }
        }
    }

    func emit(_ result: MarkdownImageResult, for url: URL, request: Int? = nil) {
        let entries = requests[url, default: []]
        if let request, entries.indices.contains(request) { entries[request].callback?(result) }
        else { entries.last?.callback?(result) }
    }

    func finish(_ url: URL, with result: MarkdownImageResult?) {
        if let result { cache[url] = result }
        for entry in requests[url, default: []] {
            entry.continuation.yield(result)
            entry.continuation.finish()
        }
    }
}
#endif
