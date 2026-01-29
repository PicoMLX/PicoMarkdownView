import XCTest
@testable import PicoMarkdownView

final class MarkdownStreamingViewModelTests: XCTestCase {
    func testChunkFeedingUpdatesAttributedString() async {
        let viewModel = await MainActor.run { MarkdownStreamingViewModel() }
        let input = MarkdownStreamingInput.chunks(["Hello ", "world", "\n\n"])

        await viewModel.consume(input)

        await drainMainQueue()
        let blocks = await MainActor.run { viewModel.blocks }
        XCTAssertEqual(renderedText(from: blocks), "Hello world\n")
    }

    func testTextReplacementOverwritesExistingContent() async {
        let viewModel = await MainActor.run { MarkdownStreamingViewModel() }

        await viewModel.consume(.text("the"))
        await drainMainQueue()
        var blocks = await MainActor.run { viewModel.blocks }
        XCTAssertEqual(renderedText(from: blocks), "the\n")

        await viewModel.consume(.text("the sky"))
        await drainMainQueue()
        blocks = await MainActor.run { viewModel.blocks }
        XCTAssertEqual(renderedText(from: blocks), "the sky\n")

        await viewModel.consume(.text("the sky is"))
        await drainMainQueue()
        blocks = await MainActor.run { viewModel.blocks }
        XCTAssertEqual(renderedText(from: blocks), "the sky is\n")
    }
}

private func renderedText(from blocks: [RenderedBlock]) -> String {
    blocks.map { String($0.content.characters) }.joined()
}

private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}
