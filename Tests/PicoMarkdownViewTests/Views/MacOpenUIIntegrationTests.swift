#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS hosted OpenUI integration")
@MainActor
struct MacOpenUIIntegrationTests {
    @Test("OpenUI sits between native paragraphs and continuous copying exports its raw fenced source")
    @available(macOS 27.0, *)
    func nativeParagraphsAndSourceCopy() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: .default().withOpenUIRendering())
        await feed("Before 🧭.\n\n" + fence + "\n\nAfter paragraph.\n\n",
                   pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        let storage = try #require(view.textStorage)
        let attachment = try #require(attachments(in: storage).first)
        #expect(attachments(in: storage).count == 1)
        #expect(storage.string == "Before 🧭.\n\u{FFFC}\nAfter paragraph.\n")
        #expect(view.textLayoutManager != nil)
        #expect(attachment.markdownRepresentation() == fence)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.contains("Before 🧭."))
        #expect(copied.contains(fence))
        #expect(copied.contains("After paragraph."))
        #expect(!copied.contains("\u{FFFC}"))
        #expect(attachment.context.isSelected)
    }

    @Test("Fence closure replaces only its native fallback and preserves an existing text selection")
    @available(macOS 27.0, *)
    func closurePreservesNativeSelection() async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: .default().withOpenUIRendering())
        await feed("Before.\n\n```openui\n" + source + "\n", pipeline: pipeline, controller: controller, view: view)
        let storage = try #require(view.textStorage)
        #expect(attachments(in: storage).isEmpty)
        #expect(storage.string.contains(source))
        let selected = (storage.string as NSString).range(of: "Before.")
        view.setSelectedRange(selected)
        await feed("```\n\nAfter.\n\n", pipeline: pipeline, controller: controller, view: view)
        #expect(attachments(in: storage).count == 1)
        #expect(view.selectedRange() == selected)
        #expect(storage.string == "Before.\n\u{FFFC}\nAfter.\n")
        #expect(view.textLayoutManager != nil)
    }

    @Test("A full apply converts the native open-fence fallback to hosted OpenUI")
    @available(macOS 27.0, *)
    func fullApplyConvertsIdenticalCode() async throws {
        let pipeline = MarkdownStreamingPipeline(theme: .default().withOpenUIRendering())
        _ = await pipeline.feed("```openui\n" + source + "\n")
        let open = try #require(await pipeline.blocksSnapshot().first { $0.codeBlock?.language == "openui" })
        #expect(!open.snapshot.isClosed)
        _ = await pipeline.feed("```\n\n")
        let closed = try #require(await pipeline.blocksSnapshot().first { $0.id == open.id })
        #expect(closed.openUI != nil)
        let backend = TextKitStreamingBackend()
        _ = backend.apply(blocks: [open], selection: emptySelection)
        #expect(backend.hostedAttachment(for: open.id) == nil)
        #expect(backend.snapshotAttributedString().string.contains(source))
        #expect(backend.codeBlockForCopy(id: open.id)?.code == source + "\n")

        _ = backend.apply(blocks: [closed], selection: emptySelection)
        let stored = backend.snapshotAttributedString()
        #expect(stored.string == "\u{FFFC}\n")
        let attachment = try #require(stored.attribute(.attachment, at: 0, effectiveRange: nil) as? PicoHostedAttachment)
        #expect(backend.hostedAttachment(for: closed.id) === attachment)
        #expect(attachment.markdownRepresentation() == fence)
        #expect(backend.codeBlockForCopy(id: closed.id) == nil,
                "Hosted OpenUI must not also acquire the ordinary native code-copy control")
        #expect(backend.codeBlockRangeForCopy(id: closed.id) == nil)
        #expect(!backend.needsFullApply(for: [closed]))
    }

    @Test("Later prose, resize and selection reuse the same lazy OpenUI attachment")
    @available(macOS 27.0, *)
    func appendAndResizeRetainAttachment() async throws {
        let theme = MarkdownRenderTheme.default().withOpenUIRendering()
        let pipeline = MarkdownStreamingPipeline(theme: theme)
        let backend = TextKitStreamingBackend()
        let initial = try #require(await pipeline.feed(fence + "\n\n"))
        _ = backend.apply(blocks: initial.blocks, diffs: [initial.diff], selection: emptySelection)
        let block = try #require(initial.blocks.first { $0.openUI != nil })
        let original = try #require(backend.hostedAttachment(for: block.id))
        let model = try #require(backend.hostedOpenUIModel(for: block.id))
        #expect(original.hostingView == nil)
        #expect(model.webView == nil)
        #expect(model.textScale == theme.bodyFont.pointSize / 16)
        for width: CGFloat in [640, 180, 700] {
            backend.updateHostedAttachments(width: width, selection: [NSRange(location: 0, length: 1)])
            #expect(backend.hostedAttachment(for: block.id) === original)
            #expect(original.hostingView == nil, "Offscreen widget sizing must not create a WKWebView")
            #expect(original.context.availableWidth == width)
            #expect(original.context.isSelected)
            #expect(original.measuredSize.height.isFinite && original.measuredSize.height > 0)
        }
        let appended = try #require(await pipeline.feed("Later **streamed** paragraph.\n\n"))
        _ = backend.apply(blocks: appended.blocks, diffs: [appended.diff], selection: emptySelection)
        #expect(backend.hostedAttachment(for: block.id) === original)
        #expect(original.hostingView == nil)
        #expect(backend.snapshotAttributedString().string.contains("Later streamed paragraph."))
        _ = backend.apply(blocks: appended.blocks, selection: emptySelection)
        #expect(backend.hostedAttachment(for: block.id) === original,
                "A full presentation refresh must not discard interactive state")
        #expect(!backend.needsFullApply(for: appended.blocks))
        let scaled = try #require(await pipeline.updateTextScale(1.5))
        _ = backend.apply(blocks: scaled, selection: emptySelection)
        #expect(backend.hostedAttachment(for: block.id) === original)
        #expect(backend.hostedOpenUIModel(for: block.id) === model)
        #expect(model.textScale == theme.bodyFont.pointSize * 1.5 / 16)
        #expect(model.webViewCreationCount == 0)
        #expect(model.renderCount == 0)
    }

    @Test("Identical OpenUI sources have independent attachment identities")
    @available(macOS 27.0, *)
    func identicalSourcesRemainIndependent() async throws {
        let pipeline = MarkdownStreamingPipeline(theme: .default().withOpenUIRendering())
        _ = await pipeline.feed(fence + "\n\nMiddle paragraph.\n\n" + fence + "\n\n")
        _ = await pipeline.finish()
        let blocks = await pipeline.blocksSnapshot()
        let children = blocks.filter { $0.openUI != nil }
        try #require(children.count == 2)
        let backend = TextKitStreamingBackend()
        _ = backend.apply(blocks: blocks, selection: emptySelection)
        let first = try #require(backend.hostedAttachment(for: children[0].id))
        let second = try #require(backend.hostedAttachment(for: children[1].id))
        let firstModel = try #require(backend.hostedOpenUIModel(for: children[0].id))
        let secondModel = try #require(backend.hostedOpenUIModel(for: children[1].id))
        #expect(first !== second)
        #expect(firstModel !== secondModel)
        #expect(firstModel.sourceID != secondModel.sourceID)
        #expect(first.markdownRepresentation() == second.markdownRepresentation())
        backend.updateHostedAttachments(width: 640, selection: [NSRange(location: 0, length: 1)])
        #expect(first.context.isSelected)
        #expect(!second.context.isSelected)
        #expect(first.hostingView == nil && second.hostingView == nil)
    }

    @Test("Pause, removal and document replacement keep OpenUI attachment lifecycle bounded")
    @available(macOS 27.0, *)
    func attachmentLifecycle() async throws {
        let block = try await closedBlock()
        let backend = TextKitStreamingBackend()
        _ = backend.apply(blocks: [block], selection: emptySelection)
        let original = try #require(backend.hostedAttachment(for: block.id))
        let originalModel = try #require(backend.hostedOpenUIModel(for: block.id))
        backend.setPaused(true)
        _ = backend.apply(blocks: [], selection: emptySelection)
        #expect(backend.hostedAttachment(for: block.id) === original)
        #expect(!originalModel.isDisposed)
        backend.setPaused(false)
        _ = backend.apply(blocks: [], selection: emptySelection)
        #expect(backend.hostedAttachment(for: block.id) == nil)
        #expect(originalModel.isDisposed)
        #expect(backend.snapshotAttributedString().length == 0)
        _ = backend.apply(blocks: [block], selection: emptySelection)
        let restored = try #require(backend.hostedAttachment(for: block.id))
        let restoredModel = try #require(backend.hostedOpenUIModel(for: block.id))
        #expect(restored !== original)
        backend.resetDocumentOnNextApply()
        _ = backend.apply(blocks: [block], selection: emptySelection)
        #expect(backend.hostedAttachment(for: block.id) !== restored,
                "Reused tokenizer IDs in a new message must not reuse another message's form state")
        #expect(restoredModel.isDisposed)
    }

    @Test("Hosted OpenUI preserves enclosing quote bars and first-child list markers", arguments: [false, true])
    @available(macOS 27.0, *)
    func nativeContainerPlacement(inList: Bool) async throws {
        let (controller, view) = makeView()
        let pipeline = MarkdownStreamingPipeline(theme: .default().withOpenUIRendering())
        let text = inList
            ? "1. ```openui\n   " + source.replacingOccurrences(of: "\n", with: "\n   ") + "\n   ```\n\n"
            : "> ```openui\n> " + source.replacingOccurrences(of: "\n", with: "\n> ") + "\n> ```\n\n"
        await feed(text, pipeline: pipeline, controller: controller, view: view)
        apply(await pipeline.finish(), controller: controller, view: view)
        let storage = try #require(view.textStorage)
        #expect(attachments(in: storage).count == 1)
        let marker = (storage.string as NSString).range(of: "\u{FFFC}")
        try #require(marker.location != NSNotFound)
        let paragraph = try #require(storage.attribute(.paragraphStyle, at: marker.location,
                                                      effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.headIndent > 0)
        #expect(paragraph.textBlocks.isEmpty)
        #expect(storage.attribute(.backgroundColor, at: marker.location, effectiveRange: nil) == nil)
        if inList {
            #expect(storage.string.contains("1. \u{FFFC}"))
            #expect(paragraph.firstLineHeadIndent < paragraph.headIndent)
        } else {
            #expect(storage.attribute(.picoBlockquoteLevel, at: marker.location, effectiveRange: nil) as? Int == 1)
        }
    }

    private let emptySelection = NSRange(location: 0, length: 0)
    private let source = "root = Stack([body])\nbody = TextContent(\"Hello 🧭\")"
    private var fence: String { "```openui\n" + source + "\n```" }

    private func closedBlock() async throws -> RenderedBlock {
        let pipeline = MarkdownStreamingPipeline(theme: .default().withOpenUIRendering())
        _ = await pipeline.feed(fence + "\n\n")
        _ = await pipeline.finish()
        return try #require(await pipeline.blocksSnapshot().first { $0.openUI != nil })
    }

    private func makeView() -> (TextKitStreamingController, NSTextView) {
        _ = NSApplication.shared
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        return (controller, view)
    }

    private func feed(_ text: String, pipeline: MarkdownStreamingPipeline,
                      controller: TextKitStreamingController, view: NSTextView) async {
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 11, limitedBy: text.endIndex) ?? text.endIndex
            apply(await pipeline.feed(String(text[start..<end])), controller: controller, view: view)
            start = end
        }
    }

    private func apply(_ update: StreamingUpdate?, controller: TextKitStreamingController, view: NSTextView) {
        guard let update else { return }
        controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                          replaceToken: 1, configuration: .default())
    }

    private func attachments(in storage: NSTextStorage) -> [PicoHostedAttachment] {
        var result: [PicoHostedAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { result.append(attachment) }
        }
        return result
    }
}
#endif
