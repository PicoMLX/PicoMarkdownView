import SwiftUI
import Testing
@testable import PicoMarkdownView
#if os(macOS)
import AppKit
#endif

@Suite("Source-backed embedded blocks")
@MainActor
struct EmbeddedBlockRendererTests {
    @Test("Selectors are exact non-Markdown inputs and never wildcard ordinary content")
    func selectorsStayNarrow() {
        #expect(PicoEmbeddedBlockSelector.htmlBlock.matches(.htmlBlock))
        #expect(PicoEmbeddedBlockSelector.fencedCode(language: " HTML ").matches(.fencedCode(language: "html")))
        for kind in [BlockKind.paragraph, .heading(level: 1), .blockquote, .table, .math(display: true), .unknown] {
            #expect(!PicoEmbeddedBlockSelector.htmlBlock.matches(kind))
            #expect(!PicoEmbeddedBlockSelector.fencedCode(language: "html").matches(kind))
        }
        #expect(!PicoEmbeddedBlockSelector.fencedCode(language: "*").matches(.fencedCode(language: "html")))
        #expect(!PicoEmbeddedBlockSelector.fencedCode(language: "html").matches(.fencedCode(language: nil)))
    }

    @Test("Open source remains native; closed metadata never runs a UI factory in the pipeline")
    func closedDeliveryOnly() async throws {
        let recorder = Recorder()
        let renderer = recorder.renderer()
        let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [renderer])
        let open = try #require(await pipeline.feed("```html\n<div>first"))
        #expect(open.blocks.allSatisfy { $0.embeddedBlock == nil })
        #expect(open.blocks.contains { String($0.content.characters).contains("<div>first") })
        let closed = try #require(await pipeline.feed("</div>\n```\n\nAfter.\n\n"))
        let block = try #require(closed.blocks.first { if case .fencedCode = $0.kind { true } else { false } })
#if os(macOS)
        #expect(block.embeddedBlock?.source == "<div>first</div>\n")
        #expect(block.embeddedBlock?.kind == .fencedCode(language: "html"))
#else
        #expect(block.embeddedBlock == nil, "iOS keeps the existing source renderer")
#endif
        #expect(recorder.contexts.isEmpty, "Only the main-actor attachment backend creates custom views")
        #expect(closed.blocks.contains { String($0.content.characters).contains("After.") })
    }

    @Test("Raw HTML source copying is verbatim and code copying chooses a safe fence")
    func sourceExport() {
        let renderer = Recorder().renderer()
        let raw = "<div>raw</div>\n"
        #expect(RenderedEmbeddedBlock(renderer: renderer, source: raw, kind: .htmlBlock, bodyFontSize: 14).markdown == raw)
        let fenced = RenderedEmbeddedBlock(renderer: renderer, source: "<pre>```</pre>",
                                           kind: .fencedCode(language: "html"), bodyFontSize: 14)
        #expect(fenced.markdown == "````html\n<pre>```</pre>\n````")
    }

