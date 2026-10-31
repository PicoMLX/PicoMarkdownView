import XCTest
import Observation
@testable import PicoMarkdownView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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

    func testRemoteImagePrefetchDoesNotBlockStreamingAndRefreshesBlock() async {
        let prefetchSuspended = expectation(description: "Image prefetch has suspended")
        let consumptionFinished = expectation(description: "Later chunks consume while prefetch is suspended")
        let provider = ControlledImagePrefetchProvider(prefetchSuspended: prefetchSuspended)
        let viewModel = await MainActor.run { MarkdownStreamingViewModel(imageProvider: provider) }

        let input = MarkdownStreamingInput.chunks([
            "Intro ![diagram](https://example.com/diagram.png) outro\n\n",
            "Tail paragraph\n\n"
        ])

        let consumeTask = Task {
            await viewModel.consume(input)
            consumptionFinished.fulfill()
        }

        let providerAsMarkdown: MarkdownImageProvider = provider
        XCTAssertTrue(providerAsMarkdown is any MarkdownImagePrefetchingProvider)

        await fulfillment(of: [prefetchSuspended, consumptionFinished], timeout: 30)
        let hasSuspendedPrefetch = await provider.hasSuspendedPrefetch
        XCTAssertTrue(hasSuspendedPrefetch, "Expected image prefetch to start and suspend")
        await drainMainQueue()
        let preRefreshBlocks = await MainActor.run { viewModel.blocks }
        XCTAssertTrue(renderedText(from: preRefreshBlocks).contains("Tail paragraph"),
                      "Later chunks should render even while image prefetch is suspended")
        XCTAssertTrue(renderedText(from: preRefreshBlocks).contains("diagram"),
                      "Fallback alt text should be shown before the image is cached")
        XCTAssertEqual(attachmentCount(in: preRefreshBlocks), 0)

        let imageRefreshed = expectation(description: "Prefetched image publishes a block-local refresh")
        await MainActor.run {
            withObservationTracking {
                _ = viewModel.blocks
            } onChange: {
                imageRefreshed.fulfill()
            }
        }
        await provider.resumePrefetches()
        await consumeTask.value
        await fulfillment(of: [imageRefreshed], timeout: 30)
        await drainMainQueue()
        let postRefreshBlocks = await MainActor.run { viewModel.blocks }
        XCTAssertGreaterThan(attachmentCount(in: postRefreshBlocks), 0,
                             "Expected a block-local refresh to insert the image attachment")
        let prefetchCallCount = await provider.prefetchCallCount()
        XCTAssertEqual(prefetchCallCount, 1)
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

private func attachmentCount(in blocks: [RenderedBlock]) -> Int {
    blocks.reduce(into: 0) { count, block in
        let ns = NSAttributedString(block.content)
        ns.enumerateAttribute(.attachment,
                              in: NSRange(location: 0, length: ns.length),
                              options: []) { value, _, _ in
            if value != nil {
                count += 1
            }
        }
    }
}

private actor ControlledImagePrefetchProvider: MarkdownImagePrefetchingProvider {
    private let result: MarkdownImageResult
    private let prefetchSuspended: XCTestExpectation
    private var cache: [URL: MarkdownImageResult] = [:]
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var callCount = 0
    private var isReleased = false

    init(prefetchSuspended: XCTestExpectation) {
        self.prefetchSuspended = prefetchSuspended
        let size = CGSize(width: 32, height: 20)
        self.result = MarkdownImageResult(image: makeTestImage(size: size), size: size)
    }

    var hasSuspendedPrefetch: Bool {
        !continuations.isEmpty
    }

    func prefetchCallCount() -> Int {
        callCount
    }

    func resumePrefetches() {
        isReleased = true
        let pending = continuations
        continuations.removeAll(keepingCapacity: true)
        for continuation in pending {
            continuation.resume()
        }
    }

    func image(for url: URL) async -> MarkdownImageResult? {
        cache[url]
    }

    func prefetch(_ url: URL) async -> MarkdownImageResult? {
        callCount += 1
        if let cached = cache[url] {
            return cached
        }

        if !isReleased {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
                prefetchSuspended.fulfill()
            }
        }

        cache[url] = result
        return result
    }
}

private func makeTestImage(size: CGSize) -> MarkdownImage {
    #if canImport(UIKit)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { context in
        UIColor.systemGreen.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
    #else
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.systemGreen.setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
    image.unlockFocus()
    return image
    #endif
}
