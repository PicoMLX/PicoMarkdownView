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
        let bodySize = FontSpec.defaultBodyPointSize + 2

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

    /// Scales the theme's fonts, preserving colors, providers, and layout limits.
    public func scaled(by scale: CGFloat) -> MarkdownRenderTheme {
        let factor = scale.isFinite && scale > 0 ? scale : 1
        let scaledCodeTheme = codeBlockTheme.map { code in
            CodeBlockTheme(font: code.font.withSize(code.font.pointSize * factor),
                           foregroundColor: code.foregroundColor, backgroundColor: code.backgroundColor,
                           tokenColors: code.tokenColors)
        }
        return MarkdownRenderTheme(
            bodyFont: bodyFont.withSize(bodyFont.pointSize * factor),
            codeFont: codeFont.withSize(codeFont.pointSize * factor),
            blockquoteColor: blockquoteColor, linkColor: linkColor,
            headingFonts: headingFonts.mapValues { $0.withSize($0.pointSize * factor) },
            imageMaxWidth: imageMaxWidth, codeBlockTheme: scaledCodeTheme,
            codeHighlighter: codeHighlighter, mermaidRenderingMode: mermaidRenderingMode)
    }
}

actor MarkdownRenderer {
    typealias SnapshotProvider = @Sendable (BlockID) async -> BlockSnapshot

    private let theme: MarkdownRenderTheme
    private var attributeBuilder: MarkdownAttributeBuilder
    private let imageProvider: RetainedMarkdownImageProvider?
    private let mermaidProvider: (any MermaidDiagramProvider)?
    private var textScale: CGFloat = 1
    private var renderGeneration: UInt64 = 0
    private var runtimeMermaidContentWidth: CGFloat?
    private let snapshotProvider: SnapshotProvider
    private var blocks: [RenderedBlock] = []
    private var indexByID: [BlockID: Int] = [:]
    private var mermaidContentWidthBucket: Int?

    init(theme: MarkdownRenderTheme = .default(),
         imageProvider: MarkdownImageProvider? = nil,
         mermaidProvider: (any MermaidDiagramProvider)? = nil,
         snapshotProvider: @escaping SnapshotProvider) {
        self.theme = theme
        let retainedImageProvider = imageProvider.map { RetainedMarkdownImageProvider(provider: $0) }
        self.imageProvider = retainedImageProvider
        self.mermaidProvider = mermaidProvider
        let resolvedMermaidProvider = mermaidProvider ?? MermaidDiagramProviders.makeDefaultProvider(theme: theme)
        self.attributeBuilder = MarkdownAttributeBuilder(theme: theme,
                                                         imageProvider: retainedImageProvider,
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
                await removeBlocks(in: range)
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
        guard let prepared = await prepareContentWidth(width, shouldContinue: { true }),
              commitContentWidth(prepared), prepared.didMutate else { return nil }
        return prepared.blocks
    }

    struct PreparedContentWidthUpdate: Sendable {
        let width: CGFloat?
        let bucket: Int?
        let generation: UInt64
        let builder: MarkdownAttributeBuilder
        let blocks: [RenderedBlock]
        let didMutate: Bool
        let previousWidth: CGFloat?
        let previousBucket: Int?
        let previousBuilder: MarkdownAttributeBuilder
        let previousBlocks: [RenderedBlock]
    }

    func prepareContentWidth(_ width: CGFloat?,
                             shouldContinue: @Sendable () async -> Bool) async -> PreparedContentWidthUpdate? {
        let bucket = mermaidWidthBucket(for: effectiveMermaidContentWidth(for: width))
        guard bucket != mermaidContentWidthBucket, await shouldContinue() else { return nil }
        let generation = renderGeneration
        let previousWidth = runtimeMermaidContentWidth
        let previousBucket = mermaidContentWidthBucket
        let previousBuilder = attributeBuilder
        let previousBlocks = blocks
        let builder = await previousBuilder.copyForContentWidth(width)
        var staged = previousBlocks
        var mutated = false
        for index in staged.indices where shouldRefreshForContentWidthChange(previousBlocks[index]) {
            guard await shouldContinue(), generation == renderGeneration else { return nil }
            let block = previousBlocks[index]
            let result = await builder.render(snapshot: block.snapshot,
                previousBlockKind: index > 0 ? previousBlocks[index - 1].kind : nil,
                blockquoteLevel: block.blockquoteLevel)
            guard await shouldContinue(), generation == renderGeneration else { return nil }
            mutated = mutated || block.content != result.attributed
            staged[index].updatePresentation(from: result)
        }
        guard await shouldContinue(), generation == renderGeneration else { return nil }
        return PreparedContentWidthUpdate(width: width, bucket: bucket, generation: generation,
            builder: builder, blocks: staged, didMutate: mutated, previousWidth: previousWidth,
            previousBucket: previousBucket, previousBuilder: previousBuilder, previousBlocks: previousBlocks)
    }

    func commitContentWidth(_ prepared: PreparedContentWidthUpdate) -> Bool {
        guard prepared.generation == renderGeneration else { return false }
        runtimeMermaidContentWidth = prepared.width
        mermaidContentWidthBucket = prepared.bucket
        attributeBuilder = prepared.builder
        blocks = prepared.blocks
        renderGeneration &+= 1
        return true
    }

    func rollbackContentWidth(_ prepared: PreparedContentWidthUpdate) {
        guard renderGeneration == prepared.generation &+ 1 else { return }
        runtimeMermaidContentWidth = prepared.previousWidth
        mermaidContentWidthBucket = prepared.previousBucket
        attributeBuilder = prepared.previousBuilder
        blocks = prepared.previousBlocks
        renderGeneration &+= 1
    }

    /// Font changes require fresh presentation for each block, not a new parse.
    func updateTextScale(_ scale: CGFloat) async -> [BlockID] {
        guard let prepared = await prepareTextScale(scale, shouldContinue: { true }) else { return [] }
        return commitTextScale(prepared)
    }

    struct PreparedTextScaleUpdate: Sendable {
        let scale: CGFloat
        let generation: UInt64
        let builder: MarkdownAttributeBuilder
        let blocks: [RenderedBlock]
        let previousScale: CGFloat
        let previousBuilder: MarkdownAttributeBuilder
        let previousBlocks: [RenderedBlock]
    }

    // The pipeline holds its operation gate until this transaction is either
    // published or abandoned; streaming edits cannot interleave with staging.
    func prepareTextScale(_ scale: CGFloat,
                          shouldContinue: @Sendable () async -> Bool) async -> PreparedTextScaleUpdate? {
        let factor = scale.isFinite && scale > 0 ? scale : 1
        guard factor != textScale, await shouldContinue() else { return nil }
        let generation = renderGeneration
        let previousScale = textScale
        let previousBuilder = attributeBuilder
        let previousBlocks = blocks
        let scaledTheme = theme.scaled(by: factor)
        let builder = MarkdownAttributeBuilder(
            theme: scaledTheme, imageProvider: imageProvider,
            mermaidProvider: mermaidProvider ?? MermaidDiagramProviders.makeDefaultProvider(theme: scaledTheme))
        await builder.setRuntimeMermaidMaxWidth(runtimeMermaidContentWidth)
        var staged = previousBlocks
        for index in staged.indices {
            guard await shouldContinue(), generation == renderGeneration else { return nil }
            let block = previousBlocks[index]
            let result = await builder.render(snapshot: block.snapshot,
                previousBlockKind: index > 0 ? previousBlocks[index - 1].kind : nil,
                blockquoteLevel: block.blockquoteLevel)
            guard await shouldContinue(), generation == renderGeneration else { return nil }
            staged[index].updatePresentation(from: result)
        }
        guard await shouldContinue(), generation == renderGeneration else { return nil }
        return PreparedTextScaleUpdate(scale: factor, generation: generation, builder: builder, blocks: staged,
            previousScale: previousScale, previousBuilder: previousBuilder, previousBlocks: previousBlocks)
    }

    func commitTextScale(_ prepared: PreparedTextScaleUpdate) -> [BlockID] {
        guard prepared.generation == renderGeneration else { return [] }
        textScale = prepared.scale
        attributeBuilder = prepared.builder
        blocks = prepared.blocks
        renderGeneration &+= 1
        return blocks.map(\.id)
    }

    func rollbackTextScale(_ prepared: PreparedTextScaleUpdate) {
        guard renderGeneration == prepared.generation &+ 1 else { return }
        textScale = prepared.previousScale
        attributeBuilder = prepared.previousBuilder
        blocks = prepared.previousBlocks
        renderGeneration &+= 1
    }

    private func render(snapshot: BlockSnapshot, previousBlockKind: BlockKind?,
                        blockquoteLevel: Int) async -> RenderedContentResult {
        // An image/math await may overlap a scale change. Do not commit an
        // obsolete builder's fonts after the new presentation has been applied.
        while true {
            let generation = renderGeneration
            let result = await attributeBuilder.render(snapshot: snapshot, previousBlockKind: previousBlockKind,
                                                       blockquoteLevel: blockquoteLevel)
            if generation == renderGeneration { return result }
        }
    }

    private func insertBlock(id: BlockID, at position: Int) async {
        guard indexByID[id] == nil else { return }
        let snapshot = await snapshotProvider(id)
        let previousKind = previousBlockKind(at: position)
        let block = await buildRenderedBlock(id: id, snapshot: snapshot, previousBlockKind: previousKind)
        let index = max(0, min(position, blocks.count))

        blocks.insert(block, at: index)
        rebuildIndex(startingAt: index)
        await updateImageReferences(for: block)
    }

    private func refreshBlock(id: BlockID) async -> Bool {
        guard let index = indexByID[id] else { return false }
        let snapshot = await snapshotProvider(id)
        let previousKind = previousBlockKind(at: index)
        let quoteLevel = blockquoteLevel(for: snapshot)
        let rendered = await render(snapshot: snapshot, previousBlockKind: previousKind, blockquoteLevel: quoteLevel)
        
        let oldContent = blocks[index].content
        let newContent = rendered.attributed

        let didMutate = oldContent != newContent

        blocks[index].kind = snapshot.kind
        blocks[index].snapshot = snapshot
        blocks[index].blockquoteLevel = quoteLevel
        blocks[index].updatePresentation(from: rendered)
        await updateImageReferences(for: blocks[index])
        return didMutate
    }

    private func updateImageReferences(for block: RenderedBlock) async {
        guard let imageProvider else { return }
        await imageProvider.setReferences(Set(block.images.compactMap(\.url)), for: block.id)
    }

    private func removeBlocks(in range: Range<Int>) async {
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
        if let imageProvider {
            await imageProvider.removeReferences(for: removed.map(\.id))
        }
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
        if block.math != nil || block.snapshot.inlineRuns?.contains(where: { $0.math != nil }) == true ||
           block.snapshot.table?.headerCells?.contains(where: { $0.contains(where: { $0.math != nil }) }) == true ||
           block.snapshot.table?.rows.contains(where: { $0.contains(where: { $0.contains(where: { $0.math != nil }) }) }) == true {
            return true
        }
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
        let rendered = await render(snapshot: snapshot, previousBlockKind: previousBlockKind, blockquoteLevel: quoteLevel)
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
                             blockquoteLevel: quoteLevel)
    }

    private func blockquoteLevel(for snapshot: BlockSnapshot) -> Int {
        if let parent = snapshot.parentID, indexByID[parent] == nil,
           let retained = indexByID[snapshot.id] {
            // Closed parents can be evicted before their retained children.
            return blocks[retained].blockquoteLevel
        }
        let inherited = snapshot.parentID.flatMap { indexByID[$0] }.map { blocks[$0].blockquoteLevel } ?? 0
        return inherited + (snapshot.kind == .blockquote ? 1 : 0)
    }
    
}

