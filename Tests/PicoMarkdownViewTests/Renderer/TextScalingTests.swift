import Foundation
import Testing
@testable import PicoMarkdownView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite @MainActor
struct TextScalingTests {
    @Test("Live scaling preserves parser state, block IDs, and selection")
    func liveScalingPreservesStream() async throws {
        let pipeline = MarkdownStreamingPipeline()
        let initial = try #require(await pipeline.feed("## Heading\n\nHello "))
        let backend = TextKitStreamingBackend()
        _ = backend.apply(blocks: initial.blocks, selection: NSRange(location: 0, length: 0))
        let selected = NSRange(location: 0, length: backend.length)
        let scaled = try #require(await pipeline.updateTextScale(2))
        #expect(scaled.blocks.map(\.id) == initial.blocks.map(\.id))
        #expect(scaled.blocks.map(\.snapshot) == initial.blocks.map(\.snapshot))
        #expect(scaled.diff.changes.allSatisfy {
            if case .blockEnded = $0 { return true }
            return false
        })
        let selection = backend.apply(blocks: scaled.blocks, diffs: [scaled.diff], selection: selected)
        #expect(selection == selected)
        for (before, after) in zip(initial.blocks, scaled.blocks) {
            #expect(try font(in: after).pointSize == font(in: before).pointSize * 2)
        }
        #expect(await pipeline.updateTextScale(2) == nil)
        _ = await pipeline.feed("world\n\n")
        _ = await pipeline.finish()
        let finished = await pipeline.blocksSnapshot()
        #expect(finished.map(\.id) == initial.blocks.map(\.id))
        #expect(finished.map { String($0.content.characters) }.joined() == "Heading\nHello world\n")
        #expect(try font(in: finished[1]).pointSize == font(in: scaled.blocks[1]).pointSize)
    }

    @Test("Code, table math, display math, and styled quotes scale together")
    func scaledAttachmentsAndStyles() async throws {
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed("> **bold** and `code` [link](https://example.com)\n\n```swift\nlet x = 1\n```\n\n| Formula |\n| --- |\n| $\\frac{1}{\\sqrt{x}}$ |\n\n$$x^2$$\n")
        _ = await pipeline.finish()
        let before = await pipeline.blocksSnapshot()
        let after = try #require(await pipeline.updateTextScale(2)).blocks
        #expect(after.map(\.snapshot) == before.map(\.snapshot))
        let quote = try #require(after.first(where: { $0.kind == .blockquote }))
        let quoted = NSAttributedString.picoConverted(from: quote.content)
        let boldFont = try #require(quoted.attribute(.font, at: 0, effectiveRange: nil) as? MarkdownFont)
        #if canImport(UIKit)
        #expect(boldFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        #else
        #expect(boldFont.fontDescriptor.symbolicTraits.contains(.bold))
        #endif
        let codeRange = (quoted.string as NSString).range(of: "code")
        let codeFont = try #require(quoted.attribute(.font, at: codeRange.location, effectiveRange: nil) as? MarkdownFont)
        #expect(codeFont.pointSize == MarkdownRenderTheme.default().codeFont.pointSize * 2)
        let mathBefore = try #require(before.first(where: { $0.math != nil })?.math)
        let mathAfter = try #require(after.first(where: { $0.math != nil })?.math)
        #expect(mathAfter.fontSize == mathBefore.fontSize * 2)
        let tableBefore = try #require(before.first(where: { $0.table != nil }))
        let tableAfter = try #require(after.first(where: { $0.table != nil }))
        let small = try attachmentBounds(in: tableBefore)
        let large = try attachmentBounds(in: tableAfter)
        #expect(large.height > small.height)
        #expect(large.width > small.width)
        let fenced = try #require(after.first(where: { $0.codeBlock != nil }))
        let fencedBefore = try #require(before.first(where: { $0.codeBlock != nil }))
        #expect(try font(in: fenced).pointSize == font(in: fencedBefore).pointSize * 2)
    }

    @Test("Invalid scale falls back to the base theme")
    func invalidScale() async throws {
        let theme = MarkdownRenderTheme.default()
        for factor in [CGFloat.nan, .infinity, 0, -1] {
            #expect(theme.scaled(by: factor).bodyFont == theme.bodyFont)
        }
    }

    @Test("Scale changes overlapping chunks never discard text")
    func scaleChangesDuringStreaming() async throws {
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed("Start")
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<100 { _ = await pipeline.feed(" word") }
            }
            group.addTask {
                for scale in [CGFloat(1.5), 2, 1] { _ = await pipeline.updateTextScale(scale) }
            }
        }
        _ = await pipeline.feed("\n\n")
        _ = await pipeline.finish()
        let blocks = await pipeline.blocksSnapshot()
        #expect(blocks.count == 1)
        let text = String(try #require(blocks.first).content.characters)
        #expect(text == "Start" + String(repeating: " word", count: 100) + "\n")
        #expect(try font(in: blocks[0]).pointSize == MarkdownRenderTheme.default().bodyFont.pointSize)
    }

    private func font(in block: RenderedBlock) throws -> MarkdownFont {
        try #require(NSAttributedString.picoConverted(from: block.content).attribute(.font, at: 0, effectiveRange: nil) as? MarkdownFont)
    }

    private func attachmentBounds(in block: RenderedBlock) throws -> CGRect {
        let content = NSAttributedString.picoConverted(from: block.content)
        var bounds: CGRect?
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, stop in
            if let attachment = value as? NSTextAttachment {
                bounds = attachment.bounds
                stop.pointee = true
            }
        }
        return try #require(bounds)
    }
}
