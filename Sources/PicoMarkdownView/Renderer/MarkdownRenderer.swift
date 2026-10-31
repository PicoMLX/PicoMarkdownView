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
    /// Render completed `svg` fences as hosted vectors on macOS. UIKit keeps code rendering.
    public let svgRenderingEnabled: Bool
    /// Render completed `openui` fences as interactive hosted content on macOS.
    public let openUIRenderingEnabled: Bool
    /// Renders closed `vega-lite` fences as native vector charts on macOS.
    public let vegaLiteRenderingEnabled: Bool

    public init(bodyFont: FontSpec,
                codeFont: FontSpec,
                blockquoteColor: ThemeColor,
                linkColor: ThemeColor,
                headingFonts: [Int: FontSpec],
                imageMaxWidth: CGFloat? = nil,
                codeBlockTheme: CodeBlockTheme? = nil,
                codeHighlighter: AnyCodeSyntaxHighlighter? = nil,
                mermaidRenderingMode: MermaidRenderingMode = .onFenceClose,
                svgRenderingEnabled: Bool = false,
                openUIRenderingEnabled: Bool = false,
                vegaLiteRenderingEnabled: Bool = true) {
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.blockquoteColor = blockquoteColor
        self.linkColor = linkColor
        self.headingFonts = headingFonts
        self.imageMaxWidth = imageMaxWidth
        self.codeBlockTheme = codeBlockTheme
        self.codeHighlighter = codeHighlighter
        self.mermaidRenderingMode = mermaidRenderingMode
        self.svgRenderingEnabled = svgRenderingEnabled
        self.openUIRenderingEnabled = openUIRenderingEnabled
        self.vegaLiteRenderingEnabled = vegaLiteRenderingEnabled
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
                            mermaidRenderingMode: mermaidRenderingMode,
                            svgRenderingEnabled: svgRenderingEnabled,
                            openUIRenderingEnabled: openUIRenderingEnabled,
                            vegaLiteRenderingEnabled: vegaLiteRenderingEnabled)
    }

    /// Returns a copy that enables or disables native Vega-Lite charts on macOS.
    /// Open chart fences use a delayed loading row; compilation starts only
    /// when the fence closes. Unsupported final sources remain native code.
    public func withVegaLiteRendering(_ enabled: Bool) -> MarkdownRenderTheme {
        MarkdownRenderTheme(bodyFont: bodyFont,
                            codeFont: codeFont,
                            blockquoteColor: blockquoteColor,
                            linkColor: linkColor,
                            headingFonts: headingFonts,
                            imageMaxWidth: imageMaxWidth,
                            codeBlockTheme: codeBlockTheme,
                            codeHighlighter: codeHighlighter,
                            mermaidRenderingMode: mermaidRenderingMode,
                            svgRenderingEnabled: svgRenderingEnabled,
                            openUIRenderingEnabled: openUIRenderingEnabled,
                            vegaLiteRenderingEnabled: enabled)
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
                                   mermaidRenderingMode: mermaidRenderingMode,
                                   svgRenderingEnabled: svgRenderingEnabled,
                                   openUIRenderingEnabled: openUIRenderingEnabled,
                                   vegaLiteRenderingEnabled: vegaLiteRenderingEnabled)
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
    private let mermaidPreviewTiming: MermaidPreviewTiming
    private var blocks: [RenderedBlock] = []
    private var indexByID: [BlockID: Int] = [:]
#if canImport(AppKit)
    /// Links to preceding blocks let empty containers be skipped locally,
    /// without rescanning a message's rendered prefix on every chunk.
    private var previousBlockIDs: [BlockID: BlockID] = [:]
    private var trailingParagraphSpacings: [BlockID: CGFloat] = [:]
    private var visibleQuoteBodies: Set<BlockID> = []
