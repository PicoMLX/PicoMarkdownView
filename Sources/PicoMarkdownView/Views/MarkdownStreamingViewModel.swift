import Foundation
import Observation
import os
#if os(macOS)
import Synchronization
#endif

@MainActor
@Observable
final class MarkdownStreamingViewModel {
    private static let logger = Logger(subsystem: "com.picomarkdown", category: "ViewModel")

    private var pipeline: MarkdownStreamingPipeline
    private var pipelineGeneration: UInt64 = 0
    /// Id of the input whose consumption most recently *started* — intent,
    /// not completion. Recording at start is safe because `replace(with:)`
    /// and `consume(chunks:)` always run to completion once started (plain
    /// awaits do not abort on task cancellation); the only thing that stops
    /// them is a newer input, which overwrites this id and wins the pipeline
    /// generation check. Comparing against intent also means an A -> B -> A
    /// flip while B is still parsing restarts A instead of dropping it as a
    /// duplicate of stale state.
    private var activeInputID: String?
    private var lastReplacementValue: String?
    private let theme: MarkdownRenderTheme
    /// Body size of the theme the pipelines render with; the view scales
    /// against this, not against a theme a parent may rebuild later.
    var themeBodySize: CGFloat { theme.bodyFont.pointSize }
    /// Font size of the theme's code block theme, if any; it follows its own
    /// Dynamic Type ratio because the default one is sized from the system
    /// body size without the body font's offset.
    var codeBlockFontSize: CGFloat? { theme.codeBlockTheme?.font.pointSize }
    private let imageProvider: MarkdownImageProvider?
    private let mermaidProvider: (any MermaidDiagramProvider)?
    private let tagPrefixes: Set<TagPrefix>
    private let mermaidPreviewTiming: MermaidPreviewTiming
    private let embeddedBlockRenderers: [PicoEmbeddedBlockRenderer]

    var blocks: [RenderedBlock] = []
    var diffQueue: [AssemblerDiff] = []
    var replaceToken: UInt64 = 0
#if os(macOS)
    /// Published with the blocks, separately from presentation-only refreshes.
    var documentIdentity: UInt64 = 0
    /// Presentation activity is independent of canonical block closure: a
    /// cancelled source can leave a hosted fence incomplete.
    private(set) var isHostedStreamActive = false
    /// Compatibility for SVG callers; all hosted fences share one activity lifecycle.
    var isSVGStreamActive: Bool { isHostedStreamActive }
    private var pendingDocumentIdentity: UInt64 = 0
    private var textScaleRequestRevision: UInt64 = 0
    private var contentWidthRequestRevision: UInt64 = 0
#endif

    private var pendingBlocks: [RenderedBlock]?
    private var pendingDiffs: [AssemblerDiff] = []
    private var pendingReplaceToken: UInt64?
    private var updateScheduled = false
    private var mermaidContentWidth: CGFloat?
    private var mermaidContentWidthBucket: Int?
    private var textScale: CGFloat = 1
    private var codeBlockTextScale: CGFloat? = nil
    private var imageBlockDependencies: [URL: Set<BlockID>] = [:]
    private var requestedRemoteImageURLs: Set<URL> = []
    private var imagePrefetchTasks: [URL: Task<Void, Never>] = [:]
    private var imagePrefetchGeneration: UInt64 = 0
#if os(macOS)
    // Pixel updates bypass SwiftUI body evaluation and the Markdown pipeline.
    @ObservationIgnored private(set) var imagePreviews: [URL: MarkdownImagePreview] = [:]
    @ObservationIgnored var onImagePreview: ((URL, MarkdownImagePreview?, UInt64) -> Void)?
    @ObservationIgnored private var finishedImagePreviewURLs: Set<URL> = []
    @ObservationIgnored private var imagePreviewSequences: [URL: UInt64] = [:]
    private var mermaidPreviewTask: Task<Void, Never>?
    private var pendingMermaidPreviewIDs: Set<BlockID> = []
#endif