// Keep successful results while their blocks survive. The shared provider's
// bounded cache may evict them between presentation-only refreshes.
private actor RetainedMarkdownImageProvider: MarkdownImageProvider {
    private let provider: any MarkdownImageProvider
    private var images: [URL: MarkdownImageResult] = [:]
    private var urlsByBlock: [BlockID: Set<URL>] = [:]
    private var referenceCounts: [URL: Int] = [:]

    init(provider: any MarkdownImageProvider) { self.provider = provider }

    func image(for url: URL) async -> MarkdownImageResult? {
        if let result = await provider.image(for: url) {
            images[url] = result
            return result
        }
        return images[url]
    }

    func setReferences(_ urls: Set<URL>, for id: BlockID) {
        let previous = urlsByBlock[id] ?? []
        guard previous != urls else { return }
        for url in previous where !urls.contains(url) { releaseReference(to: url) }
        for url in urls where !previous.contains(url) { referenceCounts[url, default: 0] += 1 }
        if urls.isEmpty {
            urlsByBlock[id] = nil
        } else {
            urlsByBlock[id] = urls
        }
    }

    func removeReferences(for ids: [BlockID]) {
        for id in ids {
            guard let urls = urlsByBlock.removeValue(forKey: id) else { continue }
            for url in urls { releaseReference(to: url) }
        }
    }

    private func releaseReference(to url: URL) {
        guard let count = referenceCounts[url] else { return }
        if count > 1 {
            referenceCounts[url] = count - 1
        } else {
            referenceCounts[url] = nil
            images[url] = nil
        }
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
    var blockquoteLevel: Int = 0
}

extension RenderedBlock {
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
        lhs.mermaidDiagram == rhs.mermaidDiagram &&
        lhs.blockquoteLevel == rhs.blockquoteLevel
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
