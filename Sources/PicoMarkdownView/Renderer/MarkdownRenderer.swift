import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Theme configuration for Markdown rendering.
///
/// All properties are genuinely `Sendable` — no `@unchecked` needed.
/// Fonts and colors are stored as specifications (`FontSpec`, `ThemeColor`)
/// and resolved to platform types at render time inside the renderer actor.
public struct MarkdownRenderTheme: Sendable {
    public let bodyFont: FontSpec
    public let codeFont: FontSpec
    public let blockquoteColor: ThemeColor
    public let linkColor: ThemeColor
    public let headingFonts: [Int: FontSpec]
    public let imageMaxWidth: CGFloat?
    public let codeBlockTheme: CodeBlockTheme?
    public let codeHighlighter: AnyCodeSyntaxHighlighter?
    public let mermaidRenderingMode: MermaidRenderingMode

    public init(bodyFont: FontSpec,
                codeFont: FontSpec,
                blockquoteColor: ThemeColor,
                linkColor: ThemeColor,
                headingFonts: [Int: FontSpec],
                imageMaxWidth: CGFloat? = nil,
                codeBlockTheme: CodeBlockTheme? = nil,
                codeHighlighter: AnyCodeSyntaxHighlighter? = nil,
                mermaidRenderingMode: MermaidRenderingMode = .onFenceClose) {
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.blockquoteColor = blockquoteColor
        self.linkColor = linkColor
        self.headingFonts = headingFonts
        self.imageMaxWidth = imageMaxWidth
        self.codeBlockTheme = codeBlockTheme
        self.codeHighlighter = codeHighlighter
        self.mermaidRenderingMode = mermaidRenderingMode
    }

    public static func `default`() -> MarkdownRenderTheme {
        let bodySize: CGFloat
        #if canImport(UIKit)
        bodySize = UIFont.preferredFont(forTextStyle: .body).pointSize + 2
        #else
        bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize + 2
        #endif

        let body = FontSpec(size: bodySize)
        let code = FontSpec(size: bodySize, design: .monospaced)

        return MarkdownRenderTheme(
            bodyFont: body,
            codeFont: code,
            blockquoteColor: .secondaryLabel,
            linkColor: .link,
            headingFonts: [
                1: FontSpec(size: bodySize * 1.6, weight: .bold),
                2: FontSpec(size: bodySize * 1.4, weight: .bold),
                3: FontSpec(size: bodySize * 1.2, weight: .semibold),
                4: FontSpec(size: bodySize * 1.1, weight: .semibold),
                5: FontSpec(size: bodySize, weight: .semibold),
                6: FontSpec(size: bodySize),
            ],
            imageMaxWidth: nil,
            codeBlockTheme: .gitHub(),
            codeHighlighter: AnyCodeSyntaxHighlighter(PrismCodeHighlighter()),
            mermaidRenderingMode: .onFenceClose
        )
    }

    /// Returns a copy with a different code block theme and highlighter,
    /// keeping every other setting. Pass `codeHighlighter: nil` to fall back
    /// to plain monospaced rendering, or wrap a custom
    /// `CodeSyntaxHighlighter` to swap engines.
    public func withCodeHighlighting(codeBlockTheme: CodeBlockTheme?,
                                     codeHighlighter: AnyCodeSyntaxHighlighter?) -> MarkdownRenderTheme {
        MarkdownRenderTheme(bodyFont: bodyFont,
                            codeFont: codeFont,
                            blockquoteColor: blockquoteColor,
                            linkColor: linkColor,
                            headingFonts: headingFonts,
                            imageMaxWidth: imageMaxWidth,
                            codeBlockTheme: codeBlockTheme,
                            codeHighlighter: codeHighlighter,
                            mermaidRenderingMode: mermaidRenderingMode)
    }

