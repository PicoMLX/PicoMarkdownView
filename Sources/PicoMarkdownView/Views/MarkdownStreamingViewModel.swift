import Foundation
import Observation
import os

@MainActor
@Observable
final class MarkdownStreamingViewModel {
    private static let logger = Logger(subsystem: "com.picomarkdown", category: "ViewModel")

    private var pipeline: MarkdownStreamingPipeline
    private var pipelineGeneration: UInt64 = 0
    private var lastConsumedInputID: String?
    private var lastReplacementValue: String?
    private let theme: MarkdownRenderTheme
    private let imageProvider: MarkdownImageProvider?
    private let tagPrefixes: Set<TagPrefix>

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

    init(theme: MarkdownRenderTheme = .default(),
         imageProvider: MarkdownImageProvider? = nil,
         tagPrefixes: Set<TagPrefix> = TagPrefix.defaults) {
        self.theme = theme
        self.imageProvider = imageProvider
        self.tagPrefixes = tagPrefixes
        self.pipeline = MarkdownStreamingPipeline(theme: theme, imageProvider: imageProvider, tagPrefixes: tagPrefixes)
    }

    func consume(_ input: MarkdownStreamingInput) async {
        switch input.payload {
        case .replacement(let value):
            // Input ids are content-derived for `.text`/`.chunks`, so a
            // re-fired `.task` (parent re-render, scroll-back in a lazy
            // container) with unchanged content is dropped here without
            // touching the pipeline. Only the *latest* consumed id is
            // remembered so A -> B -> A re-applies A.
            guard input.id != lastConsumedInputID else { return }
            lastConsumedInputID = input.id
            await replace(with: value)
        case .chunks(let values):
            guard input.id != lastConsumedInputID else { return }
            lastConsumedInputID = input.id
            await consume(chunks: values)
        case .stream:
            // Streams are intentionally NOT deduplicated by id: `.task` is
            // cancelled when the view scrolls out and re-fires with the same
            // id when it reappears, and a cancelled stream cannot be resumed.
            // Rebuild and re-invoke the factory so the view shows the full
            // content again (the factory should return the full stream on
            // each invocation).
            guard let factory = input.streamFactory else { return }
            // Streams still update the last-consumed id: a `.chunks`/`.text`
            // input that re-arrives after a stream replaced the document must
            // not be mistaken for a redundant re-delivery.
            lastConsumedInputID = input.id
            let (freshPipeline, generation) = makeFreshPipeline()
            _ = await freshPipeline.updateMermaidContentWidth(mermaidContentWidth)
            enqueueUpdate(blocks: [], diff: nil)
            let stream = await factory()
            await consume(stream: stream, pipeline: freshPipeline, generation: generation)
        }
    }

    /// Replaces the active pipeline and bumps the consumption generation so a
    /// cancelled-but-still-draining older consume loop can no longer publish
    /// into the new document.
    private func makeFreshPipeline() -> (MarkdownStreamingPipeline, UInt64) {
        lastReplacementValue = nil
        resetImagePrefetchState()
        pipelineGeneration &+= 1
        let newPipeline = MarkdownStreamingPipeline(theme: theme, imageProvider: imageProvider, tagPrefixes: tagPrefixes)
        pipeline = newPipeline
        return (newPipeline, pipelineGeneration)
    }

    private func consume(chunks: [String]) async {
        // A `.chunks` input describes a complete document, and `finish()` has
        // already sealed any previously consumed input. Feeding into the
        // existing pipeline would duplicate content, so rebuild from scratch
        // exactly like `replace(with:)` does.
        let (freshPipeline, generation) = makeFreshPipeline()
        _ = await freshPipeline.updateMermaidContentWidth(mermaidContentWidth)

        var latestBlocks: [RenderedBlock] = []
        for chunk in chunks where !chunk.isEmpty {
            if let update = await freshPipeline.feed(chunk) {
                latestBlocks = update.blocks
            }
        }
        if let update = await freshPipeline.finish() {
            latestBlocks = update.blocks
        }
        guard generation == pipelineGeneration else { return }
        enqueueUpdate(blocks: latestBlocks, diff: nil)
    }

    private func consume(stream: AsyncStream<String>,
                         pipeline: MarkdownStreamingPipeline,
                         generation: UInt64) async {
        for await chunk in stream {
            if Task.isCancelled { return }
            guard !chunk.isEmpty else { continue }
            if let update = await pipeline.feed(chunk) {
                guard generation == pipelineGeneration else { return }
                enqueueUpdate(blocks: update.blocks, diff: update.diff)
            }
        }
        guard !Task.isCancelled else { return }
        if let update = await pipeline.finish() {
            guard generation == pipelineGeneration else { return }
            enqueueUpdate(blocks: update.blocks, diff: update.diff)
        }
    }

    private func replace(with value: String) async {
        // Belt-and-braces alongside the content-derived input id: a redundant
        // replace with identical text must not re-tokenize the document.
        guard value != lastReplacementValue else { return }
        #if DEBUG
        Self.logger.debug("replace(with:) called, value length=\(value.count)")
        #endif
        let (freshPipeline, generation) = makeFreshPipeline()
        var latestBlocks: [RenderedBlock] = []

        _ = await freshPipeline.updateMermaidContentWidth(mermaidContentWidth)

        if !value.isEmpty {
            if let update = await freshPipeline.feed(value) {
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

        if let update = await freshPipeline.finish() {
            latestBlocks = update.blocks
            #if DEBUG
            Self.logger.debug("finish produced \(latestBlocks.count) blocks")
            #endif
        } else {
            #if DEBUG
            Self.logger.debug("finish returned nil (blocks from feed: \(latestBlocks.count))")
            #endif
        }

        guard generation == pipelineGeneration else { return }
        lastReplacementValue = value
        #if DEBUG
        Self.logger.debug("enqueueUpdate with \(latestBlocks.count) blocks")
        #endif
        enqueueUpdate(blocks: latestBlocks, diff: nil)
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
        // This runs once per enqueued update (i.e. per chunk). The common case
        // is a document with no images at all — skip the dictionary rebuild
        // entirely rather than reallocating an empty map every chunk.
        if imageBlockDependencies.isEmpty && blocks.allSatisfy({ $0.images.isEmpty }) {
            return
        }

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
        guard !imageBlockDependencies.isEmpty else { return }
        guard let prefetcher = imageProvider as? any MarkdownImagePrefetchingProvider else { return }

        // Sort only the not-yet-requested URLs (usually none) instead of
        // re-sorting the full set on every chunk.
        let pendingURLs = imageBlockDependencies.keys.filter { !requestedRemoteImageURLs.contains($0) }
        guard !pendingURLs.isEmpty else { return }

        for url in pendingURLs.sorted(by: { $0.absoluteString < $1.absoluteString }) {
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