    init(theme: MarkdownRenderTheme = .default(),
         imageProvider: MarkdownImageProvider? = nil,
         mermaidProvider: (any MermaidDiagramProvider)? = nil,
         tagPrefixes: Set<TagPrefix> = TagPrefix.defaults,
         mermaidPreviewTiming: MermaidPreviewTiming = .continuous,
         embeddedBlockRenderers: [PicoEmbeddedBlockRenderer] = []) {
        self.theme = theme
        self.imageProvider = imageProvider
        self.mermaidProvider = mermaidProvider
        self.tagPrefixes = tagPrefixes
        self.mermaidPreviewTiming = mermaidPreviewTiming
        self.embeddedBlockRenderers = embeddedBlockRenderers
        self.pipeline = MarkdownStreamingPipeline(theme: theme, imageProvider: imageProvider,
                                                   mermaidProvider: mermaidProvider, tagPrefixes: tagPrefixes,
                                                   mermaidPreviewTiming: mermaidPreviewTiming,
                                                   embeddedBlockRenderers: embeddedBlockRenderers)
    }

    func consume(_ input: MarkdownStreamingInput) async {
        switch input.payload {
        case .replacement(let value):
            // Input ids are content-derived for `.text`/`.chunks`, so a
            // re-fired `.task` (parent re-render, scroll-back in a lazy
            // container) with unchanged content is dropped here without
            // touching the pipeline. Only the most recently *started* id is
            // remembered (see `activeInputID`) so A -> B -> A re-applies A
            // even while B is still mid-parse.
            guard input.id != activeInputID else { return }
            activeInputID = input.id
            await replace(with: value)
        case .chunks(let values):
            guard input.id != activeInputID else { return }
            activeInputID = input.id
            await consume(chunks: values)
        case .stream:
            // Streams are intentionally NOT deduplicated by id: `.task` is
            // cancelled when the view scrolls out and re-fires with the same
            // id when it reappears, and a cancelled stream cannot be resumed.
            // Rebuild and re-invoke the factory so the view shows the full
            // content again (the factory should return the full stream on
            // each invocation).
            guard let factory = input.streamFactory else { return }
            // Streams still update the active id: a `.chunks`/`.text` input
            // that re-arrives after a stream replaced the document must not
            // be mistaken for a redundant re-delivery.
            activeInputID = input.id
            let (freshPipeline, generation) = makeFreshPipeline()
#if os(macOS)
            await consumeMacStream(factory: factory, pipeline: freshPipeline, generation: generation)
#else
            _ = await freshPipeline.updateMermaidContentWidth(mermaidContentWidth)
            _ = await freshPipeline.updateTextScale(textScale, codeBlockScale: codeBlockTextScale)
            enqueueUpdate(blocks: [], diff: nil)
            let stream = await factory()
            await consume(stream: stream, pipeline: freshPipeline, generation: generation)
#endif
        }
    }

    /// Replaces the active pipeline and bumps the consumption generation so a
    /// cancelled-but-still-draining older consume loop can no longer publish
    /// into the new document.
    private func makeFreshPipeline() -> (MarkdownStreamingPipeline, UInt64) {
        lastReplacementValue = nil
        resetImagePrefetchState()
#if os(macOS)
        cancelMermaidPreview()
#endif
        pipelineGeneration &+= 1
#if os(macOS)
        isHostedStreamActive = true
#endif
        let newPipeline = MarkdownStreamingPipeline(theme: theme, imageProvider: imageProvider,
                                                    mermaidProvider: mermaidProvider, tagPrefixes: tagPrefixes,
                                                    mermaidPreviewTiming: mermaidPreviewTiming,
                                                   embeddedBlockRenderers: embeddedBlockRenderers)
        pipeline = newPipeline
        return (newPipeline, pipelineGeneration)
    }

#if os(macOS)
    /// Stop loading chrome promptly even when cancellation cannot resume a
    /// suspended factory. This never finishes the tokenizer or a newer input.
    private func consumeMacStream(factory: @escaping @Sendable () async -> AsyncStream<String>,
                                  pipeline: MarkdownStreamingPipeline,
                                  generation: UInt64) async {
        await withTaskCancellationHandler {
            defer { endHostedStream(generation: generation) }
            _ = await pipeline.updateMermaidContentWidth(mermaidContentWidth)
            _ = await pipeline.updateTextScale(textScale, codeBlockScale: codeBlockTextScale)
            guard !Task.isCancelled, generation == pipelineGeneration else { return }
            enqueueUpdate(blocks: [], diff: nil)
            let stream = await factory()
            guard !Task.isCancelled, generation == pipelineGeneration else { return }
            await consume(stream: stream, pipeline: pipeline, generation: generation)
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.endHostedStream(generation: generation)
            }
        }
    }

    private func endHostedStream(generation: UInt64) {
        guard generation == pipelineGeneration else { return }
        isHostedStreamActive = false
    }
