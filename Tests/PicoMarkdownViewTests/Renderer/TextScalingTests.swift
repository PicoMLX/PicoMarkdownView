import Foundation
import Testing
@testable import PicoMarkdownView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Live font scaling: the theme scales as a value, the renderer re-renders
/// the presentation without touching the parse, and a stream keeps going.
@Suite
struct TextScalingTests {
    private func firstFont(in block: RenderedBlock) -> MarkdownFont? {
        let content = NSAttributedString(block.content)
        guard content.length > 0 else { return nil }
        return content.attribute(.font, at: 0, effectiveRange: nil) as? MarkdownFont
    }

    @Test("Scaling a theme multiplies every font size and keeps the rest")
    func themeScales() {
        let base = MarkdownRenderTheme.default()
        let scaled = base.scaled(by: 1.5)
        #expect(scaled.bodyFont.pointSize == base.bodyFont.pointSize * 1.5)
        #expect(scaled.codeFont.pointSize == base.codeFont.pointSize * 1.5)
        for (level, font) in base.headingFonts {
            #expect(scaled.headingFonts[level]?.pointSize == font.pointSize * 1.5)
        }
        #expect(scaled.codeBlockTheme?.font.pointSize == base.codeBlockTheme!.font.pointSize * 1.5)
        #expect(scaled.codeBlockTheme?.tokenColors == base.codeBlockTheme?.tokenColors)
        #expect(scaled.linkColor == base.linkColor)
        #expect(scaled.blockquoteColor == base.blockquoteColor)
        #expect(scaled.mermaidRenderingMode == base.mermaidRenderingMode)
        #expect(base.scaled(by: 1).bodyFont.pointSize == base.bodyFont.pointSize)
        #expect(base.scaled(by: 0).bodyFont.pointSize == base.bodyFont.pointSize, "a nonsense scale is ignored")
        #expect(base.scaled(by: .nan).bodyFont.pointSize == base.bodyFont.pointSize)
    }

