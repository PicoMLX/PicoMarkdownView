import SwiftUI
import Observation

public struct PicoMarkdownStackView: View {
    private let input: MarkdownStreamingInput

    @State private var viewModel: MarkdownStreamingViewModel

    private init(input: MarkdownStreamingInput,
                 theme: MarkdownRenderTheme) {
        self.input = input
        _viewModel = State(initialValue: MarkdownStreamingViewModel(theme: theme))
    }

    public init(text: String,
                theme: MarkdownRenderTheme = .default()) {
        self.init(input: .text(text), theme: theme)
    }

    public init(chunks: [String],
                theme: MarkdownRenderTheme = .default()) {
        self.init(input: .chunks(chunks), theme: theme)
    }

    public init(stream: @escaping @Sendable () async -> AsyncStream<String>,
                theme: MarkdownRenderTheme = .default()) {
        self.init(input: .stream(stream), theme: theme)
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
        trimTrailingNewlines(from: block.content)
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
        func context(for block: RenderedBlock, visited: Set<BlockID> = []) -> RenderContext {
            if let cached = cache[block.id] {
                return cached
            }

            if visited.contains(block.id) {
                let root = RenderContext()
                cache[block.id] = root
                return root
            }

            guard let parentID = block.snapshot.parentID,
                  let parent = map[parentID] else {
                let root = RenderContext()
                cache[block.id] = root
                return root
            }

            let parentContext = context(for: parent, visited: visited.union([block.id]))
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
                    MarkdownListRowView(item: item, images: block.images)
                        .padding(.leading, CGFloat(context.listDepth) * 20)
                )
            }
            return AnyView(EmptyView())
        case .table:
            if let table = block.table {
                return AnyView(MarkdownTableView(table: table))
            }
            return AnyView(EmptyView())
        case .fencedCode:
            let trimmed = trimmedContent(for: block)
            return AnyView(
                MarkdownCodeBlockView(text: trimmed,
                                      metadata: block.codeBlock)
            )
        case .math:
            if let math = block.math {
                return AnyView(
                    HStack(alignment: .center, spacing: 0) {
                        Spacer(minLength: 0)
                        MathBlockView(math: math)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                )
            }
            fallthrough
        case .blockquote:
            if let quote = block.blockquote {
                return AnyView(
                    MarkdownBlockquoteContentView(content: quote.content,
                                                  images: block.images)
                        .frame(maxWidth: .infinity, alignment: .leading)
                )
            }
            fallthrough
        default:
            if block.kind == .paragraph, isHorizontalRule(block) {
                return AnyView(
                    Divider()
                        .frame(maxWidth: .infinity)
                )
            }
            let trimmed = trimmedContent(for: block)
            if block.images.isEmpty {
                return AnyView(
                    MarkdownInlineTextView(content: trimmed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                )
            } else {
                return AnyView(
                    MarkdownParagraphContentView(text: trimmed,
                                                 images: block.images)
                        .frame(maxWidth: .infinity, alignment: .leading)
                )
            }
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
        case .math:
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
        case .math:
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
                        MarkdownInlineTextView(content: header)
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
                        MarkdownInlineTextView(content: cell)
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
    var images: [RenderedImage]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: item.bullet)
                .alignmentGuide(.listBullet) { dimensions in
                    dimensions[.trailing]
                }
                .font(.body)
            VStack(alignment: .leading, spacing: 8) {
                MarkdownInlineTextView(content: trimTrailingNewlines(from: item.content))
                    .alignmentGuide(.listBullet) { dimensions in
                        dimensions[.leading]
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !images.isEmpty {
                    MarkdownImageGalleryView(images: images)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MarkdownParagraphContentView: View {
    var text: AttributedString
    var images: [RenderedImage]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasVisibleContent(text) {
                MarkdownInlineTextView(content: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !images.isEmpty {
                MarkdownImageGalleryView(images: images)
            }
        }
    }
}

private struct MarkdownCodeBlockView: View {
    var text: AttributedString
    var metadata: RenderedCodeBlock?
    @Environment(\.picoCodeBlockTheme) private var codeTheme
    @Environment(\.picoCodeHighlighter) private var codeHighlighter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(displayText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(backgroundColor)
        )
    }

    private var backgroundColor: Color {
        Color(platformColor: codeTheme.backgroundColor)
    }

    private var displayText: AttributedString {
        guard let metadata else { return text }
        var highlighted = codeHighlighter.highlight(metadata.code, language: metadata.language, theme: codeTheme)
        if highlighted.characters.last != "\n" {
            highlighted.append(AttributedString("\n"))
        }
        return highlighted
    }
}

private struct MarkdownBlockquoteContentView: View {
    var content: AttributedString
    var images: [RenderedImage]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasVisibleContent(content) {
                MarkdownInlineTextView(content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !images.isEmpty {
                MarkdownImageGalleryView(images: images)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct MarkdownImageGalleryView: View {
    var images: [RenderedImage]

    var body: some View {
        ForEach(images) { descriptor in
            MarkdownRemoteImageView(image: descriptor)
        }
    }
}

private struct MarkdownRemoteImageView: View {
    var image: RenderedImage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let url = image.url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ImagePlaceholderView(style: .loading)
                        case .success(let loaded):
                            loaded
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        case .failure:
                            ImagePlaceholderView(style: .failure(failureDescription))
                        @unknown default:
                            ImagePlaceholderView(style: .failure(failureDescription))
                        }
                    }
                } else {
                    ImagePlaceholderView(style: .failure(failureDescription))
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text(image.altText.isEmpty ? "Image" : image.altText))

            if let title = image.title, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !image.altText.isEmpty {
                Text(image.altText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var failureDescription: String {
        if !image.altText.isEmpty {
            return image.altText
        }
        if let host = image.url?.host, !host.isEmpty {
            return "Image unavailable (\(host))"
        }
        return "Image unavailable"
    }
}

private struct ImagePlaceholderView: View {
    enum Style {
        case loading
        case failure(String)
    }

    var style: Style

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.12))
            switch style {
            case .loading:
                ProgressView()
                    .progressViewStyle(.circular)
            case .failure(let description):
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.title3)
                    Text(description)
                        .multilineTextAlignment(.center)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                }
                .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
    }
}

private func trimTrailingNewlines(from content: AttributedString) -> AttributedString {
    var trimmed = content
    while let last = trimmed.characters.last, last == "\n" {
        trimmed.characters.removeLast()
    }
    return trimmed
}

private func hasVisibleContent(_ content: AttributedString) -> Bool {
    content.characters.contains { !$0.isWhitespace && $0 != "\n" }
}

private extension HorizontalAlignment {
    enum ListBulletAlignment: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[.leading]
        }
    }

    static let listBullet = HorizontalAlignment(ListBulletAlignment.self)
}

private extension Color {
    init(platformColor: MarkdownColor) {
#if canImport(UIKit)
        self.init(platformColor)
#elseif canImport(AppKit)
        self.init(nsColor: platformColor)
#else
        self.init(.sRGBLinear, red: 0, green: 0, blue: 0, opacity: 0)
#endif
    }
}

private struct PicoCodeBlockThemeKey: EnvironmentKey {
    static let defaultValue: CodeBlockTheme = .monospaced()
}

private struct PicoCodeHighlighterKey: EnvironmentKey {
    static let defaultValue: AnyCodeSyntaxHighlighter = AnyCodeSyntaxHighlighter(PlainCodeSyntaxHighlighter())
}

extension EnvironmentValues {
    var picoCodeBlockTheme: CodeBlockTheme {
        get { self[PicoCodeBlockThemeKey.self] }
        set { self[PicoCodeBlockThemeKey.self] = newValue }
    }

    var picoCodeHighlighter: AnyCodeSyntaxHighlighter {
        get { self[PicoCodeHighlighterKey.self] }
        set { self[PicoCodeHighlighterKey.self] = newValue }
    }
}

public extension View {
    func picoCodeTheme(_ theme: CodeBlockTheme) -> some View {
        environment(\.picoCodeBlockTheme, theme)
    }

    func picoCodeHighlighter<H: CodeSyntaxHighlighter>(_ highlighter: H) -> some View {
        environment(\.picoCodeHighlighter, AnyCodeSyntaxHighlighter(highlighter))
    }
}
