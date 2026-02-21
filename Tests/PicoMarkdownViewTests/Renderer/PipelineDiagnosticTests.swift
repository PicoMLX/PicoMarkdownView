import Foundation
import Testing
@testable import PicoMarkdownView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite
struct PipelineDiagnosticTests {
    @Test("Pipeline feed and finish produce non-empty blocks")
    func pipelineReplaceProducesBlocks() async {
        let markdown = "# Hello\n\nThis is a test paragraph.\n\n- Item 1\n- Item 2\n"
        let pipeline = MarkdownStreamingPipeline()

        var blocks: [RenderedBlock] = []

        if let update = await pipeline.feed(markdown) {
            blocks = update.blocks
        }

        if let update = await pipeline.finish() {
            blocks = update.blocks
        }

        #expect(!blocks.isEmpty, "Pipeline should produce non-empty blocks for non-empty markdown")

        for block in blocks {
            let text = String(block.content.characters)
            #expect(!text.isEmpty, "Block \(block.id) should have non-empty content")
        }

        let totalText = blocks.map { String($0.content.characters) }.joined()
        #expect(totalText.contains("Hello"))
        #expect(totalText.contains("test paragraph"))
    }

    @Test("NSAttributedString conversion preserves content")
    func nsAttributedStringConversion() async {
        let pipeline = MarkdownStreamingPipeline()
        let markdown = "Hello world\n\n"

        _ = await pipeline.feed(markdown)
        _ = await pipeline.finish()
        let blocks = await pipeline.blocksSnapshot()

        for block in blocks {
            let nsStr = NSAttributedString(block.content)
            #expect(nsStr.length > 0, "NSAttributedString should have content for block \(block.id)")
        }
    }
}
