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
    private var imageBlockDependencies: [URL: Set<BlockID>] = [:]
    private var requestedRemoteImageURLs: Set<URL> = []
    private var imagePrefetchTasks: [URL: Task<Void, Never>] = [:]
    private var imagePrefetchGeneration: UInt64 = 0

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
        #if DEBUG
        Self.logger.debug("replace(with:) called, value length=\(value.count)")
        #endif
        resetImagePrefetchState()
        let newPipeline = MarkdownStreamingPipeline(theme: theme, imageProvider: imageProvider)
        var latestBlocks: [RenderedBlock] = []

        _ = await newPipeline.updateMermaidContentWidth(mermaidContentWidth)

        if !value.isEmpty {
            if let update = await newPipeline.feed(value) {
                latestBlocks = update.blocks
                #if DEBUG
                Self.logger.debug("feed produced \(latestBlocks.count) blocks")
                #endif
            } else {
                #if DEBUG
                Self.logger.warning("feed returned nil for non-empty value")
                #endif
            }
        }

        if let update = await newPipeline.finish() {
            latestBlocks = update.blocks
            #if DEBUG
            Self.logger.debug("finish produced \(latestBlocks.count) blocks")
            #endif
        } else {
            #if DEBUG
            Self.logger.debug("finish returned nil (blocks from feed: \(latestBlocks.count))")
            #endif
        }

        pipeline = newPipeline
        #if DEBUG
        Self.logger.debug("enqueueUpdate with \(latestBlocks.count) blocks")
        #endif
        enqueueUpdate(blocks: latestBlocks, diff: nil)
    }

    private func applyChunk(_ chunk: String) async {
        guard !chunk.isEmpty else { return }
        if let update = await pipeline.feed(chunk) {
            enqueueUpdate(blocks: update.blocks, diff: update.diff)
        }
    }

    func updateMermaidContentWidth(_ width: CGFloat?) async {
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
        updateImageDependencies(using: blocks)
        scheduleImagePrefetchIfNeeded(using: blocks)
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
            #if DEBUG
            Self.logger.debug("flushPendingUpdates: no pending blocks")
            #endif
            return
        }
        #if DEBUG
        Self.logger.debug("flushPendingUpdates: \(blocks.count) blocks, replaceToken=\(self.pendingReplaceToken.map { String($0) } ?? "nil")")
        #endif
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

    private func resetImagePrefetchState() {
        imagePrefetchGeneration &+= 1
        for task in imagePrefetchTasks.values {
            task.cancel()
        }
        imagePrefetchTasks.removeAll(keepingCapacity: true)
        imageBlockDependencies.removeAll(keepingCapacity: true)
        requestedRemoteImageURLs.removeAll(keepingCapacity: true)
    }

    private func updateImageDependencies(using blocks: [RenderedBlock]) {
        var dependencies: [URL: Set<BlockID>] = [:]
        for block in blocks {
            for image in block.images {
                guard let url = image.url, isRemoteImageURL(url) else { continue }
                dependencies[url, default: []].insert(block.id)
            }
        }

        let validURLs = Set(dependencies.keys)
        for (url, task) in imagePrefetchTasks where !validURLs.contains(url) {
            task.cancel()
            imagePrefetchTasks[url] = nil
        }

        imageBlockDependencies = dependencies
    }

    private func scheduleImagePrefetchIfNeeded(using blocks: [RenderedBlock]) {
        guard !blocks.isEmpty else { return }
        guard let prefetcher = imageProvider as? any MarkdownImagePrefetchingProvider else { return }

        for url in imageBlockDependencies.keys.sorted(by: { $0.absoluteString < $1.absoluteString }) {
            guard requestedRemoteImageURLs.insert(url).inserted else { continue }
            let generation = imagePrefetchGeneration
            imagePrefetchTasks[url] = Task { [weak self] in
                guard let self else { return }
                let result = await prefetcher.prefetch(url)
                guard result != nil else {
                    await MainActor.run {
                        self.imagePrefetchTasks[url] = nil
                    }
                    return
                }
                if Task.isCancelled {
                    await MainActor.run {
                        self.imagePrefetchTasks[url] = nil
                    }
                    return
                }

                await MainActor.run {
                    self.handleImagePrefetchCompletion(url: url, generation: generation)
                }
            }
        }
    }

    private func handleImagePrefetchCompletion(url: URL, generation: UInt64) {
        guard generation == imagePrefetchGeneration else {
            imagePrefetchTasks[url] = nil
            return
        }
        guard let affectedBlocks = imageBlockDependencies[url], !affectedBlocks.isEmpty else {
            imagePrefetchTasks[url] = nil
            return
        }

        imagePrefetchTasks[url] = nil

        Task { [weak self] in
            guard let self else { return }
            guard let update = await self.pipeline.refreshBlocks(affectedBlocks) else { return }
            await MainActor.run {
                guard generation == self.imagePrefetchGeneration else { return }
                self.enqueueUpdate(blocks: update.blocks, diff: update.diff)
            }
        }
    }

    private func isRemoteImageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
