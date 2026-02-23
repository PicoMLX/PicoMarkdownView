import XCTest
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
        let provider = ControlledImagePrefetchProvider()
        let viewModel = await MainActor.run { MarkdownStreamingViewModel(imageProvider: provider) }

        let input = MarkdownStreamingInput.chunks([
            "Intro ![diagram](https://example.com/diagram.png) outro\n\n",
            "Tail paragraph\n\n"
        ])

        let consumeTask = Task {
            await viewModel.consume(input)
        }

        let providerAsMarkdown: MarkdownImageProvider = provider
        XCTAssertTrue(providerAsMarkdown is any MarkdownImagePrefetchingProvider)

        var prefetchStarted = false
        for _ in 0..<200 {
            if await provider.hasSuspendedPrefetch {
                prefetchStarted = true
                break
            }
            await drainMainQueue()
            await Task.yield()
        }
        XCTAssertTrue(prefetchStarted, "Expected image prefetch to start and suspend")

        var preRefreshBlocks: [RenderedBlock] = []
        var sawTailWhileSuspended = false
        for _ in 0..<200 {
            await drainMainQueue()
            preRefreshBlocks = await MainActor.run { viewModel.blocks }
            let text = renderedText(from: preRefreshBlocks)
            if text.contains("Tail paragraph") {
                sawTailWhileSuspended = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(sawTailWhileSuspended,
                      "Later chunks should render even while image prefetch is suspended")
        XCTAssertTrue(renderedText(from: preRefreshBlocks).contains("diagram"),
                      "Fallback alt text should be shown before the image is cached")
        XCTAssertEqual(attachmentCount(in: preRefreshBlocks), 0)

        await provider.resumePrefetches()
        await consumeTask.value

        var postRefreshBlocks: [RenderedBlock] = []
        var attachmentSeen = false
        for _ in 0..<200 {
            await drainMainQueue()
            postRefreshBlocks = await MainActor.run { viewModel.blocks }
            if attachmentCount(in: postRefreshBlocks) > 0 {
                attachmentSeen = true
                break
            }
            await Task.yield()
        }

        XCTAssertTrue(attachmentSeen, "Expected a block-local refresh to insert the image attachment")
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
    private var cache: [URL: MarkdownImageResult] = [:]
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var callCount = 0

    init() {
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

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
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
