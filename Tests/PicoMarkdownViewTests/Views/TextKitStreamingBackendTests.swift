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

    func testChildInsertionSyncsRefreshedParentRecord() {
        let backend = TextKitStreamingBackend()

        // Streamed split-marker scenario: the parent quote is inserted as a
        // blank quoted line before its child exists…
        let blankParent = makeBlock(id: 1, text: "\n", kind: .blockquote)
        let insertParent = AssemblerDiff(documentVersion: 1,
                                         changes: [.blockStarted(id: 1, kind: .blockquote, position: 0)])
        _ = backend.apply(blocks: [blankParent], diffs: [insertParent], selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(backend.snapshotAttributedString().string, "\n")

        // …then the child arrives. The renderer re-renders the parent as
        // empty (container-only), and the diff only mentions the child — the
        // backend must sync the parent record too.
        let emptyParent = makeBlock(id: 1, text: "", kind: .blockquote)
        let child = makeBlock(id: 2, text: "nested\n", kind: .blockquote, parentID: 1, depth: 1)
        let insertChild = AssemblerDiff(documentVersion: 2,
                                        changes: [.blockStarted(id: 2, kind: .blockquote, position: 1)])
        _ = backend.apply(blocks: [emptyParent, child],
                          diffs: [insertChild],
                          selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(backend.snapshotAttributedString().string, "nested\n",
                       "stale blank parent line must be removed when its child streams in")
    }

    private func makeBlock(id: BlockID,
                           text: String,
                           kind: BlockKind = .paragraph,
                           parentID: BlockID? = nil,
                           depth: Int = 0) -> RenderedBlock {
        let snapshot = BlockSnapshot(id: id,
                                     kind: kind,
                                     inlineRuns: nil,
                                     codeText: nil,
                                     mathText: nil,
                                     table: nil,
                                     isClosed: true,
                                     parentID: parentID,
                                     depth: depth,
                                     childIDs: [])
        return RenderedBlock(id: id,
                             kind: kind,
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
