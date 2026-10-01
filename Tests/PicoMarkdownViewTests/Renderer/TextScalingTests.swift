import Foundation
import Testing
@testable import PicoMarkdownView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite @MainActor
struct TextScalingTests {
    @Test("Built-in themes use an unscaled body baseline")
    func builtInFontBaseline() {
        #if canImport(UIKit)
        let baseline = UIFont.preferredFont(forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        #else
        let baseline: CGFloat = 13
        #endif
        let theme = MarkdownRenderTheme.default()
        #expect(theme.bodyFont.pointSize == baseline + 2)
        #expect(theme.scaled(by: 2).bodyFont.pointSize == (baseline + 2) * 2)
        for code in [CodeBlockTheme.monospaced(), .prismDefault(), .gitHub()] {
            #expect(code.font.pointSize == baseline)
        }
    }

    @Test("Initial text scale is installed before text, chunk, and stream rendering")
    func initialScalePrecedesConsumption() async throws {
        let source = "![image](https://example.com/image.png)\n\n"
        let referenceProvider = YieldingImageProvider()
        let reference = MarkdownStreamingPipeline(imageProvider: referenceProvider)
        _ = await reference.feed(source)
        _ = await reference.finish()
        let referenceRenders = await referenceProvider.requestCount
        let inputs: [MarkdownStreamingInput] = [
            .text(source), .chunks([source]), .stream({ AsyncStream { $0.yield(source); $0.finish() } })
        ]
        for input in inputs {
            let provider = YieldingImageProvider()
            let model = MarkdownStreamingViewModel(imageProvider: provider)
            await model.consume(input, initialTextScale: 2)
            await drainPublication()
            #expect(try font(in: #require(model.blocks.first)).pointSize == MarkdownRenderTheme.default().bodyFont.pointSize * 2)
            #expect(await provider.requestCount == referenceRenders)
        }
    }

    @Test("Live scaling preserves parser state, block IDs, and selection")
    func liveScalingPreservesStream() async throws {
        let pipeline = MarkdownStreamingPipeline()
        let initial = try #require(await pipeline.feed("## Heading\n\nHello "))
        let backend = TextKitStreamingBackend()
        _ = backend.apply(blocks: initial.blocks, selection: NSRange(location: 0, length: 0))
        let selected = NSRange(location: 0, length: backend.length)
        let scaled = try #require(await pipeline.updateTextScale(2))
        #expect(scaled.blocks.map(\.id) == initial.blocks.map(\.id))
        #expect(scaled.blocks.map(\.snapshot) == initial.blocks.map(\.snapshot))
        #expect(scaled.diff.changes.allSatisfy {
            if case .blockEnded = $0 { return true }
            return false
        })
        let selection = backend.apply(blocks: scaled.blocks, diffs: [scaled.diff], selection: selected)
        #expect(selection == selected)
        for (before, after) in zip(initial.blocks, scaled.blocks) {
            #expect(try font(in: after).pointSize == font(in: before).pointSize * 2)
        }
        #expect(await pipeline.updateTextScale(2) == nil)
        _ = await pipeline.feed("world\n\n")
        _ = await pipeline.finish()
        let finished = await pipeline.blocksSnapshot()
        #expect(finished.map(\.id) == initial.blocks.map(\.id))
        #expect(finished.map { String($0.content.characters) }.joined() == "Heading\nHello world\n")
        #expect(try font(in: finished[1]).pointSize == font(in: scaled.blocks[1]).pointSize)
    }

    @Test("Code, table math, display math, and styled quotes scale together")
    func scaledAttachmentsAndStyles() async throws {
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed("> **bold** and `code` [link](https://example.com)\n\n```swift\nlet x = 1\n```\n\n| Formula |\n| --- |\n| $\\frac{1}{\\sqrt{x}}$ |\n\n$$x^2$$\n")
        _ = await pipeline.finish()
        let before = await pipeline.blocksSnapshot()
        let after = try #require(await pipeline.updateTextScale(2)).blocks
        #expect(after.map(\.snapshot) == before.map(\.snapshot))
        let quote = try #require(after.first(where: { $0.kind == .blockquote }))
        let quoted = NSAttributedString.picoConverted(from: quote.content)
        let boldFont = try #require(quoted.attribute(.font, at: 0, effectiveRange: nil) as? MarkdownFont)
        #if canImport(UIKit)
        #expect(boldFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        #else
        #expect(boldFont.fontDescriptor.symbolicTraits.contains(.bold))
        #endif
        let codeRange = (quoted.string as NSString).range(of: "code")
        let codeFont = try #require(quoted.attribute(.font, at: codeRange.location, effectiveRange: nil) as? MarkdownFont)
        #expect(codeFont.pointSize == MarkdownRenderTheme.default().codeFont.pointSize * 2)
        let mathBefore = try #require(before.first(where: { $0.math != nil })?.math)
        let mathAfter = try #require(after.first(where: { $0.math != nil })?.math)
        #expect(mathAfter.fontSize == mathBefore.fontSize * 2)
        let tableBefore = try #require(before.first(where: { $0.table != nil }))
        let tableAfter = try #require(after.first(where: { $0.table != nil }))
        let small = try attachmentBounds(in: tableBefore)
        let large = try attachmentBounds(in: tableAfter)
        #expect(large.height > small.height)
        #expect(large.width > small.width)
        let fenced = try #require(after.first(where: { $0.codeBlock != nil }))
        let fencedBefore = try #require(before.first(where: { $0.codeBlock != nil }))
        #expect(try font(in: fenced).pointSize == font(in: fencedBefore).pointSize * 2)
    }

    @Test("Invalid scale falls back to the base theme")
    func invalidScale() async throws {
        let theme = MarkdownRenderTheme.default()
        for factor in [CGFloat.nan, .infinity, 0, -1] {
            #expect(theme.scaled(by: factor).bodyFont == theme.bodyFont)
        }
    }

    @Test("Scale changes overlapping chunks never discard text")
    func scaleChangesDuringStreaming() async throws {
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed("Start")
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<100 { _ = await pipeline.feed(" word") }
            }
            group.addTask {
                for scale in [CGFloat(1.5), 2, 1] { _ = await pipeline.updateTextScale(scale) }
            }
        }
        _ = await pipeline.feed("\n\n")
        _ = await pipeline.finish()
        let blocks = await pipeline.blocksSnapshot()
        #expect(blocks.count == 1)
        let text = String(try #require(blocks.first).content.characters)
        #expect(text == "Start" + String(repeating: " word", count: 100) + "\n")
        #expect(try font(in: blocks[0]).pointSize == MarkdownRenderTheme.default().bodyFont.pointSize)
    }

    @Test("Scale and feed operations never overlap a suspended image render")
    func serializesSuspendedRenders() async throws {
        let provider = YieldingImageProvider()
        let pipeline = MarkdownStreamingPipeline(imageProvider: provider)
        _ = await pipeline.feed("![image](https://example.com/image.png) ")
        let id = try #require(await pipeline.blocksSnapshot().first).id
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<20 { _ = await pipeline.feed("word ") }
            }
            group.addTask {
                for scale in [CGFloat(2), 1.5, 1] { _ = await pipeline.updateTextScale(scale) }
            }
            group.addTask {
                for _ in 0..<3 { _ = await pipeline.refreshBlocks([id]) }
            }
        }
        _ = await pipeline.finish()
        #expect(await provider.maximumActiveRequests == 1)
        let block = try #require(await pipeline.blocksSnapshot().first)
        #expect(String(block.content.characters) == "image " + String(repeating: "word ", count: 20) + "\n")
        #expect(try font(in: block).pointSize == MarkdownRenderTheme.default().bodyFont.pointSize)
    }

    @Test("Unsupported inline and display math fallback uses the scaled font")
    func unsupportedMathScales() async throws {
        let tex = "\\unsupported{foo}"
        let theme = MarkdownRenderTheme.default()
        for display in [false, true] {
            let fallback = InlineMathAttachment.mathString(tex: tex, display: display, baseFont: theme.scaled(by: 2).bodyFont.resolved())
            #expect(fallback.string == tex)
            let font = try #require(fallback.attribute(.font, at: 0, effectiveRange: nil) as? MarkdownFont)
            #expect(font.pointSize == theme.bodyFont.pointSize * 2)
        }
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed("$$\n\(tex)\n$$\n\n")
        _ = await pipeline.finish()
        let before = try #require(await pipeline.blocksSnapshot().first)
        let after = try #require(await pipeline.updateTextScale(2)?.blocks.first)
        #expect(after.snapshot == before.snapshot)
        #expect(String(after.content.characters) == String(before.content.characters))
        #expect(try font(in: after).pointSize == theme.bodyFont.pointSize * 2)
    }

    @Test("Scaling cannot retain snapshots of blocks evicted by an overlapping feed")
    func scalingAtRetentionLimit() async throws {
        let provider = PausingImageProvider()
        let pipeline = MarkdownStreamingPipeline(imageProvider: provider)
        _ = await pipeline.feed("![image](https://example.com/image.png)\n\n" + String(repeating: "row\n\n", count: 999))
        await provider.pauseNextRequest()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await pipeline.updateTextScale(2) }
            await provider.waitUntilPaused()
            group.addTask { _ = await pipeline.feed("next\n\nnext\n\nnext\n\n") }
            for _ in 0..<20 { await Task.yield() }
            await provider.resume()
        }
        _ = await pipeline.finish()
        let blocks = await pipeline.blocksSnapshot()
        #expect(blocks.count == 1_000)
        #expect(Set(blocks.map(\.id)).count == 1_000)
        #expect(blocks.allSatisfy { $0.snapshot.isClosed })
        #expect(blocks.suffix(3).allSatisfy { String($0.content.characters) == "next\n" })
        for block in blocks {
            #expect(try font(in: block).pointSize == MarkdownRenderTheme.default().bodyFont.pointSize * 2)
        }
    }

    @Test("Out-of-order publication cannot overwrite newer text or scale")
    func stalePublicationIsIgnored() async throws {
        let pipeline = MarkdownStreamingPipeline()
        let older = try #require(await pipeline.feed("Hello "))
        _ = await pipeline.feed("world\n\n")
        let newest = try #require(await pipeline.updateTextScale(2))
        let model = MarkdownStreamingViewModel()
        model.enqueueUpdate(newest, replacing: true)
        await drainPublication()
        for replacing in [false, true] {
            model.enqueueUpdate(older, replacing: replacing)
            await drainPublication()
            #expect(model.blocks.map { String($0.content.characters) }.joined() == "Hello world\n")
            #expect(try font(in: #require(model.blocks.first)).pointSize == MarkdownRenderTheme.default().bodyFont.pointSize * 2)
        }
    }

    @Test("Canceled queued scale changes do not rerender retained blocks")
    func canceledScaleRequestsSkipRenders() async throws {
        let provider = PausingImageProvider()
        let pipeline = MarkdownStreamingPipeline(imageProvider: provider)
        _ = await pipeline.feed("![image](https://example.com/image.png)\n\n")
        let countBefore = await provider.requestCount
        await provider.pauseNextRequest()
        let first = Task { await pipeline.updateTextScale(2) }
        await provider.waitUntilPaused()
        let canceled = (0..<20).map { index in
            Task { await pipeline.updateTextScale(CGFloat(index + 3)) }
        }
        for _ in 0..<20 { await Task.yield() }
        for task in canceled { task.cancel() }
        let last = Task { await pipeline.updateTextScale(3) }
        await provider.resume()
        _ = await first.value
        for task in canceled { #expect(await task.value == nil) }
        _ = await last.value
        #expect(await provider.requestCount <= countBefore + 2)
        let final = try #require(await pipeline.blocksSnapshot().first)
        #expect(try font(in: final).pointSize == MarkdownRenderTheme.default().bodyFont.pointSize * 3)
    }

    @Test("Canceled finite-input initialization still completes at the requested scale")
    func canceledInitializationRetainsScale() async throws {
        let model = MarkdownStreamingViewModel()
        await model.updateTextScale(2)
        let task = Task { await model.consume(.chunks(["Hello ", "world\n\n"])) }
        task.cancel()
        await task.value
        await drainPublication()
        #expect(model.blocks.map { String($0.content.characters) }.joined() == "Hello world\n")
        #expect(try font(in: #require(model.blocks.first)).pointSize == MarkdownRenderTheme.default().bodyFont.pointSize * 2)
    }

    private func drainPublication() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func font(in block: RenderedBlock) throws -> MarkdownFont {
        try #require(NSAttributedString.picoConverted(from: block.content).attribute(.font, at: 0, effectiveRange: nil) as? MarkdownFont)
    }

    private func attachmentBounds(in block: RenderedBlock) throws -> CGRect {
        let content = NSAttributedString.picoConverted(from: block.content)
        var bounds: CGRect?
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, stop in
            if let attachment = value as? NSTextAttachment {
                bounds = attachment.bounds
                stop.pointee = true
            }
        }
        return try #require(bounds)
    }
}

private actor YieldingImageProvider: MarkdownImageProvider {
    private var activeRequests = 0
    private(set) var maximumActiveRequests = 0
    private(set) var requestCount = 0

    func image(for url: URL) async -> MarkdownImageResult? {
        requestCount += 1
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        for _ in 0..<20 { await Task.yield() }
        activeRequests -= 1
        return nil
    }
}

private actor PausingImageProvider: MarkdownImageProvider {
    private(set) var requestCount = 0
    private var shouldPause = false
    private var paused: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func pauseNextRequest() { shouldPause = true }

    func waitUntilPaused() async {
        if paused != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        paused?.resume()
        paused = nil
    }

    func image(for url: URL) async -> MarkdownImageResult? {
        requestCount += 1
        if shouldPause {
            shouldPause = false
            await withCheckedContinuation { continuation in
                paused = continuation
                observer?.resume()
                observer = nil
            }
        }
        return nil
    }
}
