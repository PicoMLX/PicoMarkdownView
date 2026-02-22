import Foundation
import Observation
import os

@MainActor
@Observable
final class MarkdownStreamingViewModel {
    private static let logger = Logger(subsystem: "com.picomarkdown", category: "ViewModel")

    private var pipeline: MarkdownStreamingPipeline
    private var processedInputs: Set<UUID> = []
    private let theme: MarkdownRenderTheme
    private let imageProvider: MarkdownImageProvider?

    var blocks: [RenderedBlock] = []
    var diffQueue: [AssemblerDiff] = []
    var replaceToken: UInt64 = 0

    private var pendingBlocks: [RenderedBlock]?
    private var pendingDiffs: [AssemblerDiff] = []
    private var pendingReplaceToken: UInt64?
    private var updateScheduled = false
    private var mermaidContentWidth: CGFloat?
    private var mermaidContentWidthBucket: Int?

    init(theme: MarkdownRenderTheme = .default(), imageProvider: MarkdownImageProvider? = nil) {
        self.theme = theme
        self.imageProvider = imageProvider
        self.pipeline = MarkdownStreamingPipeline(theme: theme, imageProvider: imageProvider)
    }

    func consume(_ input: MarkdownStreamingInput) async {
        if case .replacement = input.payload {
            processedInputs.removeAll(keepingCapacity: true)
        }
        guard processedInputs.insert(input.id).inserted else { return }
        switch input.payload {
        case .replacement(let value):
            await replace(with: value)
        case .chunks(let values):
            await consume(chunks: values)
        case .stream:
            guard let factory = input.streamFactory else { return }
            let stream = await factory()
            await consume(stream: stream)
        }
    }

    private func consume(chunks: [String]) async {
        for chunk in chunks {
            await applyChunk(chunk)
        }
        if let update = await pipeline.finish() {
            enqueueUpdate(blocks: update.blocks, diff: update.diff)
        }
    }

    private func consume(stream: AsyncStream<String>) async {
        for await chunk in stream {
            await applyChunk(chunk)
        }
        if let update = await pipeline.finish() {
            enqueueUpdate(blocks: update.blocks, diff: update.diff)
        }
    }

    private func replace(with value: String) async {
        Self.logger.debug("replace(with:) called, value length=\(value.count)")
        let newPipeline = MarkdownStreamingPipeline(theme: theme, imageProvider: imageProvider)
        var latestBlocks: [RenderedBlock] = []

        _ = await newPipeline.updateMermaidContentWidth(mermaidContentWidth)

        if !value.isEmpty {
            if let update = await newPipeline.feed(value) {
                latestBlocks = update.blocks
                Self.logger.debug("feed produced \(latestBlocks.count) blocks")
            } else {
                Self.logger.warning("feed returned nil for non-empty value")
            }
        }

        if let update = await newPipeline.finish() {
            latestBlocks = update.blocks
            Self.logger.debug("finish produced \(latestBlocks.count) blocks")
        } else {
            Self.logger.debug("finish returned nil (blocks from feed: \(latestBlocks.count))")
        }

        pipeline = newPipeline
        Self.logger.debug("enqueueUpdate with \(latestBlocks.count) blocks")
        enqueueUpdate(blocks: latestBlocks, diff: nil)
    }

    private func applyChunk(_ chunk: String) async {
        guard !chunk.isEmpty else { return }
        if let update = await pipeline.feed(chunk) {
            enqueueUpdate(blocks: update.blocks, diff: update.diff)
        }
    }

    func updateMermaidContentWidth(_ width: CGFloat?) async {
        guard theme.mermaidRenderingMode.isEnabled else { return }

        let normalizedWidth: CGFloat? = {
            guard let width, width > 0 else { return nil }
            return width
        }()
        let nextBucket = mermaidWidthBucket(for: normalizedWidth)
        guard nextBucket != mermaidContentWidthBucket else { return }

        mermaidContentWidth = normalizedWidth
        mermaidContentWidthBucket = nextBucket

        if let updatedBlocks = await pipeline.updateMermaidContentWidth(normalizedWidth) {
            enqueueUpdate(blocks: updatedBlocks, diff: nil)
        }
    }

    private func enqueueUpdate(blocks: [RenderedBlock], diff: AssemblerDiff?) {
        pendingBlocks = blocks
        if let diff {
            pendingDiffs.append(diff)
        } else {
            pendingDiffs.removeAll(keepingCapacity: true)
            pendingReplaceToken = replaceToken &+ 1
        }
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingUpdates()
        }
    }

    private func flushPendingUpdates() {
        updateScheduled = false
        guard let blocks = pendingBlocks else {
            Self.logger.debug("flushPendingUpdates: no pending blocks")
            return
        }
        Self.logger.debug("flushPendingUpdates: \(blocks.count) blocks, replaceToken=\(self.pendingReplaceToken.map { String($0) } ?? "nil")")
        self.blocks = blocks
        self.diffQueue = pendingDiffs
        if let token = pendingReplaceToken {
            replaceToken = token
            diffQueue = []
        }
        pendingBlocks = nil
        pendingDiffs.removeAll(keepingCapacity: true)
        pendingReplaceToken = nil
    }

    private func mermaidWidthBucket(for width: CGFloat?) -> Int? {
        guard let width, width > 0 else { return nil }
        return Int((width / 8).rounded(.toNearestOrAwayFromZero))
    }
}
