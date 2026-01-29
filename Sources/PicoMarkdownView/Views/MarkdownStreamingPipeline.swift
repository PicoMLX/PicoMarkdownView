import Foundation

struct StreamingUpdate: Sendable {
    var diff: AssemblerDiff
    var blocks: [RenderedBlock]
}

actor MarkdownStreamingPipeline {
    private let tokenizer: MarkdownTokenizer
    private let assembler: MarkdownAssembler
    private let renderer: MarkdownRenderer

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
        let diff = await assembler.apply(result)
        guard !diff.changes.isEmpty else { return nil }
        _ = await renderer.apply(diff)
        let blocks = await renderer.renderedBlocks()
        return StreamingUpdate(diff: diff, blocks: blocks)
    }

    func finish() async -> StreamingUpdate? {
        let result = await tokenizer.finish()
        let diff = await assembler.apply(result)
        guard !diff.changes.isEmpty else { return nil }
        _ = await renderer.apply(diff)
        let blocks = await renderer.renderedBlocks()
        return StreamingUpdate(diff: diff, blocks: blocks)
    }

    func snapshot() async -> AttributedString {
        await renderer.currentAttributedString()
    }

    func blocksSnapshot() async -> [RenderedBlock] {
        await renderer.renderedBlocks()
    }
}
