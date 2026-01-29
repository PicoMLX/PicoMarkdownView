import Foundation
import Observation

@MainActor
@Observable
final class MarkdownStreamingViewModel {
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
        let newPipeline = MarkdownStreamingPipeline(theme: theme, imageProvider: imageProvider)
        var latestBlocks: [RenderedBlock] = []

        if !value.isEmpty {
            if let update = await newPipeline.feed(value) {
                latestBlocks = update.blocks
            }
        }

        if let update = await newPipeline.finish() {
            latestBlocks = update.blocks
        }

        pipeline = newPipeline
        enqueueUpdate(blocks: latestBlocks, diff: nil)
    }

    private func applyChunk(_ chunk: String) async {
        guard !chunk.isEmpty else { return }
        if let update = await pipeline.feed(chunk) {
            enqueueUpdate(blocks: update.blocks, diff: update.diff)
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
        guard let blocks = pendingBlocks else { return }
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
}
