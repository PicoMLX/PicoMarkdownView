#if DEBUG

import XCTest
@testable import PicoMarkdownView

final class DebugBlockFormatterTests: XCTestCase {
    func testFormatsParagraphWithInlineRuns() {
        let runs: [InlineRun] = [
            InlineRun(text: "Hello"),
            InlineRun(text: "World", style: [.bold])
        ]

        let snapshot = BlockSnapshot(id: 42,
                                      kind: .paragraph,
                                      inlineRuns: runs,
                                      isClosed: true,
                                      parentID: nil,
                                      depth: 0,
                                      childIDs: [])

        let block = RenderedBlock(id: 42,
                                  kind: .paragraph,
                                  content: AttributedString("HelloWorld"),
                                  snapshot: snapshot,
                                  table: nil,
                                  listItem: nil,
                                  blockquote: nil,
                                  math: nil,
                                  images: [],
                                  codeBlock: nil)

        let formatter = DebugBlockFormatter()
        let lines = formatter.makeLines(from: [block])

        XCTAssertEqual(lines.first, "paragraph")
        XCTAssertTrue(lines.contains("  text: \"Hello\""))
        XCTAssertTrue(lines.contains("  strong: \"World\""))
    }

    func testFormatsMathBlock() {
        let math = RenderedMath(tex: "x^{2}", display: true, fontSize: 16)
        let snapshot = BlockSnapshot(id: 7,
                                      kind: .math(display: true),
                                      inlineRuns: nil,
                                      mathText: math.tex,
                                      isClosed: true,
                                      parentID: nil,
                                      depth: 0,
                                      childIDs: [])

        let block = RenderedBlock(id: 7,
                                  kind: .math(display: true),
                                  content: AttributedString(math.tex),
                                  snapshot: snapshot,
                                  table: nil,
                                  listItem: nil,
                                  blockquote: nil,
                                  math: math,
                                  images: [],
                                  codeBlock: nil)

        let formatter = DebugBlockFormatter()
        let lines = formatter.makeLines(from: [block])

        XCTAssertEqual(lines.first, "mathBlock")
        XCTAssertTrue(lines.contains("  tex: \"x^{2}\""))
    }
}

#endif
