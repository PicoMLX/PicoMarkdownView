#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PicoMarkdownView

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MacTextKitRemountTests {
    @Test("Remounting restores native prose and the same hosted attachment before later streaming", arguments: [false, true])
    func reconnectRestoresRenderedDocument(withConsumedDiff: Bool) async throws {
        _ = NSApplication.shared
        let recorder = RemountFactoryRecorder()
        let renderer = PicoEmbeddedBlockRenderer(selectors: [.fencedCode(language: "html-preview")]) { context in
            recorder.contexts.append(context)
            return AnyView(Text(context.source).frame(height: 80))
        }
        let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [renderer])
        let initial = try #require(await pipeline.feed("Before **native**.\n\n```html-preview\n<div>Original HTML source</div>\n```\n\nTail"))
        let controller = TextKitStreamingController()
        let first = controller.makeTextKit2View(configuration: .default()) as! StreamingTextKit2View
        first.setFrameSize(NSSize(width: 400, height: 800))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 400, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = first
        defer { window.contentView = nil; window.close() }
        controller.update(textView: first, blocks: initial.blocks, diffs: [initial.diff], replaceToken: 1,
                          configuration: .default(), documentIdentity: 42)
        // Consume this version before remounting, so replaying it cannot hide
        // a lost storage document through a fresh pipeline update.
        controller.update(textView: first, blocks: initial.blocks, diffs: [initial.diff], replaceToken: 1,
                          configuration: .default(), documentIdentity: 42)
        first.layout()
        let originalStorage = try #require(first.textStorage)
        let originalDocument = NSAttributedString(attributedString: originalStorage)
        let originalAttachment = try #require(attachment(in: originalStorage))
        let originalContext = try #require(recorder.contexts.first)
        first.setSelectedRange(NSRange(location: 0, length: originalStorage.length))
        let originalCopy = first.markdownForSelection()
        window.contentView = nil

        let remounted = controller.makeTextKit2View(configuration: .default()) as! StreamingTextKit2View
        remounted.setFrameSize(NSSize(width: 400, height: 800))
        window.contentView = remounted
        let restoredStorage = try #require(remounted.textStorage)
        try #require(restoredStorage.isEqual(to: originalDocument), "Connecting the new native view must restore the rendered document without a new feed")
        controller.update(textView: remounted, blocks: initial.blocks,
                          diffs: withConsumedDiff ? [initial.diff] : [], replaceToken: 1,
                          configuration: .default(), documentIdentity: 42)
        remounted.layout()
        #expect(remounted.string.contains("Before native."))
        #expect(remounted.string.contains("Tail"))
        #expect(attachment(in: restoredStorage) === originalAttachment)
        #expect(recorder.contexts.count == 1)
        #expect(recorder.contexts.first === originalContext)
        #expect(remounted.textLayoutManager != nil)
        #expect(remounted.textContentStorage?.textStorage === restoredStorage)
        #expect(remounted.textLayoutManager?.textContentManager === remounted.textContentStorage)
        remounted.setSelectedRange(NSRange(location: 0, length: restoredStorage.length))
        #expect(remounted.markdownForSelection() == originalCopy)
        #expect(originalCopy.contains("```html-preview\n<div>Original HTML source</div>\n```"))
        #expect(!originalCopy.contains("\u{FFFC}"))

        let nativeSelection = NSRange(location: 0, length: 6)
        remounted.setSelectedRange(nativeSelection)
        let tail = try #require(await pipeline.feed(" continues after remount.\n\n"))
        controller.update(textView: remounted, blocks: tail.blocks, diffs: [tail.diff], replaceToken: 1,
                          configuration: .default(), documentIdentity: 42)
        #expect(remounted.string.contains("Tail continues after remount."))
        #expect(remounted.selectedRange() == nativeSelection)
        #expect(attachment(in: restoredStorage) === originalAttachment)
        #expect(recorder.contexts.count == 1, "Remounting and later deltas must reuse the source-backed presentation")
        #expect(remounted.textLayoutManager != nil)
    }

    private func attachment(in storage: NSTextStorage) -> PicoHostedAttachment? {
        var found: PicoHostedAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if let attachment = value as? PicoHostedAttachment {
                found = attachment
                stop.pointee = true
            }
        }
        return found
    }
}

@MainActor
private final class RemountFactoryRecorder {
    var contexts: [PicoEmbeddedBlockContext] = []
}
#endif
