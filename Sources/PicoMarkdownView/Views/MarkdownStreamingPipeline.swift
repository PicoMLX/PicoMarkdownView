import Foundation

struct StreamingUpdate: Sendable {
    var diff: AssemblerDiff
    var blocks: [RenderedBlock]
}

actor MarkdownStreamingPipeline {
    private let tokenizer: MarkdownTokenizer
    private let assembler: MarkdownAssembler
    private let renderer: MarkdownRenderer
    private var emittedDiffVersion: UInt64 = 0
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextOperationWaiter = 0
    private(set) var scaleRequestVersion: UInt64 = 0
    private(set) var widthRequestVersion: UInt64 = 0

    init(theme: MarkdownRenderTheme = .default(),
         imageProvider: MarkdownImageProvider? = nil,
         tagPrefixes: Set<TagPrefix> = TagPrefix.defaults) {
        let tokenizer = MarkdownTokenizer(tagPrefixes: tagPrefixes)
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer(theme: theme, imageProvider: imageProvider) { id in
            await assembler.block(id)
        }
        self.tokenizer = tokenizer
        self.assembler = assembler
        self.renderer = renderer
    }

    func feed(_ chunk: String) async -> StreamingUpdate? {
        guard !chunk.isEmpty else { return nil }
        await acquireOperation()
        defer { releaseOperation() }
        let result = await tokenizer.feed(chunk)
        let rawDiff = await assembler.apply(result)
        guard !rawDiff.changes.isEmpty else { return nil }
        _ = await renderer.apply(rawDiff)
        let diff = nextEmittedDiff(from: rawDiff)
        let blocks = await renderer.renderedBlocks()
        return StreamingUpdate(diff: diff, blocks: blocks)
    }

    func finish() async -> StreamingUpdate? {
        await acquireOperation()
        defer { releaseOperation() }
        let result = await tokenizer.finish()
        let rawDiff = await assembler.apply(result)
        guard !rawDiff.changes.isEmpty else { return nil }
        _ = await renderer.apply(rawDiff)
        let diff = nextEmittedDiff(from: rawDiff)
        let blocks = await renderer.renderedBlocks()
        return StreamingUpdate(diff: diff, blocks: blocks)
    }

    func refreshBlocks(_ ids: Set<BlockID>) async -> StreamingUpdate? {
        guard !ids.isEmpty else { return nil }
        await acquireOperation()
        defer { releaseOperation() }
        let refreshed = await renderer.refreshBlocks(ids)
        guard !refreshed.isEmpty else { return nil }

        let changes = refreshed.map { AssemblerDiff.Change.blockEnded(id: $0) }
        let diff = nextEmittedDiff(from: AssemblerDiff(documentVersion: 0, changes: changes))
        let blocks = await renderer.renderedBlocks()
        return StreamingUpdate(diff: diff, blocks: blocks)
    }

    func updateMermaidContentWidth(_ width: CGFloat?) async -> StreamingUpdate? {
        widthRequestVersion &+= 1
        let requestVersion = widthRequestVersion
        await acquireOperation()
        defer { releaseOperation() }
        guard requestVersion == widthRequestVersion else { return nil }
        guard let blocks = await renderer.updateMermaidContentWidth(width) else { return nil }
        let diff = nextEmittedDiff(from: AssemblerDiff(documentVersion: 0,
            changes: blocks.map { .blockEnded(id: $0.id) }))
        return StreamingUpdate(diff: diff, blocks: blocks)
    }

    func updateTextScale(_ scale: CGFloat, skipIfCancelled: Bool = true) async -> StreamingUpdate? {
        guard !skipIfCancelled || !Task.isCancelled else { return nil }
        scaleRequestVersion &+= 1
        let requestVersion = scaleRequestVersion
        await acquireOperation()
        defer { releaseOperation() }
        guard (!skipIfCancelled || !Task.isCancelled), requestVersion == scaleRequestVersion else { return nil }
        guard let prepared = await renderer.prepareTextScale(scale, shouldContinue: { [weak self] in
            guard !skipIfCancelled || !Task.isCancelled, let self else { return false }
            return await self.isCurrentScaleRequest(requestVersion)
        }) else { return nil }
        guard (!skipIfCancelled || !Task.isCancelled), requestVersion == scaleRequestVersion else { return nil }
        let refreshed = await renderer.commitTextScale(prepared)
        guard (!skipIfCancelled || !Task.isCancelled), requestVersion == scaleRequestVersion else {
            // Cancellation can arrive during the actor handoff to commit.
            // Restore the last published scale before releasing the gate.
            await renderer.rollbackTextScale(prepared)
            return nil
        }
        guard !refreshed.isEmpty else { return nil }
        let diff = nextEmittedDiff(from: AssemblerDiff(documentVersion: 0,
            changes: refreshed.map { .blockEnded(id: $0) }))
        return StreamingUpdate(diff: diff, blocks: prepared.blocks)
    }

    private func isCurrentScaleRequest(_ version: UInt64) -> Bool {
        version == scaleRequestVersion
    }

    private func acquireOperation() async {
        // Actor reentrancy must not interleave tokenizer/assembler mutations
        // with a renderer holding their snapshots across an image/math await.
        if !operationInProgress {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func releaseOperation() {
        guard nextOperationWaiter < operationWaiters.count else {
            operationInProgress = false
            return
        }
        let next = operationWaiters[nextOperationWaiter]
        nextOperationWaiter += 1
        if nextOperationWaiter == operationWaiters.count {
            operationWaiters.removeAll(keepingCapacity: true)
            nextOperationWaiter = 0
        }
        // Keep ownership reserved for this waiter until it resumes and exits.
        next.resume()
    }

    func snapshot() async -> AttributedString {
        await acquireOperation()
        defer { releaseOperation() }
        return await renderer.currentAttributedString()
    }

    func blocksSnapshot() async -> [RenderedBlock] {
        await acquireOperation()
        defer { releaseOperation() }
        return await renderer.renderedBlocks()
    }

    private func nextEmittedDiff(from diff: AssemblerDiff) -> AssemblerDiff {
        guard !diff.changes.isEmpty else { return diff }
        emittedDiffVersion &+= 1
        return AssemblerDiff(documentVersion: emittedDiffVersion, changes: diff.changes)
    }
}
