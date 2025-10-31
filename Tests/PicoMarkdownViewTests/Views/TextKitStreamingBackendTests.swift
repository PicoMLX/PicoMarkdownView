#if canImport(AppKit) || canImport(UIKit)
import XCTest
@testable import PicoMarkdownView

@MainActor
final class TextKitStreamingBackendTests: XCTestCase {
    func testInitialApplySetsAttributedString() {
        let backend = TextKitStreamingBackend()
        let block = makeBlock(id: 1, text: "Hello\n")

        let selection = backend.apply(blocks: [block], selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(selection.location, 0)
        // Backend now preserves newlines, spacing handled via paragraph styles
        XCTAssertEqual(backend.snapshotAttributedString().string, "Hello\n")
    }

    func testAppendMaintainsCaretPosition() {
        let backend = TextKitStreamingBackend()
        let initial = makeBlock(id: 1, text: "Hello")
        _ = backend.apply(blocks: [initial], selection: NSRange(location: 0, length: 0))

        let selection = NSRange(location: 5, length: 0)
        let updated = makeBlock(id: 1, text: "Hello world")
        let result = backend.apply(blocks: [updated], selection: selection)

        XCTAssertEqual(result.location, 11)
        XCTAssertEqual(result.length, 0)
        XCTAssertEqual(backend.snapshotAttributedString().string, "Hello world")
    }

    func testTrimsWhenSelectionBeyondEnd() {
        let backend = TextKitStreamingBackend()
        let block = makeBlock(id: 1, text: "Short")
        let selection = backend.apply(blocks: [block], selection: NSRange(location: 10, length: 0))

        XCTAssertEqual(selection.location, 5)
    }

    func testApplyReusesCachedAttributedStrings() {
        let backend = TextKitStreamingBackend()
        let block = makeBlock(id: 1, text: "Cached")

        _ = backend.apply(blocks: [block], selection: NSRange(location: 0, length: 0))
        let cachedFirst = backend.cachedAttributedString(forBlockAt: 0)

        _ = backend.apply(blocks: [block], selection: NSRange(location: 0, length: 0))
        let cachedSecond = backend.cachedAttributedString(forBlockAt: 0)

        XCTAssertNotNil(cachedFirst)
        XCTAssertTrue(cachedFirst === cachedSecond)
    }

    private func makeBlock(id: BlockID, text: String) -> RenderedBlock {
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