    /// A copy with every font size multiplied by `scale`, except the code
    /// block theme's font, which uses `codeBlockScale` when given: the
    /// default code block theme is sized from the system body size without
    /// the body font's offset, so Dynamic Type moves it by a different ratio.
    /// Colors, widths, highlighter and diagram settings are unchanged.
    public func scaled(by scale: CGFloat, codeBlock codeBlockScale: CGFloat? = nil) -> MarkdownRenderTheme {
        let factor = scale.isFinite && scale > 0 ? scale : 1
        let codeFactor = codeBlockScale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? factor
        guard factor != 1 || codeFactor != 1 else { return self }
        let scaledCodeTheme = codeBlockTheme.map { code in
            CodeBlockTheme(font: code.font.withSize(code.font.pointSize * codeFactor),
                           foregroundColor: code.foregroundColor,
                           backgroundColor: code.backgroundColor,
                           tokenColors: code.tokenColors)
        }
        return MarkdownRenderTheme(bodyFont: bodyFont.withSize(bodyFont.pointSize * factor),
                                   codeFont: codeFont.withSize(codeFont.pointSize * factor),
                                   blockquoteColor: blockquoteColor,
                                   linkColor: linkColor,
                                   headingFonts: headingFonts.mapValues { $0.withSize($0.pointSize * factor) },
                                   imageMaxWidth: imageMaxWidth,
                                   codeBlockTheme: scaledCodeTheme,
                                   codeHighlighter: codeHighlighter,
                                   mermaidRenderingMode: mermaidRenderingMode)
    }
}

