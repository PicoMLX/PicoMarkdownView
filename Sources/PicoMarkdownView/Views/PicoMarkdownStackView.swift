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
            let contexts = buildContexts(for: blocks)
            renderBlocks(blocks, contexts: contexts)
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
    private struct RenderContext {
        var listDepth: Int = 0
        var quoteDepth: Int = 0
    }

    private func buildContexts(for blocks: [RenderedBlock]) -> [BlockID: RenderContext] {
        guard !blocks.isEmpty else { return [:] }
        let map = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        var cache: [BlockID: RenderContext] = [:]

        @discardableResult
        func context(for block: RenderedBlock) -> RenderContext {
            if let cached = cache[block.id] {
                return cached
            }

            guard let parentID = block.snapshot.parentID,
                  let parent = map[parentID] else {
                let root = RenderContext()
                cache[block.id] = root
                return root
            }

            let parentContext = context(for: parent)
            let listDepth = parentContext.listDepth + (parent.kind.isListItem ? 1 : 0)
            let quoteDepth = parentContext.quoteDepth + (parent.kind.isBlockquote ? 1 : 0)
            let context = RenderContext(listDepth: listDepth, quoteDepth: quoteDepth)
            cache[block.id] = context
            return context
        }

        for block in blocks {
            _ = context(for: block)
        }

        return cache
    }

    private func renderBlocks(_ blocks: [RenderedBlock], contexts: [BlockID: RenderContext]) -> AnyView {
        AnyView(
            ForEach(Array(blocks.enumerated()), id: \.element.id) { pair in
                let index = pair.offset
                let block = pair.element
                let context = contexts[block.id] ?? RenderContext()
                let previousKind = index == 0 ? nil : blocks[index - 1].kind
                renderBlock(block, context: context, previousKind: previousKind)
            }
        )
    }

    private func renderBlock(_ block: RenderedBlock,
                             context: RenderContext,
                             previousKind: BlockKind?) -> AnyView {
        let base = baseView(for: block, context: context)
        let overlayDepth = context.quoteDepth + (block.kind.isBlockquote ? 1 : 0)
        let withOverlay = applyBlockquoteOverlay(to: base, depth: overlayDepth)
        let top = topSpacing(for: block.kind, previous: previousKind)
        let bottom = bottomSpacing(for: block.kind)
        let adjustedTop = isHorizontalRule(block) ? max(top, 6) : top
        let adjustedBottom = isHorizontalRule(block) ? max(bottom, 6) : bottom
        return AnyView(
            withOverlay
                .padding(.top, adjustedTop)
                .padding(.bottom, adjustedBottom)
        )
    }

    private func baseView(for block: RenderedBlock, context: RenderContext) -> AnyView {
        switch block.kind {
        case .listItem:
            if let item = block.listItem {
                return AnyView(
                    MarkdownListRowView(item: item)
                        .padding(.leading, CGFloat(context.listDepth) * 20)
                )
            }
            return AnyView(EmptyView())
        case .table:
            if let table = block.table {
                return AnyView(MarkdownTableView(table: table))
            }
            return AnyView(EmptyView())
        case .blockquote:
            if let quote = block.blockquote {
                return AnyView(
                    Text(quote.content)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                )
            }
            fallthrough
        default:
            return AnyView(
                Text(trimmedContent(for: block))
                    .frame(maxWidth: .infinity, alignment: .leading)
            )
        }
    }

    private func applyBlockquoteOverlay(to view: AnyView, depth: Int) -> AnyView {
        guard depth > 0 else { return view }
        let inset = CGFloat(depth) * 12
        return AnyView(
            view
                .padding(.leading, inset)
                .overlay(alignment: .leading) {
                    HStack(spacing: 12) {
                        ForEach(0..<depth, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.secondary.opacity(0.35))
                                .frame(width: 3)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                }
        )
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

    var isBlockquote: Bool {
        if case .blockquote = self { return true }
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

private extension HorizontalAlignment {
    enum ListBulletAlignment: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[.leading]
        }
    }

    static let listBullet = HorizontalAlignment(ListBulletAlignment.self)
}
