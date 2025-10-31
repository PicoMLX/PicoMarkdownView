import XCTest
@testable import PicoMarkdownView

final class MarkdownStreamingViewModelTests: XCTestCase {
    func testChunkFeedingUpdatesAttributedString() async {
        let viewModel = await MainActor.run { MarkdownStreamingViewModel() }
        let input = MarkdownStreamingInput.chunks(["Hello ", "world", "\n\n"])

        await viewModel.consume(input)

        let result = await MainActor.run { viewModel.attributedText }
        XCTAssertEqual(String(result.characters), "Hello world\n")
    }

    func testTextReplacementOverwritesExistingContent() async {
        let viewModel = await MainActor.run { MarkdownStreamingViewModel() }

        await viewModel.consume(.text("the"))
        var result = await MainActor.run { viewModel.attributedText }
        XCTAssertEqual(String(result.characters), "the\n")

        await viewModel.consume(.text("the sky"))
        result = await MainActor.run { viewModel.attributedText }
        XCTAssertEqual(String(result.characters), "the sky\n")

        await viewModel.consume(.text("the sky is"))
        result = await MainActor.run { viewModel.attributedText }
        XCTAssertEqual(String(result.characters), "the sky is\n")
    }
}