    @Test("The renderer re-renders blocks at the new scale without changing the parse")
    func rendererRescales() async throws {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer(theme: .default()) { await assembler.block($0) }
        let markdown = "# Title\n\nSome **bold** body text.\n\n```swift\nlet x = 1\n```\n\n- an item\n"
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed(markdown)))
        _ = await renderer.apply(await assembler.apply(await tokenizer.finish()))

        let before = await renderer.renderedBlocks()
        let baseBody = try #require(firstFont(in: before[1])).pointSize
        let baseHeading = try #require(firstFont(in: before[0])).pointSize
        let baseCode = try #require(firstFont(in: before[2])).pointSize

        let rescaled = try #require(await renderer.updateTextScale(2))
        #expect(rescaled.map(\.id) == before.map(\.id))
        #expect(rescaled.map(\.kind) == before.map(\.kind))
        #expect(rescaled.map(\.snapshot) == before.map(\.snapshot), "snapshots are untouched")
        #expect(try #require(firstFont(in: rescaled[1])).pointSize == baseBody * 2)
        #expect(try #require(firstFont(in: rescaled[0])).pointSize == baseHeading * 2)
        #expect(try #require(firstFont(in: rescaled[2])).pointSize == baseCode * 2)
        #expect(await renderer.renderedBlocks() == rescaled, "the renderer keeps the rescaled presentation")

        #expect(await renderer.updateTextScale(2) == nil, "an unchanged scale is a no-op")

        let restored = try #require(await renderer.updateTextScale(1))
        #expect(try #require(firstFont(in: restored[1])).pointSize == baseBody)
        // Dynamic colors are fresh objects on every render, so attributed
        // content is never equal across renders; compare what scaling touches.
        for (index, pair) in zip(restored, before).enumerated() {
            #expect(String(pair.0.content.characters) == String(pair.1.content.characters), "block \(index)")
            #expect(firstFont(in: pair.0)?.pointSize == firstFont(in: pair.1)?.pointSize, "block \(index)")
        }
    }

    @Test("A scale change in the middle of a stream keeps the stream and applies to later blocks")
    func pipelineKeepsStreaming() async throws {
        let pipeline = MarkdownStreamingPipeline(theme: .default())
        let first = try #require(await pipeline.feed("First paragraph.\n\nSecond paragraph still"))
        let baseSize = try #require(firstFont(in: first.blocks[0])).pointSize

        let rescaled = try #require(await pipeline.updateTextScale(1.5))
        #expect(rescaled.map(\.id) == first.blocks.map(\.id))
        #expect(try #require(firstFont(in: rescaled[0])).pointSize == baseSize * 1.5)

        let more = try #require(await pipeline.feed(" streaming.\n\nThird paragraph.\n"))
        let finished = await pipeline.finish()
        let blocks = finished?.blocks ?? more.blocks
        #expect(blocks.count == 3, "the stream continued in the same document")
        #expect(blocks.map(\.id).prefix(2) == first.blocks.map(\.id).prefix(2))
        #expect(String(blocks[1].content.characters).contains("Second paragraph still streaming."))
        for block in blocks {
            #expect(try #require(firstFont(in: block)).pointSize == baseSize * 1.5, "new blocks use the scaled fonts")
        }
    }

    @Test("Refreshing a block after a scale change uses the scaled fonts")
    func refreshAfterScale() async throws {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer(theme: .default()) { await assembler.block($0) }
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed("Hello world.\n\n")))
        let base = try #require(firstFont(in: await renderer.renderedBlocks()[0])).pointSize
        _ = await renderer.updateTextScale(1.25)
        let id = await renderer.renderedBlocks()[0].id
        _ = await renderer.refreshBlocks([id])
        #expect(try #require(firstFont(in: await renderer.renderedBlocks()[0])).pointSize == base * 1.25)
    }

    @Test("A scale render that overlaps a streamed append keeps the newer text")
    func scaleRenderKeepsStreamedText() async throws {
        let provider = GatedImageProvider()
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer(theme: .default(), imageProvider: provider) { await assembler.block($0) }
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed("![pic](https://example.com/p.png) first")))
        let before = try #require(await renderer.renderedBlocks().first)
        let baseSize = try #require(lastFont(in: before)).pointSize

        // The scaled render of the block stops at the image; meanwhile the
        // stream appends to the same block and that refresh lands.
        await provider.holdNextCall()
        let rescale = Task { await renderer.updateTextScale(1.5) }
        await provider.waitUntilHeld()
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed(" second\n\n")))
        #expect(String(try #require(await renderer.renderedBlocks().first).content.characters).contains("first second"))
        await provider.release()
        let rescaled = try #require(await rescale.value)

        let block = try #require(await renderer.renderedBlocks().first { $0.id == before.id })
        #expect(String(block.content.characters).contains("first second"), "the older snapshot's render must not land")
        #expect(try #require(lastFont(in: block)).pointSize == baseSize * 1.5)
        #expect(rescaled.first { $0.id == before.id } == block)
    }

    @Test("Overlapping scale requests leave the renderer at the scale it reports")
    func overlappingScaleRequestsAgree() async throws {
        for _ in 0..<10 {
            let tokenizer = MarkdownTokenizer()
            let assembler = MarkdownAssembler()
            let renderer = MarkdownRenderer(theme: .default()) { await assembler.block($0) }
            _ = await renderer.apply(await assembler.apply(await tokenizer.feed("Hello world.\n\n")))
            let base = try #require(firstFont(in: await renderer.renderedBlocks()[0])).pointSize

            async let first = renderer.updateTextScale(2)
            async let second = renderer.updateTextScale(3)
            _ = await (first, second)

            // Whichever request was overtaken installed nothing, so asking
            // for 3 again either is a no-op at 3 or moves there; it must
            // never be refused while the fonts still show 2.
            _ = await renderer.updateTextScale(3)
            #expect(try #require(firstFont(in: await renderer.renderedBlocks()[0])).pointSize == base * 3)
        }
    }

    @Test("Dynamic Type moves the theme body by the points a fresh default theme would use")
    func dynamicTypeScaleMatchesDefaultTheme() {
        // `default()` is the system body size plus two: when the body goes
        // from 17 to 21, a theme created now has 23, not 19 * 21 / 17.
        #expect(PicoMarkdownView.textScale(host: 1, dynamicBodySize: 21, baseline: 17, themeBodySize: 19) == CGFloat(23) / 19)
        #expect(PicoMarkdownView.textScale(host: 1, dynamicBodySize: 12, baseline: 17, themeBodySize: 19) == CGFloat(14) / 19)
        #expect(PicoMarkdownView.textScale(host: 2, dynamicBodySize: 17, baseline: 17, themeBodySize: 19) == 2)
        #expect(PicoMarkdownView.textScale(host: .nan, dynamicBodySize: 17, baseline: 17, themeBodySize: 19) == 1)
        #expect(PicoMarkdownView.textScale(host: 1, dynamicBodySize: 17, baseline: 0, themeBodySize: 19) == 1)
    }

    private func lastFont(in block: RenderedBlock) -> MarkdownFont? {
        let content = NSAttributedString(block.content)
        guard content.length > 0 else { return nil }
        return content.attribute(.font, at: content.length - 1, effectiveRange: nil) as? MarkdownFont
    }
}

/// Holds one `image(for:)` call at a gate until released; every other call
/// returns at once (with no image).
private actor GatedImageProvider: MarkdownImageProvider {
    private var held = false
    private var gate: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    func holdNextCall() { held = true }

    func image(for url: URL) async -> MarkdownImageResult? {
        guard held else { return nil }
        held = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate = continuation
            waiting?.resume()
            waiting = nil
        }
        return nil
    }

    /// Returns once the held call is waiting at the gate.
    func waitUntilHeld() async {
        guard gate == nil else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}
