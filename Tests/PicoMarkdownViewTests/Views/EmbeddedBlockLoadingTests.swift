#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PicoMarkdownView

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EmbeddedBlockLoadingTests {
    @Test("Pending fenced source keeps one attachment and invokes its factory only on closure")
    func pendingFenceKeepsAttachmentAndLatestCopy() async throws {
        let recorder = LoadingFactoryRecorder()
        let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [recorder.renderer()])
        let backend = TextKitStreamingBackend()
        let open = try #require(await pipeline.feed("Before.\n\n```html-preview\n"))
        let block = try #require(open.blocks.first { $0.embeddedBlock != nil })
        #expect(block.embeddedBlock?.isClosed == false)
        #expect(!String(block.content.characters).contains("html-preview"))
        _ = backend.apply(blocks: open.blocks, diffs: [open.diff], selection: .init(location: 0, length: 0))
        let attachment = try #require(backend.hostedAttachment(for: block.id))
        let loading = try #require(backend.embeddedLoadingState(for: block.id))
        #expect(attachment.measuredSize.height == PicoEmbeddedLoadingState.height)
        #expect(recorder.contexts.isEmpty)
        #expect(loading.isLoading)

        let blockIndex = try #require(open.blocks.firstIndex { $0.id == block.id })
        let nativeRecord = try #require(backend.cachedAttributedString(forBlockAt: blockIndex))
        let append = try #require(await pipeline.feed("<div>Card"))
        _ = backend.apply(blocks: append.blocks, diffs: [append.diff], selection: .init(location: 0, length: 0))
        backend.updateHostedAttachments(width: 600, selection: [])
        #expect(backend.hostedAttachment(for: block.id) === attachment)
        #expect(backend.embeddedLoadingState(for: block.id) === loading)
        #expect(backend.cachedAttributedString(forBlockAt: blockIndex) === nativeRecord,
                "Source-only appends must not replace the pending native record")
        #expect(attachment.markdownRepresentation().contains("<div>Card"))
        #expect(!backend.snapshotAttributedString().string.contains("<div>Card"))
        #expect(recorder.contexts.isEmpty)

        let closed = try #require(await pipeline.feed("</div>\n```\n\nAfter.\n\n"))
        _ = backend.apply(blocks: closed.blocks, diffs: [closed.diff], selection: .init(location: 0, length: 0))
        #expect(backend.hostedAttachment(for: block.id) === attachment)
        let context = try #require(recorder.contexts.first)
        #expect(recorder.contexts.count == 1)
        #expect(context.source == "<div>Card</div>\n")
        #expect(context.availableWidth == 600)
        #expect(context.loadingState === loading)
        #expect(attachment.markdownRepresentation() == "```html-preview\n<div>Card</div>\n```")
        #expect(backend.snapshotAttributedString().string.contains("After."))
        _ = backend.apply(blocks: closed.blocks, selection: .init(location: 0, length: 0))
        #expect(recorder.contexts.count == 1)
    }

    @Test("Raw HTML pending activity follows pause and stop without stopping closed preparation")
    func rawHTMLPendingActivity() async throws {
        let recorder = LoadingFactoryRecorder()
        let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [recorder.renderer()])
        let backend = TextKitStreamingBackend()
        let open = try #require(await pipeline.feed("<div>\nStreaming report\n"))
        let block = try #require(open.blocks.first { $0.embeddedBlock != nil })
        _ = backend.apply(blocks: open.blocks, diffs: [open.diff], selection: .init(location: 0, length: 0))
        let attachment = try #require(backend.hostedAttachment(for: block.id))
        let loading = try #require(backend.embeddedLoadingState(for: block.id))
        #expect(recorder.contexts.isEmpty)
        #expect(attachment.markdownRepresentation().contains("Streaming report"))
        #expect(!backend.snapshotAttributedString().string.contains("Streaming report"))
        backend.setPaused(true)
        #expect(loading.activity == .paused)
        backend.setSVGStreamActive(false)
        #expect(loading.activity == .paused)
        backend.setPaused(false)
        #expect(loading.activity == .stopped)
        #expect(loading.showsPlaceholder)
        let closed = try #require(await pipeline.feed("</div>\n\nTail.\n\n"))
        _ = backend.apply(blocks: closed.blocks, diffs: [closed.diff], selection: .init(location: 0, length: 0))
        #expect(backend.hostedAttachment(for: block.id) === attachment)
        #expect(recorder.contexts.count == 1)
        #expect(loading.activity == .receiving)
        backend.setPaused(true)
        #expect(loading.activity == .receiving, "Closed async preparation owns readiness independently of stream pause")
        loading.finishLoading()
        #expect(!loading.isLoading && !loading.showsPlaceholder)
    }

    @Test("Default registrations retain native open source and their closed-only contract")
    func defaultRegistrationRemainsClosedOnly() async throws {
        let recorder = LoadingFactoryRecorder()
        let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [recorder.renderer(pending: false)])
        let backend = TextKitStreamingBackend()
        let open = try #require(await pipeline.feed("```html-preview\n<div>Source"))
        #expect(open.blocks.allSatisfy { $0.embeddedBlock == nil })
        _ = backend.apply(blocks: open.blocks, diffs: [open.diff], selection: .init(location: 0, length: 0))
        #expect(backend.snapshotAttributedString().string.contains("<div>Source"))
        #expect(recorder.contexts.isEmpty)
        let closed = try #require(await pipeline.feed("</div>\n```\n\n"))
        _ = backend.apply(blocks: closed.blocks, diffs: [closed.diff], selection: .init(location: 0, length: 0))
        #expect(recorder.contexts.count == 1)
        #expect(recorder.contexts.first?.loadingState == nil)
    }

    @Test("An explicit default SVG registration retains native open source even with built-in SVG loading enabled")
    func defaultSVGRegistrationDoesNotOptIntoLoading() async throws {
        let recorder = LoadingFactoryRecorder()
        let renderer = PicoEmbeddedBlockRenderer(selectors: [.fencedCode(language: "svg")]) { context in
            recorder.contexts.append(context)
            return AnyView(Text("Custom SVG"))
        }
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering(), embeddedBlockRenderers: [renderer])
        let backend = TextKitStreamingBackend()
        let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><rect width=\"10\" height=\"10\"/></svg>"
        let open = try #require(await pipeline.feed("```svg\n" + source + "\n"))
        #expect(open.blocks.allSatisfy { $0.embeddedBlock == nil && $0.svgGraphic == nil })
        _ = backend.apply(blocks: open.blocks, diffs: [open.diff], selection: .init(location: 0, length: 0))
        #expect(backend.snapshotAttributedString().string.contains(source))
        #expect(recorder.contexts.isEmpty)
        let closed = try #require(await pipeline.feed("```\n\n"))
        _ = backend.apply(blocks: closed.blocks, diffs: [closed.diff], selection: .init(location: 0, length: 0))
        #expect(recorder.contexts.count == 1)
        #expect(recorder.contexts.first?.loadingState == nil)
    }

    @Test("Declined final content restores native source and ends the pending state")
    func declinedFactoryRestoresSource() async throws {
        let recorder = LoadingFactoryRecorder()
        let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [recorder.renderer(accepts: false)])
        let backend = TextKitStreamingBackend()
        let open = try #require(await pipeline.feed("```html-preview\n<div>Declined"))
        let block = try #require(open.blocks.first { $0.embeddedBlock != nil })
        _ = backend.apply(blocks: open.blocks, diffs: [open.diff], selection: .init(location: 0, length: 0))
        let loading = try #require(backend.embeddedLoadingState(for: block.id))
        let closed = try #require(await pipeline.feed("</div>\n```\n\n"))
        _ = backend.apply(blocks: closed.blocks, diffs: [closed.diff], selection: .init(location: 0, length: 0))
        #expect(backend.snapshotAttributedString().string.contains("<div>Declined</div>"))
        #expect(!backend.snapshotAttributedString().string.contains("\u{FFFC}"))
        #expect(!loading.isLoading && !loading.showsPlaceholder)
        _ = backend.apply(blocks: closed.blocks, selection: .init(location: 0, length: 0))
        #expect(recorder.contexts.count == 1)
    }

    @Test("Pending and closed views preserve quote bars and first-child list markers", arguments: [false, true])
    func containerMetadataSurvivesClosure(quoted: Bool) async throws {
        let recorder = LoadingFactoryRecorder()
        let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [recorder.renderer()])
        let backend = TextKitStreamingBackend()
        let opening = quoted ? "> ```html-preview\n> <div>Card</div>\n" : "- ```html-preview\n  <div>Card</div>\n"
        let closing = quoted ? "> ```\n\n" : "  ```\n\n"
        let open = try #require(await pipeline.feed(opening))
        let id = try #require(open.blocks.first { $0.embeddedBlock != nil }?.id)
        _ = backend.apply(blocks: open.blocks, diffs: [open.diff], selection: .init(location: 0, length: 0))
        let attachment = try #require(backend.hostedAttachment(for: id))
        try assertContainer(backend.snapshotAttributedString(), quoted: quoted)
        let closed = try #require(await pipeline.feed(closing))
        _ = backend.apply(blocks: closed.blocks, diffs: [closed.diff], selection: .init(location: 0, length: 0))
        try assertContainer(backend.snapshotAttributedString(), quoted: quoted)
        #expect(backend.hostedAttachment(for: id) === attachment)
        #expect(recorder.contexts.count == 1)
    }

    @Test("Evicting a pending block releases its loading state")
    func discardedPendingBlockReleasesState() async throws {
        let recorder = LoadingFactoryRecorder()
        let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [recorder.renderer()])
        let backend = TextKitStreamingBackend()
        let open = try #require(await pipeline.feed("```html-preview\n<div>Pending"))
        let id = try #require(open.blocks.first { $0.embeddedBlock != nil }?.id)
        _ = backend.apply(blocks: open.blocks, diffs: [open.diff], selection: .init(location: 0, length: 0))
        weak var loading = backend.embeddedLoadingState(for: id)
        try #require(loading != nil)
        _ = backend.apply(blocks: [], selection: .init(location: 0, length: 0))
        #expect(loading == nil)
        #expect(recorder.contexts.isEmpty)
    }

    private func assertContainer(_ attributed: NSAttributedString, quoted: Bool) throws {
        let marker = (attributed.string as NSString).range(of: "\u{FFFC}")
        try #require(marker.location != NSNotFound)
        let paragraph = try #require(attributed.attribute(.paragraphStyle, at: marker.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.headIndent > 0)
        if quoted {
            #expect((attributed.attribute(.picoBlockquoteLevel, at: marker.location, effectiveRange: nil) as? Int) == 1)
        } else {
            #expect(attributed.string.contains("• \u{FFFC}"))
            #expect(attributed.string.filter { $0 == "•" }.count == 1)
        }
    }
}

@MainActor
private final class LoadingFactoryRecorder {
    var contexts: [PicoEmbeddedBlockContext] = []
    func renderer(pending: Bool = true, accepts: Bool = true) -> PicoEmbeddedBlockRenderer {
        var renderer = PicoEmbeddedBlockRenderer(selectors: [.htmlBlock, .fencedCode(language: "html-preview")]) { [self] context in
            contexts.append(context)
            return accepts ? AnyView(Text("Prepared preview").frame(height: 80)) : nil
        }
        renderer.showsLoadingPlaceholder = pending
        return renderer
    }
}
#endif
