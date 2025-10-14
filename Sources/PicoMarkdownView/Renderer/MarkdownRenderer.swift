import Foundation

#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#endif

struct MarkdownRenderTheme: @unchecked Sendable {
    var bodyFont: PlatformFont
    var codeFont: PlatformFont
    var blockquoteColor: PlatformColor
    var linkColor: PlatformColor
    var headingFonts: [Int: PlatformFont]

    init(bodyFont: PlatformFont,
         codeFont: PlatformFont,
         blockquoteColor: PlatformColor,
         linkColor: PlatformColor,
         headingFonts: [Int: PlatformFont]) {
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.blockquoteColor = blockquoteColor
        self.linkColor = linkColor
        self.headingFonts = headingFonts
    }

    static func `default`() -> MarkdownRenderTheme {
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
    private let snapshotProvider: SnapshotProvider
    private var blocks: [RenderedBlock] = []
    private var indexByID: [BlockID: Int] = [:]

    init(theme: MarkdownRenderTheme = .default(), snapshotProvider: @escaping SnapshotProvider) {
        self.theme = theme
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
        let block = buildRenderedBlock(id: id, snapshot: snapshot)
        let index = max(0, min(position, blocks.count))
        blocks.insert(block, at: index)
        rebuildIndex(startingAt: index)
    }

    private func refreshBlock(id: BlockID) async {
        guard let index = indexByID[id] else { return }
        let snapshot = await snapshotProvider(id)
        let rendered = renderContent(snapshot: snapshot)
        blocks[index].kind = snapshot.kind
        blocks[index].snapshot = snapshot
        blocks[index].content = rendered.content
        blocks[index].table = rendered.table
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

    private func buildRenderedBlock(id: BlockID, snapshot: BlockSnapshot) -> RenderedBlock {
        let rendered = renderContent(snapshot: snapshot)
        return RenderedBlock(id: id,
                             kind: snapshot.kind,
                             content: rendered.content,
                             snapshot: snapshot,
                             table: rendered.table)
    }

    private func renderContent(snapshot: BlockSnapshot) -> (content: AttributedString, table: RenderedTable?) {
        switch snapshot.kind {
        case .table:
            let (fallback, table) = renderTable(snapshot.table, font: theme.bodyFont)
            return (AttributedString(fallback), table)
        default:
            let ns = render(nsSnapshot: snapshot)
            return (AttributedString(ns), nil)
        }
    }

    private func render(nsSnapshot snapshot: BlockSnapshot) -> NSAttributedString {
        switch snapshot.kind {
        case .paragraph:
            return renderInlineBlock(snapshot, prefix: nil, suffix: "\n\n", font: theme.bodyFont)
        case .heading(let level):
            let font = theme.headingFonts[level] ?? theme.headingFonts[theme.headingFonts.keys.sorted().last ?? 1] ?? theme.bodyFont
            return renderInlineBlock(snapshot, prefix: nil, suffix: "\n", font: font)
        case .listItem(let ordered, let index, let task):
            let bullet: String
            if let task {
                bullet = task.checked ? "☑︎ " : "☐ "
            } else if ordered {
                let number = index ?? 1
                bullet = "\(number). "
            } else {
                bullet = "• "
            }
            return renderInlineBlock(snapshot, prefix: bullet, suffix: "\n", font: theme.bodyFont)
        case .blockquote:
            let body = renderInline(snapshot.inlineRuns ?? [], font: theme.bodyFont)
            let mutable = NSMutableAttributedString()
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.headIndent = 16
            paragraphStyle.firstLineHeadIndent = 16
            let attributes: [NSAttributedString.Key: Any] = [
                .font: theme.bodyFont,
                .foregroundColor: theme.blockquoteColor,
                .paragraphStyle: paragraphStyle
            ]
            mutable.append(NSAttributedString(string: "› ", attributes: attributes))
            mutable.append(body)
            mutable.append(NSAttributedString(string: "\n", attributes: attributes))
            return mutable
        case .fencedCode:
            let text = snapshot.codeText ?? ""
            let attributes: [NSAttributedString.Key: Any] = [
                .font: theme.codeFont,
                .foregroundColor: PlatformColor.rendererLabel
            ]
            let content = NSMutableAttributedString(string: text, attributes: attributes)
            content.append(NSAttributedString(string: "\n\n", attributes: attributes))
            return content
        case .table:
            let (fallback, _) = renderTable(snapshot.table, font: theme.bodyFont)
            return fallback
        case .unknown:
            if snapshot.inlineRuns != nil {
                return renderInlineBlock(snapshot, prefix: nil, suffix: "\n\n", font: theme.bodyFont)
            }
            let text = snapshot.codeText ?? ""
            return NSAttributedString(string: text)
        }
    }

    private func renderInlineBlock(_ snapshot: BlockSnapshot,
                                   prefix: String?,
                                   suffix: String,
                                   font: PlatformFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = renderInline(snapshot.inlineRuns ?? [], font: font)
        if let prefix {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font
            ]
            result.append(NSAttributedString(string: prefix, attributes: attrs))
        }
        result.append(body)
        result.append(NSAttributedString(string: suffix, attributes: [.font: font]))
        return result
    }

    private func renderInline(_ runs: [InlineRun], font: PlatformFont) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()
        for run in runs {
            output.append(render(run: run, baseFont: font))
        }
        return output
    }

