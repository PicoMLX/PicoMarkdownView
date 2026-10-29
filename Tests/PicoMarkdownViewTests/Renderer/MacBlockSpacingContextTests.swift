#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS spacing predecessor links")
struct MacBlockSpacingContextTests {
    @Test("Removing and inserting before empty containers repairs the visible successor's margin")
    func emptyContainerChainAfterRetentionAndInsertion() async throws {
        let font = FontSpec(size: 15)
        let theme = MarkdownRenderTheme(bodyFont: font, codeFont: font,
                                        blockquoteColor: .secondaryLabel, linkColor: .link,
                                        headingFonts: [:])
        let store = SpacingSnapshotStore()
        let renderer = MarkdownRenderer(theme: theme) { await store.snapshot(for: $0) }

        var item = BlockSnapshot(id: 1, kind: .listItem(ordered: false, index: nil, task: nil),
                                 inlineRuns: [InlineRun(text: "List opening.")], isClosed: false,
                                 childIDs: [2, 3])
        var intervening = BlockSnapshot(id: 2, kind: .paragraph,
                                        inlineRuns: [InlineRun(text: "Intervening paragraph.")],
                                        isClosed: false, parentID: 1, depth: 1)
        let outer = BlockSnapshot(id: 3, kind: .blockquote, isClosed: false,
                                  parentID: 1, depth: 1, childIDs: [4])
        let inner = BlockSnapshot(id: 4, kind: .blockquote, isClosed: false,
                                  parentID: 3, depth: 2, childIDs: [5])
        let leaf = BlockSnapshot(id: 5, kind: .paragraph,
                                 inlineRuns: [InlineRun(text: "Visible quoted paragraph.")],
                                 isClosed: false, parentID: 4, depth: 3)
        let initial = [item, intervening, outer, inner, leaf]
        for snapshot in initial { await store.set(snapshot) }
        _ = await renderer.apply(AssemblerDiff(documentVersion: 1, changes: initial.enumerated().map {
            .blockStarted(id: $0.element.id, kind: $0.element.kind, position: $0.offset)
        }))
        var rendered = await renderer.renderedBlocks()
        #expect(try spacing(of: 3, in: rendered) == nil, "the outer quote must be a non-rendering container")
        #expect(try spacing(of: 4, in: rendered) == nil, "the inner quote must be a non-rendering container")
        #expect(try #require(try spacing(of: 5, in: rendered)).paragraphSpacingBefore == 0,
                "the visible predecessor already contributes a full paragraph margin")

        // Close and discard only the intervening child: its enclosing item and
        // the two quote containers remain open, so this is a non-prefix drop.
        intervening.isClosed = true
        await store.set(intervening)
        _ = await renderer.apply(AssemblerDiff(documentVersion: 2, changes: [.blockEnded(id: 2)]))
        item.childIDs = [3]
        await store.set(item)
        await store.remove(2)
        _ = await renderer.apply(AssemblerDiff(documentVersion: 3,
                                                changes: [.blocksDiscarded(range: 1..<2)]))
        rendered = await renderer.renderedBlocks()
        #expect(rendered.map(\.id) == [1, 3, 4, 5])
        let itemMargin = try #require(try spacing(of: 1, in: rendered)).paragraphSpacing
        let retainedLeading = try #require(try spacing(of: 5, in: rendered)).paragraphSpacingBefore
        #expect(itemMargin == 3.75)
        #expect(retainedLeading == 11.25,
                "repair must cross both empty containers after their predecessor links were compressed")
        #expect(itemMargin + retainedLeading == 15)

        // A fresh visible block inserted before the same empty chain supplies
        // that margin itself, so the quoted leaf's added leading gap disappears.
        let inserted = BlockSnapshot(id: 6, kind: .paragraph,
                                     inlineRuns: [InlineRun(text: "New middle paragraph.")],
                                     isClosed: false, parentID: 1, depth: 1)
        item.childIDs = [6, 3]
        await store.set(item)
        await store.set(inserted)
        _ = await renderer.apply(AssemblerDiff(documentVersion: 4,
                                                changes: [.blockStarted(id: 6, kind: .paragraph, position: 1)]))
        rendered = await renderer.renderedBlocks()
        #expect(rendered.map(\.id) == [1, 6, 3, 4, 5])
        let insertedMargin = try #require(try spacing(of: 6, in: rendered)).paragraphSpacing
        let insertedLeading = try #require(try spacing(of: 5, in: rendered)).paragraphSpacingBefore
        #expect(insertedMargin == 15)
        #expect(insertedLeading == 0)
        #expect(insertedMargin + insertedLeading == 15)
        #expect(await store.missingRequests().isEmpty, "retention must not query evicted snapshots")
    }

    private func spacing(of id: BlockID, in blocks: [RenderedBlock]) throws -> NSParagraphStyle? {
        let block = try #require(blocks.first { $0.id == id })
        let content = NSAttributedString.picoConverted(from: block.content)
        guard content.length > 0 else { return nil }
        return content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    }
}

private actor SpacingSnapshotStore {
    private var snapshots: [BlockID: BlockSnapshot] = [:]
    private var missing: [BlockID] = []

    func set(_ snapshot: BlockSnapshot) { snapshots[snapshot.id] = snapshot }
    func remove(_ id: BlockID) { snapshots[id] = nil }
    func missingRequests() -> [BlockID] { missing }

    func snapshot(for id: BlockID) -> BlockSnapshot {
        if let snapshot = snapshots[id] { return snapshot }
        missing.append(id)
        return BlockSnapshot(id: id, kind: .unknown, isClosed: true)
    }
}
#endif