actor MarkdownRenderer {
    typealias SnapshotProvider = @Sendable (BlockID) async -> BlockSnapshot

    /// The theme as given; `attributeBuilder` renders with it scaled by
    /// `textScale`.
    private let theme: MarkdownRenderTheme
    private var attributeBuilder: MarkdownAttributeBuilder
    private let imageProvider: MarkdownImageProvider?
    private let injectedMermaidProvider: (any MermaidDiagramProvider)?
    private let snapshotProvider: SnapshotProvider
    private var blocks: [RenderedBlock] = []
    private var indexByID: [BlockID: Int] = [:]
    private var mermaidContentWidthBucket: Int?
    private var runtimeMermaidContentWidth: CGFloat?
    private var textScale: CGFloat = 1
    private var codeBlockTextScale: CGFloat = 1
    /// Bumped when the builder is replaced, so a render that was in flight
    /// with the old fonts is redone instead of landing in the new document.
    private var builderGeneration: UInt64 = 0

    init(theme: MarkdownRenderTheme = .default(),
         imageProvider: MarkdownImageProvider? = nil,
         mermaidProvider: (any MermaidDiagramProvider)? = nil,
         snapshotProvider: @escaping SnapshotProvider) {
        self.theme = theme
        self.imageProvider = imageProvider
        self.injectedMermaidProvider = mermaidProvider
        let resolvedMermaidProvider = mermaidProvider ?? MermaidDiagramProviders.makeDefaultProvider(theme: theme)
        self.attributeBuilder = MarkdownAttributeBuilder(theme: theme,
                                                         imageProvider: imageProvider,
                                                         mermaidProvider: resolvedMermaidProvider)
        self.snapshotProvider = snapshotProvider
    }

    /// Re-renders every block with the theme's fonts scaled by `scale`. The
    /// parse is untouched: block ids, order and snapshots stay as they are.
    /// Returns the re-rendered blocks, or `nil` when the scale is unchanged.
    func updateTextScale(_ scale: CGFloat, codeBlockScale: CGFloat? = nil) async -> [RenderedBlock]? {
        let factor = scale.isFinite && scale > 0 ? scale : 1
        let codeFactor = codeBlockScale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? factor
        guard factor != textScale || codeFactor != codeBlockTextScale else { return nil }
        textScale = factor
        codeBlockTextScale = codeFactor
        let scaledTheme = theme.scaled(by: factor, codeBlock: codeFactor)
        // The scale and its builder are installed in one synchronous step
        // (the diagram width goes in through the initializer), so two
        // overlapping requests cannot leave the renderer reporting one scale
        // while rendering with another.
        attributeBuilder = MarkdownAttributeBuilder(
            theme: scaledTheme,
            imageProvider: imageProvider,
            mermaidProvider: injectedMermaidProvider ?? MermaidDiagramProviders.makeDefaultProvider(theme: scaledTheme),
            runtimeMermaidMaxWidth: runtimeMermaidContentWidth)
        builderGeneration &+= 1

        // The stream may append to a block while its scaled render awaits
        // an image or diagram, and that refresh lands first. A render whose
        // snapshot is no longer the block's is redone against the current
        // one instead of landing older text; a block removed meanwhile is
        // skipped.
        for id in blocks.map(\.id) {
            while let index = indexByID[id] {
                let snapshot = blocks[index].snapshot
                let placement = listPlacement(for: snapshot)
                let rendered = await render(snapshot: snapshot, previousBlockKind: previousBlockKind(at: index),
                                            blockquoteLevel: blocks[index].blockquoteLevel, placement: placement)
                guard let current = indexByID[id] else { break }
                if blocks[current].snapshot == snapshot {
                    blocks[current].listPlacement = placement
                    blocks[current].updatePresentation(from: rendered)
                    break
                }
            }
        }
        return blocks
    }

    /// Renders with the current builder, again if the builder changed while
    /// an image or diagram was awaited, so old fonts never land.
    private func render(snapshot: BlockSnapshot, previousBlockKind: BlockKind?, blockquoteLevel: Int,
                        placement: ListPlacement) async -> RenderedContentResult {
        while true {
            let generation = builderGeneration
            let rendered = await attributeBuilder.render(snapshot: snapshot, previousBlockKind: previousBlockKind,
                                                         blockquoteLevel: blockquoteLevel,
                                                         listIndent: placement.indent,
                                                         listMarker: placement.marker,
                                                         markerOnFirstChild: placement.markerOnFirstChild,
                                                         blockquoteBarInset: placement.barInset)
            if generation == builderGeneration { return rendered }
        }
    }

    /// Applies a diff to the per-block render cache. Returns whether anything
    /// visible changed.
    ///
    /// The renderer deliberately does **not** maintain a spliced full-document
    /// `AttributedString` here: keeping one current costs O(document) per
    /// chunk (character-offset walks plus a splice), while the streaming view
    /// layer only ever consumes `renderedBlocks()` and applies its own
    /// per-block edits to `NSTextStorage`. Callers that need the joined
    /// document (debug store, tests) get it on demand from
    /// `currentAttributedString()`.
    @discardableResult
    func apply(_ diff: AssemblerDiff) async -> Bool {
        guard !diff.changes.isEmpty else { return false }

        var mutated = false

        for change in diff.changes {
            switch change {
            case .blockStarted(let id, _, let position):
                await insertBlock(id: id, at: position)
                mutated = true
                // A new child changes its parent's snapshot (childIDs), and
                // some renders depend on children — e.g. container-only quote
                // parents render nothing. Refresh the parent so its cached
                // render doesn't go stale mid-stream.
                if let parentID = await snapshotProvider(id).parentID {
                    _ = await refreshBlock(id: parentID)
                }
            case .runsAppended(let id, _),
                 .codeAppended(let id, _),
                 .tableHeaderConfirmed(let id),
                 .tableRowAppended(let id, _),
                 .blockEnded(let id):
                mutated = await refreshBlock(id: id) || mutated
            case .blocksDiscarded(let range):
                removeBlocks(in: range)
                mutated = true
            }
        }

        return mutated
    }

    func currentAttributedString() -> AttributedString {
        var joined = AttributedString()
        for block in blocks {
            joined.append(block.content)
        }
        return joined
    }

    func renderedBlocks() -> [RenderedBlock] {
        blocks
    }

    func refreshBlocks(_ ids: Set<BlockID>) async -> [BlockID] {
        guard !ids.isEmpty else { return [] }

        let orderedIDs = ids.compactMap { id -> (index: Int, id: BlockID)? in
            guard let index = indexByID[id] else { return nil }
            return (index, id)
        }
        .sorted { $0.index < $1.index }
        .map(\.id)

        guard !orderedIDs.isEmpty else { return [] }
#if canImport(AppKit)
        await attributeBuilder.invalidateTableCache(for: Set(orderedIDs))
#endif

        var refreshed: [BlockID] = []
        refreshed.reserveCapacity(orderedIDs.count)
        for id in orderedIDs {
            if await refreshBlock(id: id) {
                refreshed.append(id)
            }
        }
        return refreshed
    }

    func updateMermaidContentWidth(_ width: CGFloat?) async -> [RenderedBlock]? {
        let effectiveWidth = effectiveMermaidContentWidth(for: width)
        let bucket = mermaidWidthBucket(for: effectiveWidth)
        guard bucket != mermaidContentWidthBucket else { return nil }
        mermaidContentWidthBucket = bucket
        runtimeMermaidContentWidth = width

        await attributeBuilder.setRuntimeMermaidMaxWidth(width)

        var mutated = false
        let candidateIDs = blocks.filter(shouldRefreshForContentWidthChange).map(\.id)
#if canImport(AppKit)
        await attributeBuilder.invalidateTableCache(for: Set(candidateIDs))
#endif
        for id in candidateIDs {
            mutated = await refreshBlock(id: id) || mutated
        }

        return mutated ? blocks : nil
    }

    private func insertBlock(id: BlockID, at position: Int) async {
        guard indexByID[id] == nil else { return }
        let snapshot = await snapshotProvider(id)
        let previousKind = previousBlockKind(at: position)
        let block = await buildRenderedBlock(id: id, snapshot: snapshot, previousBlockKind: previousKind)
        let index = max(0, min(position, blocks.count))

        blocks.insert(block, at: index)
        rebuildIndex(startingAt: index)
    }

    private func refreshBlock(id: BlockID) async -> Bool {
        guard let index = indexByID[id] else { return false }
        let snapshot = await snapshotProvider(id)
        let previousKind = previousBlockKind(at: index)
        let quoteLevel = blockquoteLevel(for: snapshot)
        let placement = listPlacement(for: snapshot)
        let rendered = await render(snapshot: snapshot, previousBlockKind: previousKind, blockquoteLevel: quoteLevel,
                                    placement: placement)

        let oldContent = blocks[index].content
        let newContent = rendered.attributed

#if canImport(AppKit)
        let didMutate = oldContent != newContent || blocks[index].table != rendered.table
#else
        let didMutate = oldContent != newContent
#endif

        blocks[index].kind = snapshot.kind
        blocks[index].snapshot = snapshot
        blocks[index].blockquoteLevel = quoteLevel
        blocks[index].listPlacement = placement
        blocks[index].updatePresentation(from: rendered)
        return didMutate
    }

    private func removeBlocks(in range: Range<Int>) {
        guard !blocks.isEmpty else { return }
        let lower = max(range.lowerBound, 0)
        let upper = min(range.upperBound, blocks.count)
        guard lower < upper else { return }
        let removalRange = lower..<upper

        let removed = blocks[removalRange]
        blocks.removeSubrange(removalRange)
        for block in removed {
            indexByID[block.id] = nil
        }
        rebuildIndex(startingAt: lower)
    }

    private func rebuildIndex(startingAt start: Int) {
        let startIndex = max(0, start)
        for idx in startIndex..<blocks.count {
            indexByID[blocks[idx].id] = idx
        }
    }

    private func previousBlockKind(at index: Int) -> BlockKind? {
        guard index > 0, index <= blocks.count else { return nil }
        return blocks[index - 1].kind
    }

    private func shouldRefreshForContentWidthChange(_ block: RenderedBlock) -> Bool {
        if !block.images.isEmpty {
            return true
        }
        guard theme.mermaidRenderingMode.isEnabled else { return false }
        if block.mermaidDiagram != nil {
            return true
        }
        guard block.snapshot.isClosed else { return false }
        guard case let .fencedCode(language) = block.kind else { return false }
        return isMermaidLanguage(language)
    }

    private func isMermaidLanguage(_ language: String?) -> Bool {
        guard let language else { return false }
        switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mermaid", "mmd", "mermaidjs":
            return true
        default:
            return false
        }
    }

    private func effectiveMermaidContentWidth(for runtimeWidth: CGFloat?) -> CGFloat? {
        let normalizedRuntime = runtimeWidth.flatMap { $0 > 0 ? $0 : nil }
        let themeWidth = theme.imageMaxWidth.flatMap { $0 > 0 ? $0 : nil }
        switch (normalizedRuntime, themeWidth) {
        case let (.some(runtime), .some(themeCap)):
            return min(runtime, themeCap)
        case let (.some(runtime), .none):
            return runtime
        case let (.none, .some(themeCap)):
            return themeCap
        case (.none, .none):
            return nil
        }
    }

    private func mermaidWidthBucket(for width: CGFloat?) -> Int? {
        guard let width, width > 0 else { return nil }
        return Int((width / 8).rounded(.toNearestOrAwayFromZero))
    }

    private func buildRenderedBlock(id: BlockID, snapshot: BlockSnapshot, previousBlockKind: BlockKind? = nil) async -> RenderedBlock {
        let quoteLevel = blockquoteLevel(for: snapshot)
        let placement = listPlacement(for: snapshot)
        let rendered = await render(snapshot: snapshot, previousBlockKind: previousBlockKind, blockquoteLevel: quoteLevel,
                                    placement: placement)
        return RenderedBlock(id: id,
                             kind: snapshot.kind,
                             content: rendered.attributed,
                             snapshot: snapshot,
                             table: rendered.table,
                             listItem: rendered.listItem,
                             blockquote: rendered.blockquote,
                             math: rendered.math,
                             images: rendered.images,
                             codeBlock: rendered.codeBlock,
                             mermaidDiagram: rendered.mermaidDiagram,
                             blockquoteLevel: quoteLevel,
                             listPlacement: placement)
    }

    /// How many blockquotes enclose a block (the block's own, when it is
    /// one, included), from its parent chain in the rendered list.
    private func blockquoteLevel(for snapshot: BlockSnapshot) -> Int {
        if let parent = snapshot.parentID, indexByID[parent] == nil,
           let retained = indexByID[snapshot.id] {
            // A closed parent can be evicted before its retained children.
            return blocks[retained].blockquoteLevel
        }
        let inherited = snapshot.parentID.flatMap { indexByID[$0] }.map { blocks[$0].blockquoteLevel } ?? 0
        return inherited + (snapshot.kind == .blockquote ? 1 : 0)
    }

    /// Where a block sits in a list item, from its parent in the rendered
    /// list: a child block starts at the item's text column (so do the
    /// blocks of a quote inside the item), and the first
    /// child of an item without text of its own carries the item's marker
    /// when it is a paragraph or heading. The item then renders nothing.
    /// A quote's bars start at the column the quote starts at, and stay
    /// there for every block inside it.
    private func listPlacement(for snapshot: BlockSnapshot) -> ListPlacement {
        func carriesMarker(_ kind: BlockKind) -> Bool {
            if case .heading = kind { return true }
            return kind == .paragraph
        }
        var placement = ListPlacement()
        if case .listItem = snapshot.kind {
            let first = snapshot.childIDs.first.flatMap { indexByID[$0] }
            placement.markerOnFirstChild = first.map { carriesMarker(blocks[$0].kind) } ?? false
        }
        guard let parentID = snapshot.parentID else { return placement }
        guard let parent = indexByID[parentID] else {
            // A closed parent can be evicted before its retained children.
            guard var retained = indexByID[snapshot.id].map({ blocks[$0].listPlacement }) else { return placement }
            retained.markerOnFirstChild = placement.markerOnFirstChild
            return retained
        }
        placement.barInset = blocks[parent].listPlacement.barInset
        if case .listItem = snapshot.kind { return placement }
        if let item = blocks[parent].listItem {
            // The parent's stored snapshot may not list a child that just started.
            let isFirst = (blocks[parent].snapshot.childIDs.first ?? snapshot.id) == snapshot.id
            placement.indent = item.textIndent
            placement.marker = isFirst && item.content.characters.isEmpty && carriesMarker(snapshot.kind) ? item.bullet : nil
        } else if blocks[parent].kind == .blockquote {
            // A quote inside a list item keeps its blocks at the item's
            // text column.
            placement.indent = blocks[parent].listPlacement.indent
        }
        if snapshot.kind == .blockquote { placement.barInset = placement.indent }
        return placement
    }

}

