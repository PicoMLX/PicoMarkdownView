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

        XCTAssertTrue(lines.contains(where: { $0.contains("paragraph") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("run bold") }))
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

        XCTAssertTrue(lines.contains(where: { $0.contains("math(display: true)") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("tex → x^{2}") }))
    }
}

#endif
