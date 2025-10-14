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

    @ViewBuilder
    private func blockView(for block: RenderedBlock) -> some View {
        let spacing = spacing(for: block.kind)
        if isHorizontalRule(block) {
            Divider()
                .padding(.vertical, 6)
        } else if block.kind == .table, let table = block.table {
            MarkdownTableView(table: table)
                .padding(.bottom, spacing)
        } else {
            Text(trimmedContent(for: block))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, spacing)
        }
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

    private func isHorizontalRule(_ block: RenderedBlock) -> Bool {
        guard block.kind == .paragraph else { return false }
        guard let runs = block.snapshot.inlineRuns else { return false }
        let rawText = runs.map { $0.text }.joined()
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard let first = stripped.first, ["-", "*", "_"].contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
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

private struct MarkdownTableView: View {
    var table: RenderedTable

    var body: some View {
        VStack(spacing: 0) {
            if let headers = table.headers, !headers.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                        Text(header)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, alignment: alignment(for: index))
                    }
                }
                .padding(.vertical, 6)

                Divider()
                    .padding(.bottom, 6)
            }

            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 12) {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        Text(cell)
                            .frame(maxWidth: .infinity, alignment: alignment(for: column))
                    }
                }
                .padding(.vertical, 6)

                if rowIndex != table.rows.count - 1 {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func alignment(for column: Int) -> Alignment {
        guard let alignments = table.alignments, column < alignments.count else {
            return .leading
        }
        switch alignments[column] {
        case .left, .none:
            return .leading
        case .center:
            return .center
        case .right:
            return .trailing
        }
    }
}
