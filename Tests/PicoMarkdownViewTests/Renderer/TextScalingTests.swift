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

    @Test("Scaling and width refresh retain images after shared-cache eviction")
    func scalingRetainsEvictedImages() async throws {
        let size = CGSize(width: 200, height: 100)
        #if canImport(UIKit)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        #else
        let image = NSImage(size: size)
        #endif
        let provider = EvictingImageProvider(result: MarkdownImageResult(image: image, size: size))
        let pipeline = MarkdownStreamingPipeline(imageProvider: provider)
        let source = "https://example.com/image.png"
        _ = await pipeline.feed("Before ![image](\(source))\n\n> ![image](\(source))\n\n| Image |\n| --- |\n| ![image](\(source)) |\n\n")
        _ = await pipeline.finish()
        let original = await pipeline.blocksSnapshot()
        #expect(try original.filter { !$0.images.isEmpty }.map(attachmentBounds).count == 3)
        await provider.evict()
        for scale in [CGFloat(2), 1, 1.5] {
            let scaled = try #require(await pipeline.updateTextScale(scale)).blocks
            #expect(scaled.map(\.snapshot) == original.map(\.snapshot))
            #expect(try scaled.filter { !$0.images.isEmpty }.map(attachmentBounds).allSatisfy { $0.size == size })
            #expect(try font(in: #require(scaled.first)).pointSize == MarkdownRenderTheme.default().bodyFont.pointSize * scale)
        }
        let narrowed = try #require(await pipeline.updateMermaidContentWidth(80)).blocks
        for block in narrowed where !block.images.isEmpty {
            let bounds = try attachmentBounds(in: block)
            let expectedWidth: CGFloat
            switch block.kind {
            case .blockquote: expectedWidth = 80 - BlockquoteBarMetrics.textIndent(level: 1)
            case .table:
                #if canImport(AppKit)
                expectedWidth = 80 - 24 - 2 // Cell padding and borders.
                #else
                expectedWidth = 80
                #endif
            default: expectedWidth = 80
            }
            #expect(bounds.size == CGSize(width: expectedWidth, height: expectedWidth / 2))
        }
        let widened = try #require(await pipeline.updateMermaidContentWidth(400)).blocks
        #expect(try widened.filter { !$0.images.isEmpty }.map(attachmentBounds).allSatisfy { $0.size == size })
    }

    @Test("Image retention ends when its rendered block is discarded")
    func discardedBlocksReleaseRetainedImages() async throws {
        let size = CGSize(width: 20, height: 10)
        #if canImport(UIKit)
        let image = UIGraphicsImageRenderer(size: size).image { _ in }
        #else
        let image = NSImage(size: size)
        #endif
        let provider = EvictingImageProvider(result: MarkdownImageResult(image: image, size: size))
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler(config: .init(maxClosedBlocks: 1))
        let renderer = MarkdownRenderer(imageProvider: provider) { await assembler.block($0) }
        let markdown = "![image](https://example.com/image.png)\n\n"
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed(markdown)))
        #expect(try attachmentBounds(in: #require((await renderer.renderedBlocks()).first)).size == size)
        await provider.evict()
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed("outside\n\n")))
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed(markdown)))
        let block = try #require((await renderer.renderedBlocks()).first)
        let content = NSAttributedString.picoConverted(from: block.content)
        #expect(content.string == "image\n")
        #expect(content.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
    }

    @Test("Shared retained images survive until their last referencing block is discarded")
    func sharedImageReferences() async throws {
        let size = CGSize(width: 20, height: 10)
        #if canImport(UIKit)
        let image = UIGraphicsImageRenderer(size: size).image { _ in }
        #else
        let image = NSImage(size: size)
        #endif
        let provider = EvictingImageProvider(result: MarkdownImageResult(image: image, size: size))
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler(config: .init(maxClosedBlocks: 2))
        let renderer = MarkdownRenderer(imageProvider: provider) { await assembler.block($0) }
        let markdown = "![image](https://example.com/image.png)\n\n"
        for _ in 0..<2 { _ = await renderer.apply(await assembler.apply(await tokenizer.feed(markdown))) }
        await provider.evict()
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed("plain\n\n")))
        _ = await renderer.updateTextScale(2)
        let retained = try #require((await renderer.renderedBlocks()).first)
        #expect(try attachmentBounds(in: retained).size == size)
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed("plain\n\n")))
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed(markdown)))
        let last = try #require((await renderer.renderedBlocks()).last)
        #expect(NSAttributedString.picoConverted(from: last.content).string == "image\n")
    }

    @Test("Refreshing a block removes its obsolete image references")
    func refreshedImageReferences() async throws {
        let size = CGSize(width: 20, height: 10)
        #if canImport(UIKit)
        let image = UIGraphicsImageRenderer(size: size).image { _ in }
        #else
        let image = NSImage(size: size)
        #endif
        let provider = EvictingImageProvider(result: MarkdownImageResult(image: image, size: size))
        let store = ScalingSnapshotStore()
        let renderer = MarkdownRenderer(imageProvider: provider) { await store.snapshot($0) }
        let runs = [InlineRun(text: "image", style: [.image], image: InlineImage(source: "https://example.com/image.png"))]
        await store.set(BlockSnapshot(id: 1, kind: .paragraph, inlineRuns: runs, isClosed: true))
        _ = await renderer.apply(AssemblerDiff(documentVersion: 1, changes: [.blockStarted(id: 1, kind: .paragraph, position: 0)]))
        #expect(try attachmentBounds(in: #require((await renderer.renderedBlocks()).first)).size == size)
        await provider.evict()
        await store.set(BlockSnapshot(id: 1, kind: .paragraph, inlineRuns: [InlineRun(text: "plain", style: [])], isClosed: true))
        _ = await renderer.refreshBlocks([1])
        await store.set(BlockSnapshot(id: 2, kind: .paragraph, inlineRuns: runs, isClosed: true))
        _ = await renderer.apply(AssemblerDiff(documentVersion: 2, changes: [.blockStarted(id: 2, kind: .paragraph, position: 1)]))
        let last = try #require((await renderer.renderedBlocks()).last)
        #expect(NSAttributedString.picoConverted(from: last.content).string == "image\n")
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

    @Test("Publication gaps synchronize closed-block scale changes", arguments: [false, true], [false, true])
    func publicationGapsPreserveScale(deliverScale: Bool, textKit2: Bool) async throws {
        let pipeline = MarkdownStreamingPipeline()
        let initial = try #require(await pipeline.feed("First closed\n\nSecond closed\n\nOpen"))
        let model = MarkdownStreamingViewModel()
        model.enqueueUpdate(initial, replacing: true)
        await drainPublication()
        let controller = TextKitStreamingController()
        let configuration = PicoTextKitConfiguration()
        let view = textKit2 ? controller.makeTextKit2View(configuration: configuration) : controller.makeTextKit1View(configuration: configuration)
        func updateView() {
            controller.update(textView: view, blocks: model.blocks, diffs: model.diffQueue,
                replaceToken: model.replaceToken, documentVersion: model.documentVersion, configuration: configuration)
        }
        updateView()
        let selection = NSRange(location: 0, length: initial.blocks.dropLast().reduce(0) { $0 + String($1.content.characters).utf16.count })
        #if canImport(UIKit)
        view.selectedRange = selection
        #else
        view.setSelectedRange(selection)
        #endif
        let scaled = try #require(await pipeline.updateTextScale(2))
        let appended = try #require(await pipeline.feed(" tail"))
        if deliverScale {
            model.enqueueUpdate(scaled)
            await drainPublication()
            // SwiftUI can coalesce flushes before the native view updates.
        }
        model.enqueueUpdate(appended)
        await drainPublication()
        model.enqueueUpdate(scaled)
        await drainPublication()
        updateView()
        #if canImport(UIKit)
        let storage = view.textStorage
        #expect(view.selectedRange == selection)
        #else
        let storage = try #require(view.textStorage)
        #expect(view.selectedRange() == selection)
        #endif
        #expect(storage.string == appended.blocks.map { String($0.content.characters) }.joined())
        for text in ["First closed", "Second closed", "Open tail"] {
            let range = (storage.string as NSString).range(of: text)
            let font = try #require(storage.attribute(.font, at: range.location, effectiveRange: nil) as? MarkdownFont)
            #expect(font.pointSize == MarkdownRenderTheme.default().bodyFont.pointSize * 2)
        }
    }

    @Test("Width diffs contain only changed attachment blocks in long documents", arguments: ["image", "mermaid", "math"])
    func widthDiffsStayBlockLocal(kind: String) async throws {
        let size = CGSize(width: 200, height: 100)
        #if canImport(UIKit)
        let image = UIGraphicsImageRenderer(size: size).image { _ in }
        #else
        let image = NSImage(size: size)
        #endif
        let provider = EvictingImageProvider(result: MarkdownImageResult(image: image, size: size))
        let pipeline = MarkdownStreamingPipeline(imageProvider: provider)
        let attachment: String
        switch kind {
        case "mermaid": attachment = "```mermaid\ngraph LR\nA-->B\n```"
        case "math": attachment = "$$" + String(repeating: "x+", count: 30) + "x$$"
        default: attachment = "![image](https://example.com/image.png)"
        }
        let paragraphs = (0..<128).map { "Paragraph \($0)\n\n" }.joined()
        _ = await pipeline.feed(paragraphs + attachment + "\n\nAfter\n\n")
        _ = await pipeline.finish()
        let original = await pipeline.blocksSnapshot()
        let changedID = try #require(original.dropFirst(128).first).id
        var previous = original
        let widths: [CGFloat?] = [48, 64, nil]
        for width in widths {
            let update = try #require(await pipeline.updateMermaidContentWidth(width))
            #expect(update.blocks.map(\.snapshot) == original.map(\.snapshot))
            #expect(update.diff.changes == [.blockEnded(id: changedID)])
            var actuallyChanged: [BlockID] = []
            for (before, after) in zip(previous, update.blocks) where before.content != after.content {
                actuallyChanged.append(after.id)
            }
            #expect(actuallyChanged == [changedID])
            #expect(await pipeline.updateMermaidContentWidth(width) == nil)
            previous = update.blocks
        }
        let appended = try #require(await pipeline.feed("New tail"))
        #expect(appended.blocks.dropLast().map(\.snapshot) == original.map(\.snapshot))
        #expect(appended.diff.documentVersion > 0)
    }

    @Test("Width publication preserves selection across image, Mermaid, and math attachments", arguments: ["image", "mermaid", "math"], [false, true])
    func widthPublicationPreservesSelection(kind: String, textKit2: Bool) async throws {
        let size = CGSize(width: 200, height: 100)
        #if canImport(UIKit)
        let image = UIGraphicsImageRenderer(size: size).image { _ in }
        #else
        let image = NSImage(size: size)
        #endif
        let provider = EvictingImageProvider(result: MarkdownImageResult(image: image, size: size))
        let model = MarkdownStreamingViewModel(imageProvider: provider)
        let attachment: String
        switch kind {
        case "mermaid": attachment = "```mermaid\ngraph LR\nA-->B\n```"
        case "math": attachment = "$$" + String(repeating: "x+", count: 30) + "x$$"
        default: attachment = "![image](https://example.com/image.png)"
        }
        await model.consume(.text("Before\n\n\(attachment)\n\nAfter\n\n"))
        await drainPublication()
        let original = model.blocks
        #expect(original.count == 3)
        let attachmentBlock = try #require(original.dropFirst().first)
        if kind == "mermaid" { #expect(attachmentBlock.mermaidDiagram != nil) }
        if kind == "math" { #expect(attachmentBlock.math != nil) }
        let initialBounds = try attachmentBounds(in: attachmentBlock)
        let originalText = original.map { String($0.content.characters) }.joined()
        let attachmentOffset = String(try #require(original.first).content.characters).utf16.count
        let selections = [
            NSRange(location: 0, length: originalText.utf16.count),
            NSRange(location: 1, length: attachmentOffset),
            NSRange(location: attachmentOffset, length: originalText.utf16.count - attachmentOffset)
        ]
        let controller = TextKitStreamingController()
        let configuration = PicoTextKitConfiguration()
        let view = textKit2 ? controller.makeTextKit2View(configuration: configuration) : controller.makeTextKit1View(configuration: configuration)
        func updateView() {
            controller.update(textView: view, blocks: model.blocks, diffs: model.diffQueue,
                replaceToken: model.replaceToken, documentVersion: model.documentVersion, configuration: configuration)
        }
        updateView()
        let replaceToken = model.replaceToken
        let widths: [CGFloat?] = [48, 64, nil]
        for selection in selections {
            #if canImport(UIKit)
            view.selectedRange = selection
            #else
            view.setSelectedRange(selection)
            #endif
            for width in widths {
                let previousVersion = model.documentVersion
                await model.updateMermaidContentWidth(width)
                await drainPublication()
                #expect(model.replaceToken == replaceToken)
                #expect(model.documentVersion > previousVersion)
                #expect(model.diffQueue.last?.documentVersion == model.documentVersion)
                #expect(model.blocks.map(\.snapshot) == original.map(\.snapshot))
                let refreshed = try #require(model.blocks.first { $0.id == attachmentBlock.id })
                #expect(try attachmentBounds(in: refreshed).width == min(width ?? initialBounds.width, initialBounds.width))
                updateView()
                #if canImport(UIKit)
                #expect(view.selectedRange == selection)
                #expect(view.textStorage.string == originalText)
                #else
                #expect(view.selectedRange() == selection)
                #expect(view.textStorage?.string == originalText)
                #endif
            }
        }
    }

    @Test("Full replacements retain their snapshot version without false gap scans", arguments: [0, 1, 2], [false, true])
    func replacementVersionBaseline(scenario: Int, textKit2: Bool) async throws {
        let model = MarkdownStreamingViewModel()
        if scenario == 0 {
            await model.consume(.text("First closed\n\nOpen"))
        } else {
            let pipeline = MarkdownStreamingPipeline()
            let initial = try #require(await pipeline.feed("First closed\n\nOpen"))
            let next = try #require(await pipeline.feed(" tail"))
            if scenario == 1 {
                model.enqueueUpdate(next, replacing: true)
            } else {
                model.enqueueUpdate(initial, replacing: true)
                model.enqueueUpdate(next)
            }
        }
        await drainPublication()
        #expect(model.documentVersion == 2)
        #expect(model.diffQueue.isEmpty)
        let controller = TextKitStreamingController()
        let configuration = PicoTextKitConfiguration()
        let view = textKit2 ? controller.makeTextKit2View(configuration: configuration) : controller.makeTextKit1View(configuration: configuration)
        controller.update(textView: view, blocks: model.blocks, diffs: model.diffQueue,
            replaceToken: model.replaceToken, documentVersion: model.documentVersion, configuration: configuration)
        #expect(controller.lastAppliedVersion == model.documentVersion)
        let narrow = AssemblerDiff(documentVersion: model.documentVersion + 1,
            changes: [.blockEnded(id: try #require(model.blocks.last).id)])
        #expect(controller.eligibleDiffs(from: [narrow], blocks: model.blocks).diffs == [narrow])
        let gap = AssemblerDiff(documentVersion: narrow.documentVersion + 1, changes: narrow.changes)
        #expect(controller.eligibleDiffs(from: [gap], blocks: model.blocks).diffs.first?.changes.count == 1 + model.blocks.count)
    }

    @Test("Resumed replacements establish their snapshot version before the next chunk", arguments: [0, 1, 2], [false, true])
    func pausedReplacementVersionBaseline(scenario: Int, textKit2: Bool) async throws {
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed("First closed\n\nSecond closed\n\nOpen")
        let replacement = try #require(await pipeline.feed(" tail"))
        let controller = TextKitStreamingController()
        var configuration = PicoTextKitConfiguration()
        let view = textKit2 ? controller.makeTextKit2View(configuration: configuration) : controller.makeTextKit1View(configuration: configuration)
        if scenario == 1 {
            controller.update(textView: view, blocks: replacement.blocks, diffs: [],
                replaceToken: 1, documentVersion: replacement.diff.documentVersion, configuration: configuration)
        }
        configuration.isPaused = true
        controller.update(textView: view, blocks: replacement.blocks, diffs: [],
            replaceToken: 2, documentVersion: replacement.diff.documentVersion, configuration: configuration)
        #expect(controller.lastAppliedVersion == 0)
        let resumed: StreamingUpdate
        if scenario == 2 {
            resumed = try #require(await pipeline.feed(" paused"))
            controller.update(textView: view, blocks: resumed.blocks, diffs: [resumed.diff],
                replaceToken: 2, documentVersion: resumed.diff.documentVersion, configuration: configuration)
            #expect(controller.lastAppliedVersion == 0)
        } else {
            resumed = replacement
        }
        configuration.isPaused = false
        controller.update(textView: view, blocks: resumed.blocks, diffs: [],
            replaceToken: 2, documentVersion: resumed.diff.documentVersion, configuration: configuration)
        #expect(controller.lastAppliedVersion == resumed.diff.documentVersion)
        #if canImport(UIKit)
        let storage = view.textStorage
        #else
        let storage = try #require(view.textStorage)
        #endif
        #expect(storage.string == resumed.blocks.map { String($0.content.characters) }.joined())
        let next = try #require(await pipeline.feed(" next"))
        #expect(controller.eligibleDiffs(from: [next.diff], blocks: next.blocks).diffs == [next.diff])
        controller.update(textView: view, blocks: next.blocks, diffs: [next.diff],
            replaceToken: 2, documentVersion: next.diff.documentVersion, configuration: configuration)
        #expect(controller.lastAppliedVersion == next.diff.documentVersion)
        #expect(storage.string == next.blocks.map { String($0.content.characters) }.joined())
    }

    @Test("Only the latest queued width refresh renders", arguments: [false, true])
    func queuedWidthsCoalesce(resetWidth: Bool) async throws {
        let provider = PausingImageProvider()
        let pipeline = MarkdownStreamingPipeline(imageProvider: provider)
        _ = await pipeline.feed((0..<8).map { "Item \($0) ![image](https://example.com/\($0).png)\n\n" }.joined())
        _ = await pipeline.finish()
        let original = await pipeline.blocksSnapshot()
        let countBefore = await provider.requestCount
        await provider.pauseNextRequest()
        let refresh = Task { await pipeline.refreshBlocks([original[0].id]) }
        await provider.waitUntilPaused()
        var obsolete: [Task<StreamingUpdate?, Never>] = []
        for index in 0..<20 {
            let version = await pipeline.widthRequestVersion
            obsolete.append(Task { await pipeline.updateMermaidContentWidth(CGFloat(160 + index * 8)) })
            while await pipeline.widthRequestVersion == version { await Task.yield() }
        }
        let latestWidth: CGFloat? = resetWidth ? nil : 800
        let version = await pipeline.widthRequestVersion
        let latest = Task { await pipeline.updateMermaidContentWidth(latestWidth) }
        while await pipeline.widthRequestVersion == version { await Task.yield() }
        let feed = Task { await pipeline.feed("Tail\n\n") }
        await provider.resume()
        _ = await refresh.value
        for task in obsolete { #expect(await task.value == nil) }
        _ = await latest.value
        _ = await feed.value
        #expect(await provider.requestCount == countBefore + 1 + (resetWidth ? 0 : original.count))
        let countAfter = await provider.requestCount
        #expect(await pipeline.updateMermaidContentWidth(latestWidth) == nil)
        #expect(await provider.requestCount == countAfter)
        #expect(await pipeline.blocksSnapshot().last?.content.characters.elementsEqual("Tail\n") == true)
    }

    @Test("Superseded in-flight widths stop rendering and never publish", arguments: [false, true])
    func supersededInFlightWidth(resetWidth: Bool) async throws {
        let size = CGSize(width: 1600, height: 800)
        #if canImport(UIKit)
        let image = UIGraphicsImageRenderer(size: size).image { _ in }
        #else
        let image = NSImage(size: size)
        #endif
        let provider = PausingImageProvider(result: MarkdownImageResult(image: image, size: size))
        let pipeline = MarkdownStreamingPipeline(imageProvider: provider)
        _ = await pipeline.updateTextScale(2)
        _ = await pipeline.updateMermaidContentWidth(400)
        _ = await pipeline.feed((0..<8).map { "Item \($0) ![image](https://example.com/\($0).png)\n\n" }.joined())
        _ = await pipeline.finish()
        let original = await pipeline.blocksSnapshot()
        let countBefore = await provider.requestCount
        await provider.pauseNextRequest()
        let obsolete = Task { await pipeline.updateMermaidContentWidth(160) }
        await provider.waitUntilPaused()
        let version = await pipeline.widthRequestVersion
        let latestWidth: CGFloat? = resetWidth ? nil : 800
        let latest = Task { await pipeline.updateMermaidContentWidth(latestWidth) }
        while await pipeline.widthRequestVersion == version { await Task.yield() }
        let feed = Task { await pipeline.feed("Tail\n\n") }
        await provider.resume()
        #expect(await obsolete.value == nil)
        let update = try #require(await latest.value)
        #expect(await provider.requestCount == countBefore + 1 + original.count)
        #expect(update.blocks.map(\.id) == original.map(\.id))
        #expect(update.blocks.map(\.snapshot) == original.map(\.snapshot))
        for block in update.blocks {
            #expect(try attachmentBounds(in: block).width == (latestWidth ?? size.width))
            #expect(try font(in: block).pointSize == MarkdownRenderTheme.default().bodyFont.pointSize * 2)
        }
        let backend = TextKitStreamingBackend()
        _ = backend.apply(blocks: original, selection: NSRange(location: 0, length: 0))
        let selection = NSRange(location: 0, length: backend.length)
        #expect(backend.apply(blocks: update.blocks, diffs: [update.diff], selection: selection) == selection)
        #expect(await pipeline.updateMermaidContentWidth(latestWidth) == nil)
        _ = await feed.value
        #expect(await pipeline.blocksSnapshot().last?.content.characters.elementsEqual("Tail\n") == true)
    }

    @Test("Rolling back a committed width restores the previous configuration and allows retry")
    func committedWidthRollback() async throws {
        let size = CGSize(width: 1600, height: 800)
        #if canImport(UIKit)
        let image = UIGraphicsImageRenderer(size: size).image { _ in }
        #else
        let image = NSImage(size: size)
        #endif
        let provider = PausingImageProvider(result: MarkdownImageResult(image: image, size: size))
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer(imageProvider: provider) { await assembler.block($0) }
        _ = await renderer.updateMermaidContentWidth(400)
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed("One ![image](https://example.com/1.png)\n\n")))
        let original = await renderer.renderedBlocks()
        let prepared = try #require(await renderer.prepareContentWidth(160, shouldContinue: { true }))
        #expect(await renderer.renderedBlocks() == original)
        #expect(await renderer.commitContentWidth(prepared))
        #expect(try attachmentBounds(in: #require(await renderer.renderedBlocks().first)).width == 160)
        await renderer.rollbackContentWidth(prepared)
        #expect(await renderer.renderedBlocks() == original)
        _ = await renderer.updateTextScale(2)
        #expect(try attachmentBounds(in: #require(await renderer.renderedBlocks().first)).width == 400)
        let retried = try #require(await renderer.updateMermaidContentWidth(160))
        #expect(try attachmentBounds(in: #require(retried.first)).width == 160)
        await renderer.rollbackContentWidth(prepared)
        #expect(await renderer.renderedBlocks() == retried)
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

    @Test("Superseded in-flight scales stop rendering and never publish", arguments: [false, true])
    func supersededInFlightScale(cancel: Bool) async throws {
        let provider = PausingImageProvider()
        let pipeline = MarkdownStreamingPipeline(imageProvider: provider)
        let source = (0..<8).map { "Item \($0) ![image](https://example.com/\($0).png)\n\n" }.joined()
        _ = await pipeline.feed(source)
        _ = await pipeline.finish()
        let original = await pipeline.blocksSnapshot()
        let countBefore = await provider.requestCount
        await provider.pauseNextRequest()
        let obsolete = Task { await pipeline.updateTextScale(2) }
        await provider.waitUntilPaused()
        let version = await pipeline.scaleRequestVersion
        let latestScale: CGFloat = cancel ? 2 : 3
        let latest = Task { await pipeline.updateTextScale(latestScale) }
        while await pipeline.scaleRequestVersion == version { await Task.yield() }
        if cancel { obsolete.cancel() }
        await provider.resume()
        #expect(await obsolete.value == nil)
        let update = try #require(await latest.value)
        let final = update.blocks
        #expect(final.map(\.snapshot) == original.map(\.snapshot))
        #expect(final.map(\.id) == original.map(\.id))
        let backend = TextKitStreamingBackend()
        _ = backend.apply(blocks: original, selection: NSRange(location: 0, length: 0))
        let selection = NSRange(location: 0, length: backend.length)
        #expect(backend.apply(blocks: final, diffs: [update.diff], selection: selection) == selection)
        #expect(await provider.requestCount == countBefore + 1 + original.count)
        for block in final {
            #expect(try font(in: block).pointSize == MarkdownRenderTheme.default().bodyFont.pointSize * latestScale)
        }
        #expect(await pipeline.blocksSnapshot() == final)
    }

    @Test("Canceling an active scale retains the complete previous presentation")
    func canceledInFlightScaleRetainsPresentation() async throws {
        let provider = PausingImageProvider()
        let pipeline = MarkdownStreamingPipeline(imageProvider: provider)
        _ = await pipeline.feed("One ![image](https://example.com/1.png)\n\nTwo ![image](https://example.com/2.png)\n\n")
        _ = await pipeline.finish()
        let original = await pipeline.blocksSnapshot()
        let countBefore = await provider.requestCount
        await provider.pauseNextRequest()
        let canceled = Task { await pipeline.updateTextScale(2) }
        await provider.waitUntilPaused()
        canceled.cancel()
        await provider.resume()
        #expect(await canceled.value == nil)
        #expect(await pipeline.blocksSnapshot() == original)
        #expect(await provider.requestCount == countBefore + 1)
        let retry = try #require(await pipeline.updateTextScale(2)).blocks
        for block in retry {
            #expect(try font(in: block).pointSize == MarkdownRenderTheme.default().bodyFont.pointSize * 2)
        }
    }

    @Test("Rolling back a committed scale restores fonts and allows a same-size retry")
    func committedScaleRollback() async throws {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { await assembler.block($0) }
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed("One\n\nTwo\n\n")))
        let original = await renderer.renderedBlocks()
        let prepared = try #require(await renderer.prepareTextScale(2, shouldContinue: { true }))
        #expect(await renderer.renderedBlocks() == original)
        #expect(await renderer.commitTextScale(prepared) == original.map(\.id))
        for block in await renderer.renderedBlocks() {
            #expect(try font(in: block).pointSize == MarkdownRenderTheme.default().bodyFont.pointSize * 2)
        }
        await renderer.rollbackTextScale(prepared)
        #expect(await renderer.renderedBlocks() == original)
        #expect(await renderer.updateTextScale(2) == original.map(\.id))
        for block in await renderer.renderedBlocks() {
            #expect(try font(in: block).pointSize == MarkdownRenderTheme.default().bodyFont.pointSize * 2)
        }
        await renderer.rollbackTextScale(prepared)
        #expect(await renderer.renderedBlocks() == prepared.blocks)
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

private actor ScalingSnapshotStore {
    private var snapshots: [BlockID: BlockSnapshot] = [:]

    func set(_ snapshot: BlockSnapshot) { snapshots[snapshot.id] = snapshot }
    func snapshot(_ id: BlockID) -> BlockSnapshot {
        snapshots[id] ?? BlockSnapshot(id: id, kind: .unknown, isClosed: true)
    }
}

private actor EvictingImageProvider: MarkdownImageProvider {
    private var result: MarkdownImageResult?

    init(result: MarkdownImageResult) { self.result = result }
    func evict() { result = nil }
    func image(for url: URL) async -> MarkdownImageResult? { result }
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
    private let result: MarkdownImageResult?
    private(set) var requestCount = 0
    private var shouldPause = false
    private var paused: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    init(result: MarkdownImageResult? = nil) { self.result = result }

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
        return result
    }
}
