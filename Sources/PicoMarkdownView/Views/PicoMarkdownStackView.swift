import SwiftUI
import Observation

public struct PicoMarkdownStackView: View {
    private let input: MarkdownStreamingInput

    @State private var viewModel: MarkdownStreamingViewModel

    private init(input: MarkdownStreamingInput, theme: MarkdownRenderTheme) {
        self.input = input
        _viewModel = State(initialValue: MarkdownStreamingViewModel(theme: theme))
    }

    public init(text: String) {
        self.init(input: .text(text), theme: .default())
    }

    public init(chunks: [String]) {
        self.init(input: .chunks(chunks), theme: .default())
    }

    public init(stream: @escaping @Sendable () async -> AsyncStream<String>) {
        self.init(input: .stream(stream), theme: .default())
    }

    public var body: some View {
        let bindable = Bindable(viewModel)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(bindable.blocks.wrappedValue) { block in
                blockView(for: block)
            }
        }
        .task(id: input.id) {
            await viewModel.consume(input)
        }
    }

    private func blockView(for block: RenderedBlock) -> some View {
        let spacing = spacing(for: block.kind)
        return Text(trimmedContent(for: block))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, spacing)
    }

    private func trimmedContent(for block: RenderedBlock) -> AttributedString {
        var content = block.content
        while let last = content.characters.last, last == "\n" {
            let end = content.endIndex
            let previous = content.index(beforeCharacter: end)
            content.removeSubrange(previous..<end)
        }
        return content
    }

    private func spacing(for kind: BlockKind) -> CGFloat {
        switch kind {
        case .heading(let level):
            return level <= 2 ? 8 : 6
        case .listItem:
            return 4
        case .blockquote:
            return 8
        case .paragraph:
            return 8
        case .fencedCode:
            return 12
        case .table:
            return 12
        case .unknown:
            return 8
        }
    }
}
