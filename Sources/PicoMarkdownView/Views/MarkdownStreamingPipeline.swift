import Foundation

actor MarkdownStreamingPipeline {
    private let tokenizer: MarkdownTokenizer
    private let assembler: MarkdownAssembler
    private let renderer: MarkdownRenderer

    init(theme: MarkdownRenderTheme = .default()) {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer(theme: theme) { id in
            await assembler.block(id)
        }
        self.tokenizer = tokenizer
        self.assembler = assembler
        self.renderer = renderer
    }

    func feed(_ chunk: String) async -> AttributedString? {
        guard !chunk.isEmpty else { return nil }
        let result = await tokenizer.feed(chunk)
        let diff = await assembler.apply(result)
        return await renderer.apply(diff)
    }

    func finish() async -> AttributedString? {
        let result = await tokenizer.finish()
        let diff = await assembler.apply(result)
        if let updated = await renderer.apply(diff) {
            return updated
        }
        return await renderer.currentAttributedString()
    }

    func snapshot() async -> AttributedString {
        await renderer.currentAttributedString()
    }
}
