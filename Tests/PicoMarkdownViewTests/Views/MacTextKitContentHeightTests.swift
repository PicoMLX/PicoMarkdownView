#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import PicoMarkdownView

@Suite("macOS native content height")
@MainActor
struct MacTextKitContentHeightTests {
    @Test("A fixed-height loading chart grows on closure and keeps its final paragraph visible")
    func chartLoadingGrowthKeepsScrolledTailVisible() async throws {
        _ = NSApplication.shared
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = NSRect(x: 0, y: 0, width: 336, height: 600)
        let document = ContentHeightDocumentView(frame: view.frame)
        document.addSubview(view)
        let scroll = NSScrollView(frame: view.frame)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        let source = try Self.largeInlineChartSource()
        #expect(VegaLiteSpecPolicy.accepts(source))
        let pipeline = MarkdownStreamingPipeline()
        for cycle in 1...3 {
            apply(await pipeline.feed("\n\n#### Chart \(cycle)\n\n```vega-lite\n"), controller, view)
            var index = source.startIndex
            while index < source.endIndex {
                let end = source.index(index, offsetBy: 2048, limitedBy: source.endIndex) ?? source.endIndex
                apply(await pipeline.feed(String(source[index..<end])), controller, view)
                resizeAndScrollToEnd(view, document: document, scroll: scroll)
                view.layoutSubtreeIfNeeded()
                index = end
            }
            let openHeight = view.intrinsicContentSize.height
            #expect(!view.string.contains(source), "Streaming JSON must stay outside native text storage")
            let loadingStorage = try #require(view.textStorage)
            var loadingAttachment: PicoHostedAttachment?
            loadingStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: loadingStorage.length)) { value, _, _ in
                if let attachment = value as? PicoHostedAttachment { loadingAttachment = attachment }
            }
            #expect(loadingAttachment?.bounds.height == 48)
            let tail = "Final paragraph after chart \(cycle)."
            apply(await pipeline.feed("```\n\n" + tail + "\n\n"), controller, view)
            for _ in 0..<6 {
                view.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            #expect(await pipeline.blocksSnapshot().compactMap(\.vegaLiteChart).filter { !$0.svg.isEmpty }.count == cycle)
            #expect(view.string.filter { $0 == "\u{FFFC}" }.count == cycle,
                    "The completed fences must become real hosted charts")
            let height = view.intrinsicContentSize.height
            let tailFrame = try paragraphFrame(containing: tail, in: view)
            #expect(abs(height - ceil(tailFrame.maxY + view.textContainerInset.height * 2)) <= 1,
                    "The document must end at its final paragraph after the code collapses")
            #expect(height > openHeight, "The ready chart must grow beyond its fixed 48-point loading row")
            resizeAndScrollToEnd(view, document: document, scroll: scroll)
            view.layoutSubtreeIfNeeded()
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let finalTail = try paragraphFrame(containing: tail, in: view)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            #expect(finalTail.intersects(view.visibleRect), "Scrolling to the end must reveal the final paragraph")
            await Task.yield()
        }
        apply(await pipeline.finish(), controller, view)
    }

    @Test("Native long-to-short replacement drops stale TextKit usage height")
    func nativeReplacementShrinksMeasuredDocument() throws {
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = NSRect(x: 0, y: 0, width: 336, height: 600)
        let storage = try #require(view.textStorage)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]
        let long = String(repeating: "A native code paragraph with enough text to wrap across the narrow document.\n", count: 512)
        storage.setAttributedString(NSAttributedString(string: long, attributes: attributes))
        let longHeight = view.intrinsicContentSize.height
        try #require(longHeight > 2_000)
        let short = "Only the final native paragraph remains.\n"
        storage.setAttributedString(NSAttributedString(string: short, attributes: attributes))
        let shortHeight = view.intrinsicContentSize.height
        #expect(storage.string == short)
        #expect(shortHeight > 0 && shortHeight < 100)
        #expect(shortHeight < longHeight / 10, "A removed long document must not survive in cached usage bounds")
        #expect(view.textLayoutManager != nil)
    }

    @Test("Empty content and trailing empty lines have finite intrinsic height")
    func emptyAndTrailingNewlineHeights() throws {
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = NSRect(x: 0, y: 0, width: 336, height: 600)
        #expect(view.intrinsicContentSize.height == 0)
        let storage = try #require(view.textStorage)
        let manager = try #require(view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        var previous: CGFloat = 0
        for text in ["Tail", "Tail\n", "Tail\n\n"] {
            storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            let height = view.intrinsicContentSize.height
            var maxY: CGFloat = 0
            manager.enumerateTextLayoutFragments(from: content.documentRange.location,
                                                options: [.ensuresLayout, .ensuresExtraLineFragment]) {
                maxY = max(maxY, $0.layoutFragmentFrame.maxY)
                return true
            }
            #expect(height.isFinite && height > 0)
            #expect(height >= previous)
            #expect(abs(height - ceil(maxY + view.textContainerInset.height * 2)) <= 1,
                    "Trailing empty lines must remain within the document height")
            previous = height
        }
        storage.setAttributedString(NSAttributedString(string: ""))
        #expect(view.intrinsicContentSize.height == 0)
    }

    private func resizeAndScrollToEnd(_ view: NSTextView, document: NSView, scroll: NSScrollView) {
        let height = max(1, view.intrinsicContentSize.height)
        view.setFrameSize(NSSize(width: 336, height: height))
        document.setFrameSize(view.frame.size)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func apply(_ update: StreamingUpdate?, _ controller: TextKitStreamingController, _ view: NSTextView) {
        guard let update else { return }
        controller.update(textView: view, blocks: update.blocks, diffs: [update.diff], replaceToken: 1,
                          configuration: .default(), documentIdentity: 1)
    }

    private func paragraphFrame(containing text: String, in view: NSTextView) throws -> CGRect {
        let range = (view.string as NSString).range(of: text)
        try #require(range.location != NSNotFound)
        let manager = try #require(view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: range.location))
        return try #require(manager.textLayoutFragment(for: location)).layoutFragmentFrame
    }

    private static func largeInlineChartSource() throws -> String {
        let rows: [[String: Any]] = (0..<256).map { ["x": $0, "y": $0 % 17, "padding": String(repeating: "s", count: 32)] }
        let spec: [String: Any] = [
            "data": ["values": rows], "mark": "point",
            "encoding": ["x": ["field": "x", "type": "quantitative"],
                         "y": ["field": "y", "type": "quantitative"]]
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: spec, options: .sortedKeys), as: UTF8.self) + "\n"
    }
}

@MainActor
private final class ContentHeightDocumentView: NSView {
    override var isFlipped: Bool { true }
}
#endif
