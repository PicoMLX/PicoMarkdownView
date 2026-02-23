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

    init(theme: MarkdownRenderTheme = .default(), imageProvider: MarkdownImageProvider? = nil) {
        let tokenizer = MarkdownTokenizer()
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
        let result = await tokenizer.feed(chunk)
        let rawDiff = await assembler.apply(result)
        guard !rawDiff.changes.isEmpty else { return nil }
        _ = await renderer.apply(rawDiff)
        let diff = nextEmittedDiff(from: rawDiff)
        let blocks = await renderer.renderedBlocks()
        return StreamingUpdate(diff: diff, blocks: blocks)
    }

    func finish() async -> StreamingUpdate? {
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
        let refreshed = await renderer.refreshBlocks(ids)
        guard !refreshed.isEmpty else { return nil }

        let changes = refreshed.map { AssemblerDiff.Change.blockEnded(id: $0) }
        let diff = nextEmittedDiff(from: AssemblerDiff(documentVersion: 0, changes: changes))
        let blocks = await renderer.renderedBlocks()
        return StreamingUpdate(diff: diff, blocks: blocks)
    }

    func updateMermaidContentWidth(_ width: CGFloat?) async -> [RenderedBlock]? {
        await renderer.updateMermaidContentWidth(width)
    }

    func snapshot() async -> AttributedString {
        await renderer.currentAttributedString()
    }

    func blocksSnapshot() async -> [RenderedBlock] {
        await renderer.renderedBlocks()
    }

    private func nextEmittedDiff(from diff: AssemblerDiff) -> AssemblerDiff {
        guard !diff.changes.isEmpty else { return diff }
        emittedDiffVersion &+= 1
        return AssemblerDiff(documentVersion: emittedDiffVersion, changes: diff.changes)
    }
}