    private func renderTable(_ table: TableSnapshot?, font: PlatformFont) -> (NSAttributedString, RenderedTable?) {
        guard let table else { return (NSAttributedString(), nil) }
        let result = NSMutableAttributedString()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font
        ]

        var renderedTable = RenderedTable(headers: nil, rows: [], alignments: table.alignments)

        if let headers = table.headerCells {
            let headerLine = NSMutableAttributedString()
            var headerCells: [AttributedString] = []
            for (index, cell) in headers.enumerated() {
                let inline = renderInline(cell, font: font)
                let headerAttributes: [NSAttributedString.Key: Any] = [
                    .font: boldFont(from: font),
                    .foregroundColor: attrs[.foregroundColor] ?? PlatformColor.rendererLabel
                ]
                let attributed = NSMutableAttributedString(attributedString: inline)
                attributed.addAttributes(headerAttributes, range: NSRange(location: 0, length: attributed.length))
                headerLine.append(attributed)
                headerCells.append(AttributedString(attributed))
                if index < headers.count - 1 {
                    let separator = NSAttributedString(string: " | ", attributes: attrs)
                    headerLine.append(separator)
                }
            }
            headerLine.append(NSAttributedString(string: "\n", attributes: attrs))
            result.append(headerLine)
            renderedTable.headers = headerCells
        }

        var renderedRows: [[AttributedString]] = []
        for row in table.rows {
            let rowLine = NSMutableAttributedString()
            var renderedCells: [AttributedString] = []
            for (index, cell) in row.enumerated() {
                let inline = renderInline(cell, font: font)
                rowLine.append(inline)
                renderedCells.append(AttributedString(inline))
                if index < row.count - 1 {
                    let separator = NSAttributedString(string: " | ", attributes: attrs)
                    rowLine.append(separator)
                }
            }
            rowLine.append(NSAttributedString(string: "\n", attributes: attrs))
            result.append(rowLine)
            renderedRows.append(renderedCells)
        }

        renderedTable.rows = renderedRows
        result.append(NSAttributedString(string: "\n", attributes: attrs))
        return (result, renderedTable)
    }

    private func render(run: InlineRun, baseFont: PlatformFont) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: run.style, baseFont: baseFont)
        ]
        if run.style.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if run.style.contains(.link), let url = run.linkURL, let linkURL = URL(string: url) {
            attributes[.foregroundColor] = theme.linkColor
            attributes[.link] = linkURL
        }
        if run.style.contains(.code) {
            attributes[.font] = theme.codeFont
        }

        if let image = run.image {
            let text = "[\(run.text)](\(image.source))"
            return NSAttributedString(string: text, attributes: attributes)
        }

        return NSAttributedString(string: run.text, attributes: attributes)
    }

    private func font(for style: InlineStyle, baseFont: PlatformFont) -> PlatformFont {
        var font = style.contains(.code) ? theme.codeFont : baseFont
#if canImport(UIKit)
        if style.contains(.bold) && style.contains(.italic) {
            let descriptor = font.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) ?? font.fontDescriptor
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        } else if style.contains(.bold) {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        } else if style.contains(.italic) {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) ?? font.fontDescriptor
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        }
#else
        if style.contains(.bold) || style.contains(.italic) {
            var traits = font.fontDescriptor.symbolicTraits
            if style.contains(.bold) { traits.insert(.bold) }
            if style.contains(.italic) { traits.insert(.italic) }
            let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
            font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }
#endif
        return font
    }
}

private func boldFont(from base: PlatformFont) -> PlatformFont {
#if canImport(UIKit)
    if let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) {
        return PlatformFont(descriptor: descriptor, size: base.pointSize)
    }
    return PlatformFont.systemFont(ofSize: base.pointSize, weight: .bold)
#else
    var traits = base.fontDescriptor.symbolicTraits
    traits.insert(.bold)
    let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
    if let font = PlatformFont(descriptor: descriptor, size: base.pointSize) {
        return font
    }
    return PlatformFont.boldSystemFont(ofSize: base.pointSize)
#endif
}

struct RenderedBlock: Sendable, Identifiable {
    var id: BlockID
    var kind: BlockKind
    var content: AttributedString
    var snapshot: BlockSnapshot
    var table: RenderedTable?
}

struct RenderedTable: Sendable, Equatable {
    var headers: [AttributedString]?
    var rows: [[AttributedString]]
    var alignments: [TableAlignment]?
}

private extension PlatformColor {
    static var rendererLabel: PlatformColor {
#if canImport(UIKit)
        return .label
#else
        return .labelColor
#endif
    }
}
