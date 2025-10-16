import XCTest
@testable import PicoMarkdownView

final class MathRenderingPipelineTests: XCTestCase {
    private var builder: MarkdownAttributeBuilder!
    private var theme: MarkdownRenderTheme!

    override func setUp() async throws {
        theme = .default()
        builder = MarkdownAttributeBuilder(theme: theme)
    }

    func testRenderedMathBlockUsesSnapshotText() async throws {
        let snapshot = BlockSnapshot(id: 1,
                                     kind: .math(display: true),
                                     inlineRuns: nil,
                                     mathText: "x^{2} + y^{2} = z^{2}",
                                     isClosed: true)
        let result = await builder.render(snapshot: snapshot)

        let renderedMath = try XCTUnwrap(result.math)
        XCTAssertEqual(renderedMath.tex, "x^{2} + y^{2} = z^{2}")
        XCTAssertTrue(renderedMath.display)
        XCTAssertEqual(renderedMath.fontSize, theme.bodyFont.pointSize, accuracy: 0.001)
    }

    func testRenderedMathFallsBackToInlineRunsWhenMathTextMissing() async throws {
        let runs = [InlineRun(text: "\\alpha + \\beta")]
        let snapshot = BlockSnapshot(id: 2,
                                     kind: .math(display: false),
                                     inlineRuns: runs,
                                     mathText: nil,
                                     isClosed: true)

        let result = await builder.render(snapshot: snapshot)
        let renderedMath = try XCTUnwrap(result.math)
        XCTAssertEqual(renderedMath.tex, "\\alpha + \\beta")
        XCTAssertFalse(renderedMath.display)
    }
}