#endif
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
         mermaidPreviewTiming: MermaidPreviewTiming = .continuous,
         snapshotProvider: @escaping SnapshotProvider) {
        self.theme = theme
        self.imageProvider = imageProvider
        self.injectedMermaidProvider = mermaidProvider
        self.mermaidPreviewTiming = mermaidPreviewTiming
        let resolvedMermaidProvider = mermaidProvider ?? MermaidDiagramProviders.makeDefaultProvider(theme: theme)
        self.attributeBuilder = MarkdownAttributeBuilder(theme: theme,
                                                         imageProvider: imageProvider,
                                                         mermaidProvider: resolvedMermaidProvider,
                                                         mermaidPreviewTiming: mermaidPreviewTiming)
        self.snapshotProvider = snapshotProvider
    }

    /// Re-renders every block with the theme's fonts scaled by `scale`. The
    /// parse is untouched: block ids, order and snapshots stay as they are.
    /// Returns the re-rendered blocks, or `nil` when the scale is unchanged.
    func updateTextScale(_ scale: CGFloat, codeBlockScale: CGFloat? = nil) async -> [RenderedBlock]? {
#if os(macOS)
        guard !Task.isCancelled else { return nil }
        // Provider cancellation means "retain code" during stream consumption.
        // A bounded presentation refresh must instead finish once accepted.
        return await Task.immediate {
            await self.updateTextScaleToCompletion(scale, codeBlockScale: codeBlockScale)
        }.value
#else
        return await updateTextScaleToCompletion(scale, codeBlockScale: codeBlockScale)
#endif
    }

    private func updateTextScaleToCompletion(_ scale: CGFloat, codeBlockScale: CGFloat?) async -> [RenderedBlock]? {
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
            runtimeMermaidMaxWidth: runtimeMermaidContentWidth,
            mermaidPreviewTiming: mermaidPreviewTiming)
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
#if canImport(AppKit)
                    cacheSpacing(for: snapshot, after: rendered.paragraphSpacingAfter)