#endif

    private func consume(chunks: [String]) async {
        // A `.chunks` input describes a complete document, and `finish()` has
        // already sealed any previously consumed input. Feeding into the
        // existing pipeline would duplicate content, so rebuild from scratch —
        // but still publish after every chunk so long replays render (and
        // start image prefetch) progressively rather than all at once.
        let (freshPipeline, generation) = makeFreshPipeline()
#if os(macOS)
        defer { endHostedStream(generation: generation) }
#endif
        _ = await freshPipeline.updateMermaidContentWidth(mermaidContentWidth)
        _ = await freshPipeline.updateTextScale(textScale, codeBlockScale: codeBlockTextScale)

        // The first publish must be a full replace (diff: nil): the view may
        // still show the previous document, and the fresh pipeline's diffs
        // are relative to an empty one.
        var publishedAny = false
        for chunk in chunks where !chunk.isEmpty {
#if os(macOS)
            await suspendMermaidPreview()
            guard generation == pipelineGeneration else { return }
#endif
            if let update = await freshPipeline.feed(chunk) {
                guard generation == pipelineGeneration else { return }
                enqueueUpdate(blocks: update.blocks, diff: publishedAny ? update.diff : nil)
                publishedAny = true
                continue
            }
#if os(macOS)
            scheduleMermaidPreview(after: nil)
#endif
        }
#if os(macOS)
        await suspendMermaidPreview()
        guard generation == pipelineGeneration else { return }
#endif
        if let update = await freshPipeline.finish() {
            guard generation == pipelineGeneration else { return }
            enqueueUpdate(blocks: update.blocks, diff: publishedAny ? update.diff : nil)
            publishedAny = true
        }
        guard generation == pipelineGeneration else { return }
        if !publishedAny {
            // Empty input still replaces whatever was on screen.
            enqueueUpdate(blocks: [], diff: nil)
        }
    }

    private func consume(stream: AsyncStream<String>,
                         pipeline: MarkdownStreamingPipeline,
                         generation: UInt64) async {
#if os(macOS)
        defer {
            if generation == pipelineGeneration { cancelMermaidPreview() }
        }
#endif
        for await chunk in stream {
            if Task.isCancelled { return }
            guard !chunk.isEmpty else { continue }
#if os(macOS)
            await suspendMermaidPreview()
            guard !Task.isCancelled, generation == pipelineGeneration else { return }
#endif
            if let update = await pipeline.feed(chunk) {
                guard generation == pipelineGeneration else { return }
                enqueueUpdate(blocks: update.blocks, diff: update.diff)
                continue
            }
#if os(macOS)
            // A chunk buffered by the tokenizer must not lose an earlier
            // completed line that is still waiting for its trailing preview.
            scheduleMermaidPreview(after: nil)
#endif
        }
        guard !Task.isCancelled else { return }
#if os(macOS)
        await suspendMermaidPreview()
        guard !Task.isCancelled, generation == pipelineGeneration else { return }
#endif
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
        Self.logger.debug("Replacing Markdown: characters=\(value.count)")
        #endif
        let (freshPipeline, generation) = makeFreshPipeline()
#if os(macOS)
        defer { endHostedStream(generation: generation) }
#endif
        var latestBlocks: [RenderedBlock] = []

        _ = await freshPipeline.updateMermaidContentWidth(mermaidContentWidth)
        _ = await freshPipeline.updateTextScale(textScale, codeBlockScale: codeBlockTextScale)

        if !value.isEmpty {
            if let update = await freshPipeline.feed(value) {
                latestBlocks = update.blocks
                #if DEBUG
                Self.logger.debug("Markdown parsed: blocks=\(latestBlocks.count)")
                #endif
            } else {
                #if DEBUG
                Self.logger.warning("Markdown parsing produced no update for nonempty input")
                #endif
            }
        }

        if let update = await freshPipeline.finish() {
            latestBlocks = update.blocks
            #if DEBUG
            Self.logger.debug("Markdown parsing finished: blocks=\(latestBlocks.count)")
            #endif
        } else {
            #if DEBUG
            Self.logger.debug("Markdown parsing finished without an update: blocks=\(latestBlocks.count)")
            #endif
        }

        // Publish the pipeline's own blocks rather than the ones cached from
        // `feed`/`finish`: a scale change that landed while the document was
        // parsing has already been applied there and must not be undone.
        let blocks = await freshPipeline.blocksSnapshot()
        guard generation == pipelineGeneration else { return }
        lastReplacementValue = value
        #if DEBUG
        Self.logger.debug("Queuing Markdown update: blocks=\(blocks.count) (parsed \(latestBlocks.count))")
        #endif
        enqueueUpdate(blocks: blocks, diff: nil)
    }

    /// Applies a font scale (Dynamic Type × host zoom) to the live document
    /// without restarting the parse or the stream. Published as a full
    /// replace, which keeps the selection.
    func updateTextScale(_ scale: CGFloat, codeBlockScale: CGFloat? = nil) async {
#if os(macOS)
        guard !Task.isCancelled else { return }
        // Once accepted, finish this bounded presentation change independently
        // of SwiftUI cancelling its task; cancellation is not a code fallback.
        await Task.immediate {
            await self.updateTextScaleToCompletion(scale, codeBlockScale: codeBlockScale)
        }.value
#else
        await updateTextScaleToCompletion(scale, codeBlockScale: codeBlockScale)
#endif
    }

    private func updateTextScaleToCompletion(_ scale: CGFloat, codeBlockScale: CGFloat?) async {
        let factor = scale.isFinite && scale > 0 ? scale : 1
        let codeFactor = codeBlockScale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard factor != textScale || codeFactor != codeBlockTextScale else { return }
#if os(macOS)
        textScaleRequestRevision &+= 1
        let revision = textScaleRequestRevision
#endif
        textScale = factor
        codeBlockTextScale = codeFactor
        let generation = pipelineGeneration
        if let blocks = await pipeline.updateTextScale(factor, codeBlockScale: codeFactor), generation == pipelineGeneration {
#if os(macOS)
            guard revision == textScaleRequestRevision else { return }
#endif
            enqueueUpdate(blocks: blocks, diff: nil)
        }
    }

    func updateMermaidContentWidth(_ width: CGFloat?) async {
#if os(macOS)
        guard !Task.isCancelled else { return }
        await Task.immediate {
            await self.updateContentWidthToCompletion(width)
        }.value
#else
        await updateContentWidthToCompletion(width)
#endif
    }

    private func updateContentWidthToCompletion(_ width: CGFloat?) async {
        let normalizedWidth: CGFloat? = {
            guard let width, width > 0 else { return nil }
            return width
        }()
        let nextBucket = mermaidWidthBucket(for: normalizedWidth)
        guard nextBucket != mermaidContentWidthBucket else { return }
#if os(macOS)
        contentWidthRequestRevision &+= 1
        let revision = contentWidthRequestRevision
#endif

        mermaidContentWidth = normalizedWidth
        mermaidContentWidthBucket = nextBucket

#if os(macOS)
        let generation = pipelineGeneration
#endif
        if let updatedBlocks = await pipeline.updateMermaidContentWidth(normalizedWidth) {
#if os(macOS)
            guard generation == pipelineGeneration, revision == contentWidthRequestRevision else { return }
#endif
            enqueueUpdate(blocks: updatedBlocks, diff: nil)
        }
    }

    private func enqueueUpdate(blocks: [RenderedBlock], diff: AssemblerDiff?) {
#if os(macOS)
        pendingDocumentIdentity = pipelineGeneration
        scheduleMermaidPreview(after: diff)
#endif
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

#if os(macOS)
    /// A timer must not enter the renderer while a stream update is closing
    /// its fence. Cancellation alone cannot stop a refresh already awaiting
    /// the provider, so let that bounded render unwind before feeding again.
    /// Keep the queued IDs until the new diff confirms which fences closed.
    private func suspendMermaidPreview() async {
        guard let task = mermaidPreviewTask else { return }
        mermaidPreviewTask = nil
        task.cancel()
        await task.value
    }

    private func cancelMermaidPreview() {
        mermaidPreviewTask?.cancel()
        mermaidPreviewTask = nil
        pendingMermaidPreviewIDs.removeAll(keepingCapacity: true)
    }

    /// The leading previews in the renderer keep a continuous stream moving;
    /// this trailing refresh shows the latest complete line when input pauses.
    /// Only changed IDs are queued, never a second scan of the whole message.
    private func scheduleMermaidPreview(after diff: AssemblerDiff?) {
        guard case .bestEffortDebounced(let milliseconds) = theme.mermaidRenderingMode,
              milliseconds > 0 else { return }
        var appendedIDs: Set<BlockID> = []
        for change in diff?.changes ?? [] {
            switch change {
            case .codeAppended(let id, _): appendedIDs.insert(id)
            case .blockEnded(let id):
                appendedIDs.remove(id)
                pendingMermaidPreviewIDs.remove(id)
            default: break
            }
        }
        pendingMermaidPreviewIDs.formUnion(appendedIDs)
        guard !pendingMermaidPreviewIDs.isEmpty else {
            mermaidPreviewTask?.cancel()
            mermaidPreviewTask = nil
            return
        }
        mermaidPreviewTask?.cancel()
        let generation = pipelineGeneration
        let currentPipeline = pipeline
        let timing = mermaidPreviewTiming
        mermaidPreviewTask = Task { [weak self] in
            do { try await timing.sleep(.milliseconds(milliseconds)) }
            catch { return }
            guard let self, !Task.isCancelled, self.pipelineGeneration == generation else { return }
            let ids = self.pendingMermaidPreviewIDs
            let update = await currentPipeline.refreshMermaidPreviews(ids)
            guard !Task.isCancelled, self.pipelineGeneration == generation else { return }
            // A buffered chunk can cancel this render without producing a
            // diff. Retain its IDs until completion so the next deadline can
            // retry the complete lines that have not been published yet.
            self.pendingMermaidPreviewIDs.subtract(ids)
            if let update {
                self.enqueueUpdate(blocks: update.blocks, diff: update.diff)
            }
        }
    }
#endif

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
            Self.logger.debug("Skipping Markdown update: no pending blocks")
            #endif
            return
        }
        #if DEBUG
        Self.logger.debug("Applying Markdown update: blocks=\(blocks.count), replacementToken=\(self.pendingReplaceToken.map { String($0) } ?? "nil")")
        #endif