struct RenderedBlock: Sendable, Identifiable, Equatable {
    var id: BlockID
    var kind: BlockKind
    var content: AttributedString
    var snapshot: BlockSnapshot
    var table: RenderedTable?
    var listItem: RenderedListItem?
    var blockquote: RenderedBlockquote?
    var math: RenderedMath?
    var images: [RenderedImage] = []
    var codeBlock: RenderedCodeBlock?
    var mermaidDiagram: RenderedMermaidDiagram?
    /// Enclosing quote depth (0 outside any quote); drives the bars and
    /// indent children of a quote are drawn with.
    var blockquoteLevel: Int = 0
    /// Its place in an enclosing list item, kept for when the item is
    /// evicted before it.
    var listPlacement = ListPlacement()
}

struct ListPlacement: Sendable, Equatable {
    var indent: CGFloat = 0
    var marker: String?
    var markerOnFirstChild = false
    /// Leading inset of the bars of the quotes around the block: the column
    /// the innermost of them starts at.
    var barInset: CGFloat = 0
}

extension RenderedBlock {
    /// Replaces everything derived from rendering; id, kind and snapshot
    /// stay.
    mutating func updatePresentation(from rendered: RenderedContentResult) {
        content = rendered.attributed
        table = rendered.table
        listItem = rendered.listItem
        blockquote = rendered.blockquote
        math = rendered.math
        images = rendered.images
        codeBlock = rendered.codeBlock
        mermaidDiagram = rendered.mermaidDiagram
    }

