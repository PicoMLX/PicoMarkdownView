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
        VStack(alignment: .leading, spacing: 8) {
            let parts = paragraphs(from: bindable.attributedText.wrappedValue)
            ForEach(Array(parts.enumerated()), id: \.offset) { item in
                Text(item.element)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .task(id: input.id) {
            await viewModel.consume(input)
        }
    }

    private func paragraphs(from attributed: AttributedString) -> [AttributedString] {
        if attributed.characters.isEmpty {
            return []
        }
        var parts: [AttributedString] = []
        var start = attributed.startIndex
        while start < attributed.endIndex {
            let remaining = attributed[start...]
            if let separator = remaining.range(of: "\n\n") {
                let segment = attributed[start..<separator.lowerBound]
                if !segment.characters.isEmpty {
                    parts.append(AttributedString(segment))
                }
                start = separator.upperBound
            } else {
                let segment = attributed[start..<attributed.endIndex]
                if !segment.characters.isEmpty {
                    parts.append(AttributedString(segment))
                }
                break
            }
        }
        return parts.isEmpty ? [attributed] : parts
    }
}