#if os(macOS)
    @Test("Hosted content keeps one factory and attachment during streaming, resizing and scaling")
    func stableHostedPresentation() async throws {
        let recorder = Recorder()
        let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [recorder.renderer()])
        let (controller, view) = makeView()
        let update = try #require(await pipeline.feed("Before.\n\n```html\n<div>card</div>\n```\n\nAfter."))
        controller.update(textView: view, blocks: update.blocks, diffs: [update.diff], replaceToken: 1, configuration: .default())
        view.layout()
        let attachment = try #require(attachments(in: view).first)
        let context = try #require(recorder.contexts.first)
        #expect(recorder.contexts.count == 1)
        #expect(context.source == "<div>card</div>\n")
        #expect(context.language == "html")
        #expect(context.availableWidth > 300)
        view.setSelectedRange(NSRange(location: 0, length: view.textStorage?.length ?? 0))
        #expect(context.isSelected)
        let copied = view.markdownForSelection()
        #expect(copied.contains("Before."))
        #expect(copied.contains("```html\n<div>card</div>\n```"))
        #expect(!copied.contains("\u{FFFC}"))

        let tail = try #require(await pipeline.feed(" streamed.\n\n"))
        controller.update(textView: view, blocks: tail.blocks, diffs: [tail.diff], replaceToken: 1, configuration: .default())
        view.setFrameSize(CGSize(width: 600, height: 800))
        view.layout()
        #expect(attachments(in: view).first === attachment)
        #expect(context.availableWidth > 500)
        #expect(recorder.contexts.count == 1)

        let baseSize = context.bodyFontSize
        let scaled = try #require(await pipeline.updateTextScale(1.5))
        controller.update(textView: view, blocks: scaled, diffs: [], replaceToken: 1, configuration: .default())
        #expect(attachments(in: view).first === attachment)
        #expect(context.bodyFontSize == baseSize * 1.5)
        #expect(recorder.contexts.count == 1)
        #expect(view.textLayoutManager != nil)
    }

    @Test("A declined first registration preserves native HTML/code and does not try later factories")
    func declinedContentFallsBack() async throws {
        for markdown in ["```html\n<div>source</div>\n```\n\n", "<div>source</div>\n\n"] {
            let first = Recorder()
            let second = Recorder()
            let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [first.renderer(accepts: false), second.renderer()])
            let native = MarkdownStreamingPipeline()
            _ = await pipeline.feed(markdown)
            _ = await native.feed(markdown)
            let blocks = await pipeline.blocksSnapshot()
            let (controller, view) = makeView()
            controller.update(textView: view, blocks: blocks, diffs: [], replaceToken: 1, configuration: .default())
            let expected = await native.blocksSnapshot().map { String($0.content.characters) }.joined()
            #expect(view.string == expected)
            #expect(attachments(in: view).isEmpty)
            #expect(first.contexts.count == 1)
            #expect(second.contexts.isEmpty)
            let scaled = try #require(await pipeline.updateTextScale(1.2))
            controller.update(textView: view, blocks: scaled, diffs: [], replaceToken: 1, configuration: .default())
            #expect(first.contexts.count == 1, "A declined source is not retried for layout or font changes")
        }
    }

    @Test("An embedded first list child and quoted block retain native container attributes")
    func containerPlacement() async throws {
        for markdown in ["- ```html\n  <div>item</div>\n  ```\n\n", "> ```html\n> <div>quote</div>\n> ```\n\n"] {
            let recorder = Recorder()
            let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [recorder.renderer()])
            _ = await pipeline.feed(markdown)
            _ = await pipeline.finish()
            let (controller, view) = makeView()
            controller.update(textView: view, blocks: await pipeline.blocksSnapshot(), diffs: [], replaceToken: 1, configuration: .default())
            let storage = try #require(view.textStorage)
            let marker = (storage.string as NSString).range(of: "\u{FFFC}")
            try #require(marker.location != NSNotFound)
            let attrs = storage.attributes(at: marker.location, effectiveRange: nil)
            #expect(attrs[.picoCodeBlockBackgroundColor] == nil)
            #expect(attrs[.backgroundColor] == nil)
            let paragraph = try #require(attrs[.paragraphStyle] as? NSParagraphStyle)
            #expect(paragraph.headIndent > 0)
            if markdown.hasPrefix("-") {
                #expect(storage.string.filter { $0 == "•" }.count == 1)
                #expect(storage.string.contains("• \u{FFFC}"))
            } else {
                #expect((attrs[.picoBlockquoteLevel] as? Int) == 1)
            }
        }
    }

    private func makeView() -> (TextKitStreamingController, StreamingTextKit2View) {
        _ = NSApplication.shared
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default()) as! StreamingTextKit2View
        view.setFrameSize(CGSize(width: 400, height: 800))
        return (controller, view)
    }

    private func attachments(in view: NSTextView) -> [PicoHostedAttachment] {
        guard let storage = view.textStorage else { return [] }
        var found: [PicoHostedAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let value = value as? PicoHostedAttachment { found.append(value) }
        }
        return found
    }
#endif

    @MainActor
    private final class Recorder {
        var contexts: [PicoEmbeddedBlockContext] = []
        func renderer(accepts: Bool = true) -> PicoEmbeddedBlockRenderer {
            PicoEmbeddedBlockRenderer(selectors: [.htmlBlock, .fencedCode(language: "html")]) { [self] context in
                contexts.append(context)
                return accepts ? AnyView(Text(context.source).frame(height: 80)) : nil
            }
        }
    }
}
