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
}

actor MarkdownRenderer {
    typealias SnapshotProvider = @Sendable (BlockID) async -> BlockSnapshot

    private let theme: MarkdownRenderTheme
    private let attributeBuilder: MarkdownAttributeBuilder
    private let snapshotProvider: SnapshotProvider
    private var blocks: [RenderedBlock] = []
    private var indexByID: [BlockID: Int] = [:]
    private var mermaidContentWidthBucket: Int?

    init(theme: MarkdownRenderTheme = .default(),
         imageProvider: MarkdownImageProvider? = nil,
         mermaidProvider: (any MermaidDiagramProvider)? = nil,
         snapshotProvider: @escaping SnapshotProvider) {
        self.theme = theme
        let resolvedMermaidProvider = mermaidProvider ?? MermaidDiagramProviders.makeDefaultProvider(theme: theme)
        self.attributeBuilder = MarkdownAttributeBuilder(theme: theme,
                                                         imageProvider: imageProvider,
                                                         mermaidProvider: resolvedMermaidProvider)
        self.snapshotProvider = snapshotProvider
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

        await attributeBuilder.setRuntimeMermaidMaxWidth(width)

        var mutated = false
        let candidateIDs = blocks.filter(shouldRefreshForContentWidthChange).map(\.id)
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
        let rendered = await attributeBuilder.render(snapshot: snapshot, previousBlockKind: previousKind)
        
        let oldContent = blocks[index].content
        let newContent = rendered.attributed

        let didMutate = oldContent != newContent

        blocks[index].kind = snapshot.kind
        blocks[index].snapshot = snapshot
        blocks[index].content = rendered.attributed
        blocks[index].table = rendered.table
        blocks[index].listItem = rendered.listItem
        blocks[index].blockquote = rendered.blockquote
        blocks[index].math = rendered.math
        blocks[index].images = rendered.images
        blocks[index].codeBlock = rendered.codeBlock
        blocks[index].mermaidDiagram = rendered.mermaidDiagram
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
        let rendered = await attributeBuilder.render(snapshot: snapshot, previousBlockKind: previousBlockKind)
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
                             mermaidDiagram: rendered.mermaidDiagram)
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
}

extension RenderedBlock {
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
