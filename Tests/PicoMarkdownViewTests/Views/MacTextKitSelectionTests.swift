#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS TextKit 2 selection")
@MainActor
struct MacTextKitSelectionTests {
    @Test("Presentation refresh preserves a hosted table and its native selection")
    func presentationRefreshPreservesHostedIdentity() async throws {
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed("Before.\n\n| Name | Value |\n| --- | --- |\n| A | B |\n\nAfter.\n\n")
        _ = await pipeline.finish()
        controller.update(textView: view, blocks: await pipeline.blocksSnapshot(), diffs: [],
                          replaceToken: 1, configuration: .default(), documentIdentity: 42)
        let storage = try #require(view.textStorage)
        let attachment = try #require(hostedAttachment(in: storage))
        let selection = NSRange(location: 0, length: storage.length)
        view.setSelectedRange(selection)

        let scaled = try #require(await pipeline.updateTextScale(1.5))
        controller.update(textView: view, blocks: scaled, diffs: [],
                          replaceToken: 2, configuration: .default(), documentIdentity: 42)
        #expect(hostedAttachment(in: storage) === attachment)
        #expect(view.selectedRange() == selection)
        #expect(attachment.context.isSelected)
        #expect(view.textLayoutManager != nil)

        // A true input replacement gets new hosted state, even when IDs and
        // content happen to be identical to the previous document.
        controller.update(textView: view, blocks: scaled, diffs: [],
                          replaceToken: 3, configuration: .default(), documentIdentity: 43)
        #expect(hostedAttachment(in: storage) !== attachment)
        #expect(view.selectedRange().length == 0)
    }

    @Test("Streaming a selected paragraph tail keeps the earlier selected text")
    func appendingToSelectedTailPreservesSelectionStart() async throws {
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        let pipeline = MarkdownStreamingPipeline()
        let first = try #require(await pipeline.feed("First paragraph.\n\nOpen paragraph\n"))
        controller.update(textView: view, blocks: first.blocks, diffs: [first.diff],
                          replaceToken: 1, configuration: .default(), documentIdentity: 1)
        let storage = try #require(view.textStorage)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let oldLength = view.selectedRange().length
        let next = try #require(await pipeline.feed("new tail content\n"))
        controller.update(textView: view, blocks: next.blocks, diffs: [next.diff],
                          replaceToken: 1, configuration: .default(), documentIdentity: 1)
        #expect(storage.string.contains("new tail content"))
        #expect(view.selectedRange().location == 0)
        #expect(view.selectedRange().length >= oldLength)
        #expect(view.markdownForSelectionForTest.contains("First paragraph"))
        #expect(view.textLayoutManager != nil)
    }

    private func hostedAttachment(in storage: NSTextStorage) -> PicoHostedAttachment? {
        var result: PicoHostedAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if let attachment = value as? PicoHostedAttachment { result = attachment; stop.pointee = true }
        }
        return result
    }
}

private extension NSTextView {
    var markdownForSelectionForTest: String {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        _ = writeSelection(to: pasteboard, type: .string)
        return pasteboard.string(forType: .string) ?? ""
    }
}
#endif