    static func == (lhs: RenderedBlock, rhs: RenderedBlock) -> Bool {
        lhs.id == rhs.id &&
        lhs.kind == rhs.kind &&
        lhs.content == rhs.content &&
        lhs.snapshot == rhs.snapshot &&
        lhs.table == rhs.table &&
        lhs.listItem == rhs.listItem &&
        lhs.blockquote == rhs.blockquote &&
        lhs.math == rhs.math &&
        lhs.images == rhs.images &&
        lhs.codeBlock == rhs.codeBlock &&
        lhs.mermaidDiagram == rhs.mermaidDiagram
    }
}

struct RenderedTable: Sendable, Equatable {
    var headers: [AttributedString]?
    var rows: [[AttributedString]]
    var alignments: [TableAlignment]?
}

struct RenderedListItem: Sendable, Equatable {
    var bullet: String
    var content: AttributedString
    var ordered: Bool
    var index: Int?
    var task: TaskListState?
    /// The column the item's text, and each of its child blocks, starts at.
    var textIndent: CGFloat = 0
}

struct RenderedBlockquote: Sendable, Equatable {
    var content: AttributedString
}

struct RenderedMath: Sendable, Equatable {
    var tex: String
    var display: Bool
    var fontSize: CGFloat
}

struct RenderedCodeBlock: Sendable, Equatable {
    var code: String
    var language: String?
}

struct RenderedMermaidDiagram: Sendable, Equatable {
    var source: String
    var size: CGSize
    var diagnostics: String?
}
