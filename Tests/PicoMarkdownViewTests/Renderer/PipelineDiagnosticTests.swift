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

    @Test("Full nested list document renders all content during streaming")
    func fullNestedListDocumentStreaming() async {
        let markdown = """
        ### 3. Project Management Style
        *Best for Agile sprints, product roadmaps, or team meeting agendas.*

        1.  **Sprint Objectives**
            *   Feature completion
            *   Code review pass rate
            *   User acceptance testing
        2.  **Team Roles**
            *   Project Manager
            *   Senior Developer
            *   QA Engineer
        3.  **Release Schedule**
            *   Week 1: Development
            *   Week 2: Testing
            *   Week 3: Deployment

        ### 4. Creative & Descriptive Style
        *Best for blogs, feature descriptions, or marketing materials.*

        1.  **Eco-Friendly Design**
            *   Minimalist aesthetics
            *   Renewable energy features
            *   Biodegradable materials

        """

        // Stream word-by-word
        let pipeline = MarkdownStreamingPipeline()
        let chunks = wordChunks(markdown)
        var lastBlocks: [RenderedBlock] = []
        var updateCount = 0
        for chunk in chunks {
            if let update = await pipeline.feed(chunk) {
                lastBlocks = update.blocks
                updateCount += 1
            }
        }
        if let update = await pipeline.finish() {
            lastBlocks = update.blocks
            updateCount += 1
        }

        let allText = lastBlocks.map { String($0.content.characters) }.joined()

        // Check that key content from all sections is present
        #expect(allText.contains("Sprint Objectives"), "Missing Sprint Objectives")
        #expect(allText.contains("Feature completion"), "Missing Feature completion")
        #expect(allText.contains("Team Roles"), "Missing Team Roles")
        #expect(allText.contains("QA Engineer"), "Missing QA Engineer")
        #expect(allText.contains("Release Schedule"), "Missing Release Schedule")
        #expect(allText.contains("Week 1: Development"), "Missing Week 1")
        #expect(allText.contains("Week 3: Deployment"), "Missing Week 3")
        #expect(allText.contains("Creative"), "Missing Creative heading")
        #expect(allText.contains("Eco-Friendly"), "Missing Eco-Friendly")
        #expect(allText.contains("Biodegradable"), "Missing Biodegradable")

        // Should have produced multiple updates during streaming
        #expect(updateCount > 5, "Expected many updates during streaming, got \(updateCount)")

        // Compare with single-shot
        let singlePipeline = MarkdownStreamingPipeline()
        _ = await singlePipeline.feed(markdown)
        _ = await singlePipeline.finish()
        let singleBlocks = await singlePipeline.blocksSnapshot()

        #expect(lastBlocks.count == singleBlocks.count,
                "Block count mismatch: stream=\(lastBlocks.count) single=\(singleBlocks.count)")
    }

    @Test("TextKit backend receives all streaming updates")
    func textKitBackendReceivesAllUpdates() async {
        let markdown = """
        ### 3. Project Management Style
        *Best for Agile sprints, product roadmaps, or team meeting agendas.*

        1.  **Sprint Objectives**
            *   Feature completion
            *   Code review pass rate
            *   User acceptance testing
        2.  **Team Roles**
            *   Project Manager
            *   Senior Developer
            *   QA Engineer
        3.  **Release Schedule**
            *   Week 1: Development
            *   Week 2: Testing
            *   Week 3: Deployment

        ### 4. Creative & Descriptive Style

        """

        let pipeline = MarkdownStreamingPipeline()
        let backend = await TextKitStreamingBackend()
        let chunks = wordChunks(markdown)
        var lastAppliedVersion: UInt64 = 0

        for chunk in chunks {
            if let update = await pipeline.feed(chunk) {
                // Filter eligible diffs (same logic as controller)
                let eligible = update.diff.documentVersion > lastAppliedVersion ? [update.diff] : []
                if !eligible.isEmpty {
                    _ = await MainActor.run {
                        backend.apply(blocks: update.blocks, diffs: eligible, selection: NSRange(location: 0, length: 0))
                    }
                    lastAppliedVersion = update.diff.documentVersion
                }
            }
        }
        if let update = await pipeline.finish() {
            let eligible = update.diff.documentVersion > lastAppliedVersion ? [update.diff] : []
            if !eligible.isEmpty {
                _ = await MainActor.run {
                    backend.apply(blocks: update.blocks, diffs: eligible, selection: NSRange(location: 0, length: 0))
                }
                lastAppliedVersion = update.diff.documentVersion
            }
        }

        let text = await MainActor.run { backend.snapshotAttributedString().string }

        #expect(text.contains("Release Schedule"), "Missing Release Schedule in backend: \(text.prefix(200))")
        #expect(text.contains("Week 1"), "Missing Week 1 in backend")
        #expect(text.contains("Week 3"), "Missing Week 3 in backend")
        #expect(text.contains("Creative"), "Missing Creative heading in backend")
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
