import Foundation
import Testing
@testable import PicoMarkdownView

@Suite("Opt-in OpenUI fence rendering")
struct OpenUIRendererTests {
    @Test("OpenUI is disabled by default and theme copies preserve the opt-in")
    func themeCopiesPreserveOptIn() {
        let defaults = MarkdownRenderTheme.default()
        #expect(!defaults.openUIRenderingEnabled)
        let enabled = defaults.withOpenUIRendering()
        #expect(enabled.openUIRenderingEnabled)
        #expect(enabled.scaled(by: 1.5).openUIRenderingEnabled)
        #expect(enabled.withMermaidRendering(.disabled).openUIRenderingEnabled)
        #expect(enabled.withSVGRendering().openUIRenderingEnabled)
        #expect(enabled.withCodeHighlighting(codeBlockTheme: nil, codeHighlighter: nil).openUIRenderingEnabled)
        #expect(enabled.withSVGRendering().withOpenUIRendering(false).svgRenderingEnabled)
        #expect(!enabled.withOpenUIRendering(false).openUIRenderingEnabled)
    }

    @Test("Only OpenUI info strings opt into hosted rendering", arguments: [
        ("openui", true), ("OPENUI preview", true), ("openui\tpreview", true),
        ("html", false), ("json", false), ("openui-json", false), ("swift", false), ("", false)
    ])
    func explicitLanguageOnly(_ entry: (String, Bool)) async throws {
        let blocks = await render(["```" + entry.0 + "\n" + source + "\n```\n\n"],
                                  theme: .default().withOpenUIRendering())
        let code = try #require(blocks.first { $0.codeBlock != nil })
#if os(macOS)
        #expect((code.openUI != nil) == entry.1)
#else
        #expect(code.openUI == nil, "Enabling OpenUI must leave the UIKit code presentation unchanged")
#endif
        #expect(code.codeBlock?.code == source + "\n")
    }

    @Test("Opting in retains the exact source while disabled rendering stays native code")
    func completeSourceAndFallback() async throws {
        let disabled = await render([document], theme: .default())
        let enabled = await render([document], theme: .default().withOpenUIRendering())
        let plain = try #require(disabled.first { $0.codeBlock?.language == "openui" })
        let hosted = try #require(enabled.first { $0.codeBlock?.language == "openui" })
        #expect(disabled.allSatisfy { $0.openUI == nil })
        #expect(hosted.codeBlock == plain.codeBlock)
        #expect(String(plain.content.characters).contains(source))
        #expect(hosted.math == nil)
        #expect(hosted.mermaidDiagram == nil)
        #expect(hosted.svgGraphic == nil)
#if os(macOS)
        #expect(String(hosted.content.characters) == "\u{FFFC}\n")
        #expect(hosted.openUI?.source == source + "\n")
        #expect(hosted.openUI?.language == "openui")
#else
        #expect(String(hosted.content.characters) == String(plain.content.characters))
        #expect(hosted.openUI == nil)
#endif
    }

