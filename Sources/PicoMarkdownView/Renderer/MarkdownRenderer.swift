import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct MarkdownRenderTheme: @unchecked Sendable {
    public var bodyFont: MarkdownFont
    public var codeFont: MarkdownFont
    public var blockquoteColor: MarkdownColor
    public var linkColor: MarkdownColor
    public var headingFonts: [Int: MarkdownFont]

    public init(bodyFont: MarkdownFont,
                codeFont: MarkdownFont,
                blockquoteColor: MarkdownColor,
                linkColor: MarkdownColor,
                headingFonts: [Int: MarkdownFont]) {
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.blockquoteColor = blockquoteColor
        self.linkColor = linkColor
        self.headingFonts = headingFonts
    }

    public static func `default`() -> MarkdownRenderTheme {
#if canImport(UIKit)
        let body = UIFont.preferredFont(forTextStyle: .body)
        let code = UIFont.monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
        let blockquote = UIColor.secondaryLabel
        let link = UIColor.systemBlue
        var headings: [Int: UIFont] = [:]
        headings[1] = UIFont.systemFont(ofSize: body.pointSize * 1.6, weight: .bold)
        headings[2] = UIFont.systemFont(ofSize: body.pointSize * 1.4, weight: .bold)
        headings[3] = UIFont.systemFont(ofSize: body.pointSize * 1.2, weight: .semibold)
        headings[4] = UIFont.systemFont(ofSize: body.pointSize * 1.1, weight: .semibold)
        headings[5] = UIFont.systemFont(ofSize: body.pointSize, weight: .semibold)
        headings[6] = UIFont.systemFont(ofSize: body.pointSize, weight: .regular)
#else
        let body = NSFont.preferredFont(forTextStyle: .body)
        let code = NSFont.monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
        let blockquote = NSColor.secondaryLabelColor
        let link = NSColor.systemBlue
        var headings: [Int: NSFont] = [:]
        headings[1] = NSFont.systemFont(ofSize: body.pointSize * 1.6, weight: .bold)
        headings[2] = NSFont.systemFont(ofSize: body.pointSize * 1.4, weight: .bold)
        headings[3] = NSFont.systemFont(ofSize: body.pointSize * 1.2, weight: .semibold)
        headings[4] = NSFont.systemFont(ofSize: body.pointSize * 1.1, weight: .semibold)
        headings[5] = NSFont.systemFont(ofSize: body.pointSize, weight: .semibold)
        headings[6] = NSFont.systemFont(ofSize: body.pointSize, weight: .regular)
#endif
        return MarkdownRenderTheme(bodyFont: body,
                                   codeFont: code,
                                   blockquoteColor: blockquote,
                                   linkColor: link,
                                   headingFonts: headings)
    }
}

actor MarkdownRenderer {
    typealias SnapshotProvider = @Sendable (BlockID) async -> BlockSnapshot

    private let theme: MarkdownRenderTheme
    private let attributeBuilder: MarkdownAttributeBuilder
    private let snapshotProvider: SnapshotProvider
    private var blocks: [RenderedBlock] = []
    private var indexByID: [BlockID: Int] = [:]

    init(theme: MarkdownRenderTheme = .default(), snapshotProvider: @escaping SnapshotProvider) {
        self.theme = theme
        self.attributeBuilder = MarkdownAttributeBuilder(theme: theme)
        self.snapshotProvider = snapshotProvider
    }

    @discardableResult
    func apply(_ diff: AssemblerDiff) async -> AttributedString? {
        guard !diff.changes.isEmpty else { return nil }

        var mutated = false

        for change in diff.changes {
            switch change {
            case .blockStarted(let id, _, let position):
                await insertBlock(id: id, at: position)
                mutated = true
            case .runsAppended(let id, _),
                 .codeAppended(let id, _),
                 .tableHeaderConfirmed(let id),
                 .tableRowAppended(let id, _),
                 .blockEnded(let id):
                await refreshBlock(id: id)
                mutated = true
            case .blocksDiscarded(let range):
                removeBlocks(in: range)
                mutated = true
            }
        }

        return mutated ? makeSnapshot() : nil
    }

    func currentAttributedString() -> AttributedString {
        makeSnapshot()
    }

    func renderedBlocks() -> [RenderedBlock] {
        blocks
    }

    private func makeSnapshot() -> AttributedString {
        guard !blocks.isEmpty else { return AttributedString() }
        var result = AttributedString()
        for block in blocks {
            result.append(block.content)
        }
        return result
    }

    private func insertBlock(id: BlockID, at position: Int) async {
        guard indexByID[id] == nil else { return }
        let snapshot = await snapshotProvider(id)
        let block = await buildRenderedBlock(id: id, snapshot: snapshot)
        let index = max(0, min(position, blocks.count))
        blocks.insert(block, at: index)
        rebuildIndex(startingAt: index)
    }

    private func refreshBlock(id: BlockID) async {
        guard let index = indexByID[id] else { return }
        let snapshot = await snapshotProvider(id)
        let rendered = await attributeBuilder.render(snapshot: snapshot)
        blocks[index].kind = snapshot.kind
        blocks[index].snapshot = snapshot
        blocks[index].content = rendered.attributed
        blocks[index].table = rendered.table
        blocks[index].listItem = rendered.listItem
        blocks[index].blockquote = rendered.blockquote
        blocks[index].math = rendered.math
        blocks[index].images = rendered.images
        blocks[index].codeBlock = rendered.codeBlock
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

    private func buildRenderedBlock(id: BlockID, snapshot: BlockSnapshot) async -> RenderedBlock {
        let rendered = await attributeBuilder.render(snapshot: snapshot)
        return RenderedBlock(id: id,
                             kind: snapshot.kind,
                             content: rendered.attributed,
                             snapshot: snapshot,
                             table: rendered.table,
                             listItem: rendered.listItem,
                             blockquote: rendered.blockquote,
                             math: rendered.math,
                             images: rendered.images,
                             codeBlock: rendered.codeBlock)
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
        lhs.codeBlock == rhs.codeBlock
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
