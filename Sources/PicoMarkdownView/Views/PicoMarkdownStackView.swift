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
            let blocks = bindable.blocks.wrappedValue
            let segments = buildSegments(from: blocks)
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                let previousKind = index > 0 ? segments[index - 1].lastKind : nil
                segmentView(segment, previousKind: previousKind)
            }
        }
        .task(id: input.id) {
            await viewModel.consume(input)
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

    private func buildSegments(from blocks: [RenderedBlock]) -> [RenderedSegment] {
        var result: [RenderedSegment] = []
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            if block.kind.isListItem {
                var group: [RenderedBlock] = []
                while index < blocks.count, blocks[index].kind.isListItem {
                    group.append(blocks[index])
                    index += 1
                }
                result.append(.list(group))
            } else {
                result.append(.block(block))
                index += 1
            }
        }
        return result
    }

    @ViewBuilder
    private func segmentView(_ segment: RenderedSegment, previousKind: BlockKind?) -> some View {
        switch segment {
        case .list(let items):
            let firstKind = items.first?.kind ?? .listItem(ordered: false, index: nil, task: nil)
            let lastKind = items.last?.kind ?? firstKind
            MarkdownListGroupView(items: items)
                .padding(.top, topSpacing(for: firstKind, previous: previousKind))
                .padding(.bottom, bottomSpacing(for: lastKind))
        case .block(let block):
            let top = topSpacing(for: block.kind, previous: previousKind)
            let bottom = bottomSpacing(for: block.kind)
            let minTop = isHorizontalRule(block) ? max(top, 6) : top
            let minBottom = isHorizontalRule(block) ? max(bottom, 6) : bottom
            blockContent(for: block)
                .padding(.top, minTop)
                .padding(.bottom, minBottom)
        }
    }

    @ViewBuilder
    private func blockContent(for block: RenderedBlock) -> some View {
        if isHorizontalRule(block) {
            Divider()
        } else if block.kind == .table, let table = block.table {
            MarkdownTableView(table: table)
        } else if block.listItem != nil {
            MarkdownListGroupView(items: [block])
        } else if let quote = block.blockquote {
            MarkdownBlockquoteView(blockquote: quote)
        } else {
            Text(trimmedContent(for: block))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    private func bottomSpacing(for kind: BlockKind) -> CGFloat {
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

    private func topSpacing(for kind: BlockKind, previous: BlockKind?) -> CGFloat {
        guard let previous else { return 0 }
        switch kind {
        case .heading(let level):
            switch level {
            case 1: return previous.isHeading ? 14 : 18
            case 2: return previous.isHeading ? 12 : 16
            case 3: return previous.isHeading ? 10 : 14
            default: return previous.isHeading ? 8 : 12
            }
        case .listItem:
            return previous.isListItem ? 2 : 6
        case .blockquote:
            return 8
        case .paragraph:
            return previous == .paragraph ? 6 : 8
        case .fencedCode:
            return 10
        case .table:
            return 12
        case .unknown:
            return 8
        }
    }
}

private extension BlockKind {
    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }

    var isListItem: Bool {
        if case .listItem = self { return true }
        return false
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
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, alignment: alignment(for: index))
                    }
                }
                .padding(.vertical, 6)

                Divider()
                    .padding(.bottom, 6)
            }

            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        Text(cell)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
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

private enum RenderedSegment: Identifiable {
    case block(RenderedBlock)
    case list([RenderedBlock])

    var id: String {
        switch self {
        case .block(let block):
            return "block_\(block.id)"
        case .list(let blocks):
            let identifier = blocks.map { String($0.id) }.joined(separator: "-")
            return "list_\(identifier)"
        }
    }

    var lastKind: BlockKind {
        switch self {
        case .block(let block):
            return block.kind
        case .list(let blocks):
            return blocks.last?.kind ?? .listItem(ordered: false, index: nil, task: nil)
        }
    }
}

private struct MarkdownListGroupView: View {
    var items: [RenderedBlock]

    var body: some View {
        VStack(alignment: .listBullet, spacing: 4) {
            ForEach(items, id: \.id) { block in
                if let item = block.listItem {
                    MarkdownListRowView(item: item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownListRowView: View {
    var item: RenderedListItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: item.bullet)
                .alignmentGuide(.listBullet) { dimensions in
                    dimensions[.trailing]
                }
            Text(item.content)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .alignmentGuide(.listBullet) { dimensions in
                    dimensions[.leading]
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MarkdownBlockquoteView: View {
    var blockquote: RenderedBlockquote

    var body: some View {
        Text(blockquote.content)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .padding(.vertical, 6)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                    .padding(.vertical, 6)
            }
    }
}

private extension HorizontalAlignment {
    enum ListBulletAlignment: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[.leading]
        }
    }

    static let listBullet = HorizontalAlignment(ListBulletAlignment.self)
}