    @Test("OpenUI metadata tracks body font scaling independently of code font scaling")
    func presentationUsesBodyFontSize() async throws {
        #expect(RenderedOpenUIContent(source: source, language: "openui").fontSize == 16)
        let defaults = MarkdownRenderTheme.default()
        let theme = MarkdownRenderTheme(bodyFont: FontSpec(size: 20), codeFont: FontSpec(size: 11, design: .monospaced),
            blockquoteColor: defaults.blockquoteColor, linkColor: defaults.linkColor, headingFonts: defaults.headingFonts)
            .withOpenUIRendering()
        let original = try #require(await render([document], theme: theme).first { $0.codeBlock?.language == "openui" })
        let scaled = try #require(await render([document], theme: theme.scaled(by: 1.5, codeBlock: 0.5))
            .first { $0.codeBlock?.language == "openui" })
#if os(macOS)
        #expect(original.openUI?.fontSize == 20)
        #expect(scaled.openUI?.fontSize == 30)
        #expect(scaled.openUI?.source == original.openUI?.source)
#else
        #expect(original.openUI == nil && scaled.openUI == nil)
#endif
    }

    @Test("An open OpenUI fence streams native code until closure or end of input", arguments: [false, true])
    func waitsForCompletion(finishWithoutFence: Bool) async throws {
        let pipeline = MarkdownStreamingPipeline(theme: .default().withOpenUIRendering())
        _ = await pipeline.feed("Before.\n\n```openui\n" + source + "\n")
        let open = try #require(await pipeline.blocksSnapshot().first { $0.codeBlock?.language == "openui" })
        #expect(!open.snapshot.isClosed)
        #expect(open.openUI == nil)
        #expect(String(open.content.characters).contains(source))

        if finishWithoutFence {
            _ = await pipeline.finish()
        } else {
            _ = await pipeline.feed("```\n\nAfter.\n\n")
        }
        let closed = try #require(await pipeline.blocksSnapshot().first { $0.id == open.id })
        #expect(closed.snapshot.isClosed)
        #expect(closed.codeBlock?.code == source + "\n")
#if os(macOS)
        #expect(closed.openUI?.source == source + "\n")
#else
        #expect(closed.openUI == nil)
#endif
    }

    @Test("Character-sized chunks produce the same blocks and OpenUI source as a single feed")
    func arbitraryChunkBoundaries() async {
        let theme = MarkdownRenderTheme.default().withOpenUIRendering()
        let single = await render([document], theme: theme)
        let chunked = await render(document.map(String.init), theme: theme)
        #expect(chunked.count == single.count)
        for (actual, expected) in zip(chunked, single) {
            #expect(String(actual.content.characters) == String(expected.content.characters))
            // Adaptive color providers have fresh identities across pipelines;
            // compare the tokenizer and renderer metadata independently of them.
            var metadata = actual
            metadata.content = expected.content
            #expect(metadata == expected)
        }
    }

    @Test("Later prose and table rows do not refresh a completed OpenUI block")
    func completedBlockIsIncrementallyIsolated() async throws {
        let pipeline = MarkdownStreamingPipeline(theme: .default().withOpenUIRendering())
        _ = await pipeline.feed("```openui\n" + source + "\n```\n\n")
        let completed = try #require(await pipeline.blocksSnapshot().first { $0.codeBlock?.language == "openui" })
        let prose = try #require(await pipeline.feed("Later prose.\n\n| Name | Value |\n| --- | --- |\n| First | 1 |\n"))
        let firstTable = try #require(prose.blocks.first { $0.table != nil })
        #expect(firstTable.table?.rows.count == 1)
        #expect(prose.blocks.first { $0.id == completed.id } == completed)
        #expect(!prose.diff.changes.contains { touches($0, id: completed.id) })

        let row = try #require(await pipeline.feed("| Second | 2 |\n"))
        #expect(row.blocks.first { $0.id == firstTable.id }?.table?.rows.count == 2)
        #expect(row.diff.changes.contains(.tableRowAppended(id: firstTable.id, rowIndex: 1)))
        #expect(row.blocks.first { $0.id == completed.id } == completed)
        #expect(!row.diff.changes.contains { touches($0, id: completed.id) })
    }

    @Test("OpenUI opt-in leaves math, tables and other fence languages on their existing paths")
    func unrelatedRenderersRemainNative() async throws {
        let text = "```html\n<div>Example</div>\n```\n\n```math\nx^2\n```\n\n| Name | Value |\n| --- | --- |\n| First | 1 |\n\n"
        let blocks = await render([text], theme: .default().withOpenUIRendering())
        #expect(blocks.allSatisfy { $0.openUI == nil })
        #expect(blocks.contains { $0.codeBlock?.language == "html" })
        #expect(blocks.contains { $0.math?.tex == "x^2\n" || $0.math?.tex == "x^2" })
        #expect(blocks.first { $0.table != nil }?.table?.rows.count == 1)
    }

    private let source = "root = Stack([body])\nbody = TextContent(\"Hello 🧭\")"
    private var document: String { "Before 🧭.\n\n```openui\n" + source + "\n```\n\nAfter **native** paragraph.\n\n" }

    private func render(_ chunks: [String], theme: MarkdownRenderTheme) async -> [RenderedBlock] {
        let pipeline = MarkdownStreamingPipeline(theme: theme)
        for chunk in chunks { _ = await pipeline.feed(chunk) }
        _ = await pipeline.finish()
        return await pipeline.blocksSnapshot()
    }

    private func touches(_ change: AssemblerDiff.Change, id: BlockID) -> Bool {
        switch change {
        case .blockStarted(let changed, _, _), .runsAppended(let changed, _),
             .codeAppended(let changed, _), .tableHeaderConfirmed(let changed),
             .tableRowAppended(let changed, _), .blockEnded(let changed):
            changed == id
        case .blocksDiscarded:
            false
        }
    }
}