#endif
                    break
                }
            }
        }
        return blocks
    }

    /// Renders with the current builder, again if the builder changed while
    /// an image or diagram was awaited, so old fonts never land.
    private func render(snapshot: BlockSnapshot, previousBlockKind: BlockKind?, blockquoteLevel: Int,
                        placement: ListPlacement, precedingBlockID: BlockID? = nil) async -> RenderedContentResult {
        while true {
            let generation = builderGeneration
#if canImport(AppKit)
            let previous = previousVisibleBlock(for: snapshot, placement: placement, precedingBlockID: precedingBlockID)
            let effectivePreviousKind = previous?.kind
            let spacing = spacingContext(for: snapshot, placement: placement, previous: previous)
#else
            let effectivePreviousKind = previousBlockKind
            let spacing: BlockSpacingContext? = nil
#endif
            let rendered = await attributeBuilder.render(snapshot: snapshot, previousBlockKind: effectivePreviousKind,
                                                         blockquoteLevel: blockquoteLevel,
                                                         listIndent: placement.indent,
                                                         listMarker: placement.marker,
                                                         markerOnFirstChild: placement.markerOnFirstChild,
                                                         blockquoteBarInset: placement.barInset,
                                                         spacingContext: spacing)
            if generation == builderGeneration {
#if canImport(AppKit)
                // A preceding block can be refreshed or retained away while
                // this block waits for an image, without changing this snapshot.
                let currentPrevious = previousVisibleBlock(for: snapshot, placement: placement,
                                                            precedingBlockID: precedingBlockID)
                let currentSpacing = spacingContext(for: snapshot, placement: placement, previous: currentPrevious)
                guard currentPrevious?.kind == effectivePreviousKind, currentSpacing == spacing else { continue }
#endif
                return rendered
            }
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
        guard !diff.changes.isEmpty || !diff.relinkedBlocks.isEmpty else { return false }

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
#if canImport(AppKit)
                let firstDiscarded = max(0, min(range.lowerBound, blocks.count))
                let endDiscarded = max(firstDiscarded, min(range.upperBound, blocks.count))
                let discardedIDs = Set(blocks[firstDiscarded..<endDiscarded].map(\.id))
#endif
                removeBlocks(in: range)
#if canImport(AppKit)
                await attributeBuilder.discardMermaidPreviews(for: discardedIDs)
                // Repair the local container links, then refresh only the
                // first visible successor (or first retained visible block).
                if let successor = relinkVisibleSuccessor(startingAt: max(0, range.lowerBound)) {
                    _ = await refreshBlock(id: successor)
                }
#endif
                mutated = true
            }
        }
        // References whose definition arrived link now; the text and so the
        // layout are as before, only the link attributes are new.
        for id in diff.relinkedBlocks where indexByID[id] != nil {
            mutated = await refreshBlock(id: id) || mutated
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

#if os(macOS)
    func openMermaidBlockIDs(in ids: Set<BlockID>) -> Set<BlockID> {
        Set(ids.filter { id in
            guard let index = indexByID[id], !blocks[index].snapshot.isClosed,
                  case .fencedCode(let language) = blocks[index].kind else { return false }
            return ["mermaid", "mmd", "mermaidjs"].contains(language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
        })
    }
#endif

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
#if os(macOS)
        guard !Task.isCancelled else { return nil }
        return await Task.immediate {
            await self.updateContentWidthToCompletion(width)
        }.value
#else
        return await updateContentWidthToCompletion(width)
#endif
    }

    private func updateContentWidthToCompletion(_ width: CGFloat?) async -> [RenderedBlock]? {
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
#if canImport(AppKit)
        let precedingID = position > 0 && position <= blocks.count ? blocks[position - 1].id : nil
#else
        let precedingID: BlockID? = nil
#endif
        let previousKind = previousBlockKind(at: position)
        let prepared = await buildRenderedBlock(id: id, snapshot: snapshot, previousBlockKind: previousKind,
                                                precedingBlockID: precedingID)
#if canImport(AppKit)
        guard indexByID[id] == nil else { return }
#endif
        let index = max(0, min(position, blocks.count))

        blocks.insert(prepared.block, at: index)
        rebuildIndex(startingAt: index)
#if canImport(AppKit)
        previousBlockIDs[id] = index > 0 ? blocks[index - 1].id : nil
        cacheSpacing(for: snapshot, after: prepared.paragraphSpacingAfter)
        if let successor = relinkVisibleSuccessor(startingAt: index + 1) {
            _ = await refreshBlock(id: successor)
        }
#endif
    }

    private func refreshBlock(id: BlockID) async -> Bool {
        while true {
            guard let initialIndex = indexByID[id] else { return false }
#if canImport(AppKit)
            let previousSnapshot = blocks[initialIndex].snapshot
#endif
            let snapshot = await snapshotProvider(id)
#if canImport(AppKit)
            guard let renderIndex = indexByID[id] else { return false }
            guard blocks[renderIndex].snapshot == previousSnapshot || blocks[renderIndex].snapshot == snapshot else { continue }
#else
            let renderIndex = initialIndex
#endif
            let previousKind = previousBlockKind(at: renderIndex)
            let quoteLevel = blockquoteLevel(for: snapshot)
            let placement = listPlacement(for: snapshot)
            let rendered = await render(snapshot: snapshot, previousBlockKind: previousKind, blockquoteLevel: quoteLevel,
                                        placement: placement)
#if canImport(AppKit)
            guard let acceptedIndex = indexByID[id] else { return false }
            guard blocks[acceptedIndex].snapshot == previousSnapshot || blocks[acceptedIndex].snapshot == snapshot else { continue }
#else
            let acceptedIndex = renderIndex
#endif
            let oldContent = blocks[acceptedIndex].content
            let newContent = rendered.attributed

#if canImport(AppKit)
            let didMutate = oldContent != newContent || blocks[acceptedIndex].table != rendered.table
                || blocks[acceptedIndex].mermaidDiagram != rendered.mermaidDiagram
                || blocks[acceptedIndex].svgGraphic != rendered.svgGraphic
                || blocks[acceptedIndex].openUI != rendered.openUI
                || blocks[acceptedIndex].vegaLiteChart != rendered.vegaLiteChart
#else
            let didMutate = oldContent != newContent
#endif
            blocks[acceptedIndex].kind = snapshot.kind
            blocks[acceptedIndex].snapshot = snapshot
            blocks[acceptedIndex].blockquoteLevel = quoteLevel
            blocks[acceptedIndex].listPlacement = placement
            blocks[acceptedIndex].updatePresentation(from: rendered)
#if canImport(AppKit)
            cacheSpacing(for: snapshot, after: rendered.paragraphSpacingAfter)
#endif
            return didMutate
        }
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
#if canImport(AppKit)
            previousBlockIDs[block.id] = nil
            trailingParagraphSpacings[block.id] = nil
            visibleQuoteBodies.remove(block.id)
#endif
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

#if canImport(AppKit)
    private func relinkVisibleSuccessor(startingAt start: Int) -> BlockID? {
        var index = start
        var previous = start > 0 && start <= blocks.count ? blocks[start - 1].id : nil
        // An invisible quote/item contributes no margin. Walk only the local
        // chain of container nodes before the following rendered block.
        while index < blocks.count {
            previousBlockIDs[blocks[index].id] = previous
            if !blocks[index].content.characters.isEmpty { return blocks[index].id }
            previous = blocks[index].id
            index += 1
        }
        return nil
    }

    private func previousVisibleBlock(for snapshot: BlockSnapshot, placement: ListPlacement,
                                      precedingBlockID: BlockID?) -> RenderedBlock? {
        var candidate = precedingBlockID ?? previousBlockIDs[snapshot.id]
        var skipped: [BlockID] = []
        while let id = candidate, let index = indexByID[id] {
            let block = blocks[index]
            // A first child's marker is transferred from an empty item when
            // that child starts; the parent refresh follows this render.
            let handingOffMarker = id == snapshot.parentID && placement.marker != nil
            let emptyQuoteParent = id == snapshot.parentID && block.kind == .blockquote
                && !visibleQuoteBodies.contains(id)
            if !block.content.characters.isEmpty && !handingOffMarker && !emptyQuoteParent {
                for skippedID in skipped { previousBlockIDs[skippedID] = id }
                return block
            }
            skipped.append(id)
            candidate = previousBlockIDs[id]
        }
        for skippedID in skipped { previousBlockIDs[skippedID] = nil }
        return nil
    }

    private func cacheSpacing(for snapshot: BlockSnapshot, after: CGFloat?) {
        trailingParagraphSpacings[snapshot.id] = after
        let hasQuoteBody = snapshot.kind == .blockquote && (snapshot.inlineRuns ?? []).contains { run in
            run.image != nil || run.math != nil || !run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasQuoteBody { visibleQuoteBodies.insert(snapshot.id) }
        else { visibleQuoteBodies.remove(snapshot.id) }
    }

    private func spacingContext(for snapshot: BlockSnapshot, placement: ListPlacement,
                                previous: RenderedBlock?) -> BlockSpacingContext {
        let gap: BlockSpacingContext.Gap
        switch snapshot.kind {
        case .paragraph, .blockquote:
            if placement.marker != nil {
                let itemParent = snapshot.parentID.flatMap { indexByID[$0] }.flatMap { blocks[$0].snapshot.parentID }
                gap = itemParent == previous?.id ? .none : .listItem
            } else {
                gap = .paragraph
            }
        case .listItem(let ordered, _, _):
            if previous?.id == snapshot.parentID {
                gap = .none
            } else if let previous, case .listItem = previous.kind,
                      isSameList(as: snapshot, ordered: ordered, previous: previous) {
                gap = .listItem
            } else {
                gap = .paragraph
            }
        default:
            gap = .standard
        }
        let previousAfter = previous.flatMap { trailingParagraphSpacings[$0.id] }
        let suppressTrailing: Bool
        if case .listItem = snapshot.kind,
           let firstChild = snapshot.childIDs.first.flatMap({ indexByID[$0] }),
           case .listItem = blocks[firstChild].kind {
            suppressTrailing = true
        } else {
            suppressTrailing = false
        }
        return BlockSpacingContext(previousSpacingAfter: previousAfter, gap: gap,
                                   suppressTrailingListSpacing: suppressTrailing)
    }

    private func isSameList(as snapshot: BlockSnapshot, ordered: Bool, previous: RenderedBlock) -> Bool {
        var candidate: RenderedBlock? = previous
        while let block = candidate {
            if case .listItem(let previousOrdered, _, _) = block.kind,
               block.snapshot.parentID == snapshot.parentID, block.snapshot.depth == snapshot.depth {
                return previousOrdered == ordered
            }
            candidate = block.snapshot.parentID.flatMap { indexByID[$0] }.map { blocks[$0] }
        }
        return false
    }
#endif

    private func shouldRefreshForContentWidthChange(_ block: RenderedBlock) -> Bool {
        if !block.images.isEmpty {
            return true
        }
#if os(macOS)
        if theme.vegaLiteRenderingEnabled {
            if block.vegaLiteChart != nil { return true }
            if block.snapshot.isClosed, case let .fencedCode(language) = block.kind,
               isVegaLiteLanguage(language) { return true }
        }
#endif
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

    private func buildRenderedBlock(id: BlockID, snapshot: BlockSnapshot, previousBlockKind: BlockKind? = nil,
                                    precedingBlockID: BlockID? = nil) async -> (block: RenderedBlock, paragraphSpacingAfter: CGFloat?) {
        let quoteLevel = blockquoteLevel(for: snapshot)
        let placement = listPlacement(for: snapshot)
        let rendered = await render(snapshot: snapshot, previousBlockKind: previousBlockKind, blockquoteLevel: quoteLevel,
                                    placement: placement, precedingBlockID: precedingBlockID)
        let block = RenderedBlock(id: id,
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
                             svgGraphic: rendered.svgGraphic,
                             vegaLiteChart: rendered.vegaLiteChart,
                             openUI: rendered.openUI,
                             blockquoteLevel: quoteLevel,
                             listPlacement: placement)
        return (block, rendered.paragraphSpacingAfter)
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
    /// when it is a paragraph, heading or supported macOS hosted fence. The item then
    /// renders nothing.
    /// A quote's bars start at the column the quote starts at, and stay
    /// there for every block inside it.
    private func listPlacement(for snapshot: BlockSnapshot) -> ListPlacement {
        func carriesMarker(_ kind: BlockKind) -> Bool {
            if case .heading = kind { return true }
#if os(macOS)
            if case .fencedCode(let language) = kind {
                if theme.openUIRenderingEnabled,
                   language?.split(whereSeparator: \.isWhitespace).first?.lowercased() == "openui" { return true }
                if theme.svgRenderingEnabled, SVGDiagramSupport.isSVGLanguage(language) { return true }
                if theme.vegaLiteRenderingEnabled, isVegaLiteLanguage(language) { return true }
                if theme.mermaidRenderingMode.isEnabled { return isMermaidLanguage(language) }
            }
#endif
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
    var svgGraphic: RenderedSVGGraphic? = nil
    var vegaLiteChart: RenderedVegaLiteChart? = nil
    var openUI: RenderedOpenUIContent? = nil
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
        svgGraphic = rendered.svgGraphic
        vegaLiteChart = rendered.vegaLiteChart
        openUI = rendered.openUI
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
        lhs.svgGraphic == rhs.svgGraphic &&
        lhs.vegaLiteChart == rhs.vegaLiteChart &&
        lhs.openUI == rhs.openUI
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
    /// macOS replays the vector drawing in a hosted attachment. Bitmap-only
    /// providers and UIKit keep their existing image attachment path.
    var svg: String? = nil
    /// The effective renderer width also bounds the hosted viewport. Some
    /// diagrams keep a wider intrinsic SVG even when Pele receives this cap.
    var maxWidth: CGFloat? = nil
}

struct RenderedVegaLiteChart: Sendable, Equatable {
    var source: String
    var language: String?
    var svg: String
    var intrinsicSize: CGSize
    var maxWidth: CGFloat?
}

/// The whole fence info string must identify Vega-Lite; JSON and Vega stay code.
func isVegaLiteLanguage(_ language: String?) -> Bool {
    language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "vega-lite"
}
