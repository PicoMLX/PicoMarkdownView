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

    @Test("Ordered list with nested sub-items: paragraph not merged into list")
    func orderedListParagraphNotMerged() async {
        let markdown = """
        Here is a list with sub-items:

        1.  **Header Item**
            *   Sub-item A
            *   Sub-item B
            *   Sub-item C

        2.  **Main Category**
            *   Sub-point 1
            *   Sub-point 2
            *   Sub-point 3

        3.  **Simple List**
            *   Item One
            *   Item Two
            *   Item Three

        Would you like to try adding more complex nesting (like lists within lists) or something else?

        """

        // Single-shot
        let singlePipeline = MarkdownStreamingPipeline()
        _ = await singlePipeline.feed(markdown)
        _ = await singlePipeline.finish()
        let singleBlocks = await singlePipeline.blocksSnapshot()

        // Streaming word-by-word
        let streamPipeline = MarkdownStreamingPipeline()
        let chunks = wordChunks(markdown)
        for chunk in chunks {
            _ = await streamPipeline.feed(chunk)
        }
        _ = await streamPipeline.finish()
        let streamBlocks = await streamPipeline.blocksSnapshot()

        // The trailing paragraph must be its own block, not merged into any list item
        let singleTexts = singleBlocks.map { String($0.content.characters) }
        let streamTexts = streamBlocks.map { String($0.content.characters) }

        // Find the trailing paragraph in single-shot
        let singleHasTrailingParagraph = singleTexts.contains { $0.contains("Would you like") }
        #expect(singleHasTrailingParagraph, "Single-shot should have trailing paragraph as a block")

        let streamHasTrailingParagraph = streamTexts.contains { $0.contains("Would you like") }
        #expect(streamHasTrailingParagraph, "Streaming should have trailing paragraph as a block")

        // The trailing paragraph must NOT be in the same block as "Simple List"
        let mergedBlock = streamTexts.first { $0.contains("Simple List") && $0.contains("Would you like") }
        #expect(mergedBlock == nil, "Trailing paragraph must not be merged with list item 3. Got: \(mergedBlock ?? "")")

        // Block counts should match
        #expect(streamBlocks.count == singleBlocks.count,
                "Block count mismatch: stream=\(streamBlocks.count) single=\(singleBlocks.count)\nStream: \(streamTexts)\nSingle: \(singleTexts)")
    }

    private func wordChunks(_ text: String) -> [String] {
        var result: [String] = []
        var chunk = ""
        var wordSeen = false
        for character in text {
            chunk.append(character)
            if character.isWhitespace {
                if wordSeen {
                    result.append(chunk)
                    chunk.removeAll(keepingCapacity: true)
                    wordSeen = false
                }
            } else {
                wordSeen = true
            }
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
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
