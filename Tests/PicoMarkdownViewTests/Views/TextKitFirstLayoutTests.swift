#if canImport(AppKit)
import XCTest
@testable import PicoMarkdownView
import AppKit

/// Regression coverage for the cold-launch "first render garbled" bug.
///
/// On a cold launch the macOS text view starts receiving streamed edits before
/// SwiftUI assigns it a frame (`bounds.width == 0`). The view must NOT measure
/// itself by laying out at an infinite container width in that state — doing so
/// mis-sizes the content and leaves stale glyph fragments stacked at the top
/// until a later relayout corrects it. Instead it defers (reports
/// `noIntrinsicMetric`) until a real width is known; the existing
/// `layout()`/`viewDidMoveToWindow()` invalidation then supplies the real size.
///
/// The full timing race needs a live window/run-loop, but the underlying sizing
/// contract is exercised directly here: zero width → deferred height; real width
/// → a finite, positive height.
@MainActor
final class TextKitFirstLayoutTests: XCTestCase {
    func testTextKit1DefersHeightUntilWidthIsKnown() {
        let controller = TextKitStreamingController()
        let config = PicoTextKitConfiguration() // isScrollEnabled == false → intrinsic sizing
        let view = controller.makeTextKit1View(configuration: config)
        assertDefersHeightUntilWidthIsKnown(view, controller: controller, configuration: config)
    }

    func testTextKit2DefersHeightUntilWidthIsKnown() {
        let controller = TextKitStreamingController()
        let config = PicoTextKitConfiguration()
        let view = controller.makeTextKit2View(configuration: config)
        assertDefersHeightUntilWidthIsKnown(view, controller: controller, configuration: config)
    }

    private func assertDefersHeightUntilWidthIsKnown(_ view: NSTextView,
                                                     controller: TextKitStreamingController,
                                                     configuration: PicoTextKitConfiguration,
                                                     file: StaticString = #filePath,
                                                     line: UInt = #line) {
        // Populate the view's backing storage with content that wraps onto several
        // lines at a narrow width but collapses to one line at infinite width.
        let text = "Markdown: Syntax — a heading-length paragraph long enough to wrap "
            + "onto multiple lines when the container is constrained to a narrow width."
        let block = makeParagraphBlock(id: 1, text: text)
        controller.update(textView: view, blocks: [block], diffs: [], replaceToken: 1, configuration: configuration)

        // Before a frame is assigned (the cold-launch state) the view must defer
        // rather than lay out at infinite width.
        view.frame = .zero
        XCTAssertEqual(view.intrinsicContentSize.height,
                       NSView.noIntrinsicMetric,
                       "At bounds.width == 0 the view must defer its height, not measure at infinite width",
                       file: file, line: line)

        // Once a real width is assigned the view reports a finite, positive height.
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 0)
        let measured = view.intrinsicContentSize.height
        XCTAssertNotEqual(measured, NSView.noIntrinsicMetric,
                          "With a real width the view must report a concrete height",
                          file: file, line: line)
        XCTAssertGreaterThan(measured, 0,
                             "Measured height should be positive for non-empty content",
                             file: file, line: line)
    }

    private func makeParagraphBlock(id: BlockID, text: String) -> RenderedBlock {
        let snapshot = BlockSnapshot(id: id,
                                     kind: .paragraph,
                                     inlineRuns: nil,
                                     codeText: nil,
                                     mathText: nil,
                                     table: nil,
                                     isClosed: true,
                                     parentID: nil,
                                     depth: 0,
                                     childIDs: [])
        return RenderedBlock(id: id,
                             kind: .paragraph,
                             content: AttributedString(text),
                             snapshot: snapshot,
                             table: nil,
                             listItem: nil,
                             blockquote: nil,
                             math: nil,
                             images: [],
                             codeBlock: nil)
    }
}
#endif
