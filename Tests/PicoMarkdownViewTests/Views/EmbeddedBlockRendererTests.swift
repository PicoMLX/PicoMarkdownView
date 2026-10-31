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

    @Test("An explicit SVG renderer owns accepted content and declined native fallback", arguments: [false, true])
    func explicitSVGRegistrationWins(accepts: Bool) async throws {
        let recorder = Recorder()
        let renderer = PicoEmbeddedBlockRenderer(selectors: [.fencedCode(language: "svg")]) { context in
            recorder.contexts.append(context)
            return accepts ? AnyView(Text("Custom SVG presentation").frame(height: 80)) : nil
        }
        let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 120 40\"><rect width=\"120\" height=\"40\" fill=\"#3973d5\"/></svg>"
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering(), embeddedBlockRenderers: [renderer])
        let update = try #require(await pipeline.feed("Before.\n\n```svg\n" + source + "\n```\n\nAfter.\n\n"))
        let block = try #require(update.blocks.first { $0.codeBlock?.language == "svg" })
        #expect(block.embeddedBlock != nil)
        #expect(block.svgGraphic != nil, "The merge carries both metadata values; backend dispatch must honor the explicit registration")
        let (controller, view) = makeView()
        controller.update(textView: view, blocks: update.blocks, diffs: [update.diff], replaceToken: 1, configuration: .default())
        #expect(recorder.contexts.count == 1)
        #expect(view.string.contains("Before.") && view.string.contains("After."))
        if accepts {
            let attachment = try #require(attachments(in: view).first)
            #expect(attachments(in: view).count == 1)
            #expect(attachment.markdownRepresentation().contains("```svg\n" + source + "\n```"))
            #expect(!view.string.contains(source))
        } else {
            #expect(attachments(in: view).isEmpty, "A declined explicit registration must not fall through to built-in SVG hosting")
            #expect(view.string.contains(source))
        }
    }

    @Test("An HTML-only registration leaves enabled SVG fences on the built-in vector path")
    func unrelatedRegistrationPreservesSVG() async throws {
        let recorder = Recorder()
        let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 120 40\"><rect width=\"120\" height=\"40\" fill=\"#3973d5\"/></svg>"
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering(), embeddedBlockRenderers: [recorder.renderer()])
        let update = try #require(await pipeline.feed("```svg\n" + source + "\n```\n\n"))
        let block = try #require(update.blocks.first { $0.codeBlock?.language == "svg" })
        #expect(block.embeddedBlock == nil)
        #expect(block.svgGraphic != nil)
        let (controller, view) = makeView()
        controller.update(textView: view, blocks: update.blocks, diffs: [update.diff], replaceToken: 1, configuration: .default())
        #expect(recorder.contexts.isEmpty)
        let attachment = try #require(attachments(in: view).first)
        #expect(attachments(in: view).count == 1)
        #expect(attachment.markdownRepresentation().contains("```svg\n" + source + "\n```"))
        #expect(!view.string.contains(source))
    }

    @Test("An explicit OpenUI registration owns accepted content and declined native fallback", arguments: [false, true])
    func explicitOpenUIRegistrationWins(accepts: Bool) async throws {
        let recorder = Recorder()
        let renderer = PicoEmbeddedBlockRenderer(selectors: [.fencedCode(language: "openui")]) { context in
            recorder.contexts.append(context)
            return accepts ? AnyView(Text("Custom OpenUI presentation").frame(height: 80)) : nil
        }
        let source = "root = Stack([body])\nbody = TextContent(\"Hello\")"
        let pipeline = MarkdownStreamingPipeline(theme: .default().withOpenUIRendering(), embeddedBlockRenderers: [renderer])
        let open = try #require(await pipeline.feed("```openui\n" + source + "\n"))
        #expect(open.blocks.allSatisfy { $0.embeddedBlock == nil && $0.openUI == nil })
        #expect(recorder.contexts.isEmpty)
        let closed = try #require(await pipeline.feed("```\n\n"))
        let block = try #require(closed.blocks.first { $0.codeBlock?.language == "openui" })
        #expect(block.embeddedBlock != nil)
        #expect(block.openUI == nil, "The built-in interpreter must not replace the explicit registration's native fallback")
        #expect(String(block.content.characters).contains(source))
        let backend = TextKitStreamingBackend()
        _ = backend.apply(blocks: closed.blocks, diffs: [closed.diff], selection: .init(location: 0, length: 0))
        #expect(recorder.contexts.count == 1)
        #expect(backend.hostedOpenUIModel(for: block.id) == nil)
        let attributed = backend.snapshotAttributedString()
        var hosted: PicoHostedAttachment?
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { hosted = attachment }
        }
        if accepts {
            let attachment = try #require(hosted)
            #expect(attachment.markdownRepresentation() == "```openui\n" + source + "\n```")
            #expect(!attributed.string.contains(source))
        } else {
            #expect(hosted == nil)
            #expect(attributed.string.contains(source))
            #expect(!attributed.string.contains("\u{FFFC}"))
        }
        _ = backend.apply(blocks: closed.blocks, selection: .init(location: 0, length: 0))
        #expect(recorder.contexts.count == 1)
    }

    @Test("An explicit chart registration owns open source, accepted content and declined fallback", arguments: [false, true])
    func explicitChartRegistrationWins(accepts: Bool) async throws {
        let recorder = Recorder()
        let renderer = PicoEmbeddedBlockRenderer(selectors: [.fencedCode(language: "vega-lite")]) { context in
            recorder.contexts.append(context)
            return accepts ? AnyView(Text("Custom chart presentation").frame(height: 80)) : nil
        }
        let source = VegaLiteRenderingFixture.source
        let pipeline = MarkdownStreamingPipeline(theme: .default().withVegaLiteRendering(true), embeddedBlockRenderers: [renderer])
        let open = try #require(await pipeline.feed("```vega-lite\n" + source))
        let openBlock = try #require(open.blocks.first { $0.codeBlock?.language == "vega-lite" })
        #expect(openBlock.embeddedBlock == nil)
        #expect(openBlock.vegaLiteChart == nil)
        #expect(String(openBlock.content.characters).contains(source))
        #expect(recorder.contexts.isEmpty)
        let backend = TextKitStreamingBackend()
        _ = backend.apply(blocks: open.blocks, diffs: [open.diff], selection: .init(location: 0, length: 0))
        #expect(backend.hostedAttachment(for: openBlock.id) == nil)
        #expect(backend.hostedVectorModel(for: openBlock.id) == nil)
        #expect(backend.snapshotAttributedString().string.contains(source))

        let closed = try #require(await pipeline.feed("```\n\n"))
        let block = try #require(closed.blocks.first { $0.id == openBlock.id })
        #expect(block.embeddedBlock != nil)
        #expect(block.vegaLiteChart == nil, "The built-in chart compiler must not consume a registered fence")
        #expect(String(block.content.characters).contains(source))
        _ = backend.apply(blocks: closed.blocks, diffs: [closed.diff], selection: .init(location: 0, length: 0))
        #expect(recorder.contexts.count == 1)
        #expect(backend.hostedVectorModel(for: block.id) == nil)
        let attributed = backend.snapshotAttributedString()
        if accepts {
            let attachment = try #require(backend.hostedAttachment(for: block.id))
            #expect(attachment.markdownRepresentation() == "```vega-lite\n" + source + "```")
            #expect(!attributed.string.contains(source))
        } else {
            #expect(backend.hostedAttachment(for: block.id) == nil)
            #expect(attributed.string.contains(source))
            #expect(!attributed.string.contains("\u{FFFC}"))
            #expect(backend.codeBlockForCopy(id: block.id)?.code == source)
        }
        _ = backend.apply(blocks: closed.blocks, selection: .init(location: 0, length: 0))
        #expect(recorder.contexts.count == 1)
    }

    @Test("A registered Mermaid fence stays native while open and when its factory declines")
    func declinedMermaidSkipsBuiltInInterpretation() async throws {
        let recorder = Recorder()
        let provider = DeclinedEmbeddedMermaidProvider()
        let renderer = PicoEmbeddedBlockRenderer(selectors: [.fencedCode(language: "mermaid")]) { context in
            recorder.contexts.append(context)
            return nil
        }
        let pipeline = MarkdownStreamingPipeline(mermaidProvider: provider, embeddedBlockRenderers: [renderer])
        let open = try #require(await pipeline.feed("```mermaid\nflowchart LR\n  A --> B\n"))
        #expect(open.blocks.allSatisfy { $0.embeddedBlock == nil && $0.mermaidDiagram == nil })
        let closed = try #require(await pipeline.feed("```\n\n"))
        let block = try #require(closed.blocks.first { $0.codeBlock?.language == "mermaid" })
        #expect(block.embeddedBlock != nil)
        #expect(block.mermaidDiagram == nil)
        #expect(await provider.calls == 0, "The built-in provider must not consume a fence owned by a source-backed registration")
        let (controller, view) = makeView()
        controller.update(textView: view, blocks: closed.blocks, diffs: [closed.diff], replaceToken: 1, configuration: .default())
        #expect(recorder.contexts.count == 1)
        #expect(attachments(in: view).isEmpty)
        #expect(view.string.contains("flowchart LR\n  A --> B"))
        #expect(!view.string.contains("\u{FFFC}"))
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

#if os(macOS)
private actor DeclinedEmbeddedMermaidProvider: MermaidDiagramProvider {
    private(set) var calls = 0
    func render(_ request: MermaidRenderRequest) async -> MermaidRenderResult? {
        calls += 1
        return nil
    }
}
#endif