#if os(macOS)
        documentIdentity = pendingDocumentIdentity
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
#if os(macOS)
        for url in imagePreviews.keys { onImagePreview?(url, nil, pipelineGeneration) }
        imagePreviews.removeAll(keepingCapacity: true)
        finishedImagePreviewURLs.removeAll(keepingCapacity: true)
        imagePreviewSequences.removeAll(keepingCapacity: true)
#endif
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
#if os(macOS)
        for url in imagePreviews.keys where !validURLs.contains(url) {
            imagePreviews[url] = nil
            onImagePreview?(url, nil, pipelineGeneration)
        }
#endif
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
#if os(macOS)
            if let progressive = prefetcher as? any MarkdownProgressiveImagePrefetchingProvider,
               progressive.progressiveJPEGPreviewsEnabled {
                scheduleProgressiveImagePrefetch(url, provider: progressive, generation: generation)
                continue
            }
#endif
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

#if os(macOS)
    private func scheduleProgressiveImagePrefetch(_ url: URL,
        provider: any MarkdownProgressiveImagePrefetchingProvider, generation: UInt64) {
        let sequence = Mutex<UInt64>(0)
        imagePrefetchTasks[url] = Task { [weak self] in
            let result = await provider.prefetch(url) { [weak self] result in
                let revision = sequence.withLock { value in value &+= 1; return value }
                Task { @MainActor [weak self] in
                    self?.receiveImagePreview(result, url: url, generation: generation, sequence: revision)
                }
            }
            guard let self, !Task.isCancelled, generation == self.imagePrefetchGeneration else { return }
            if let result {
                if self.imagePreviews[url] != nil {
                    self.receiveImagePreview(result, url: url, generation: generation, isFinal: true)
                }
                self.finishedImagePreviewURLs.insert(url)
                self.handleImagePrefetchCompletion(url: url, generation: generation)
            } else {
                self.finishedImagePreviewURLs.insert(url)
                self.imagePrefetchTasks[url] = nil
                self.imagePreviews[url] = nil
                self.onImagePreview?(url, nil, self.pipelineGeneration)
            }
        }
    }

    private func receiveImagePreview(_ result: MarkdownImageResult, url: URL,
                                     generation: UInt64, isFinal: Bool = false, sequence: UInt64 = 0) {
        guard generation == imagePrefetchGeneration,
              imageBlockDependencies[url]?.isEmpty == false,
              isFinal || (!finishedImagePreviewURLs.contains(url) &&
                          sequence > imagePreviewSequences[url, default: 0]) else { return }
        if !isFinal { imagePreviewSequences[url] = sequence }
        var result = result
        let size = result.size ?? result.image.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        if let width = theme.imageMaxWidth, width.isFinite, width > 0, size.width > width {
            result.size = CGSize(width: width, height: size.height * width / size.width)
        }
        let preview = MarkdownImagePreview(result: result, isFinal: isFinal)
        imagePreviews[url] = preview
        onImagePreview?(url, preview, pipelineGeneration)
    }
#endif

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
