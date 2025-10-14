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

struct MarkdownRenderTheme {
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
    typealias SnapshotProvider = @Sendable (BlockID) async -> BlockSnapshot?

    private let theme: MarkdownRenderTheme
    private let snapshotProvider: SnapshotProvider
    private var storage = NSMutableAttributedString()
    private var blocks: [BlockRenderState] = []
    private var indexByID: [BlockID: Int] = [:]

    init(theme: MarkdownRenderTheme = .default(), snapshotProvider: @escaping SnapshotProvider) {
        self.theme = theme
        self.snapshotProvider = snapshotProvider
    }

    @discardableResult
    func apply(_ diff: AssemblerDiff) async -> AttributedString? {
        guard !diff.changes.isEmpty else { return nil }

        var dirtyBlocks = Set<BlockID>()

        for change in diff.changes {
            switch change {
            case .blockStarted(let id, _, let position):
                await insertBlock(id: id, at: position)
            case .runsAppended(let id, _),
                 .codeAppended(let id, _),
                 .tableHeaderConfirmed(let id),
                 .tableRowAppended(let id, _),
                 .blockEnded(let id):
                dirtyBlocks.insert(id)
            case .blocksDiscarded(let range):
                removeBlocks(in: range)
            }
        }

        for id in dirtyBlocks {
            await refreshBlock(id: id)
        }

        return makeSnapshot()
    }

    func currentAttributedString() -> AttributedString {
        makeSnapshot() ?? AttributedString()
    }

    private func makeSnapshot() -> AttributedString? {
        let copy = storage.copy() as! NSAttributedString
        return AttributedString(copy)
    }

    private func insertBlock(id: BlockID, at position: Int) async {
        guard indexByID[id] == nil else { return }
        guard let snapshot = await snapshotProvider(id) else { return }
        let rendered = render(snapshot: snapshot)
        let index = max(0, min(position, blocks.count))
        let location = index < blocks.count ? blocks[index].range.location : storage.length
        storage.insert(rendered, at: location)
        let range = NSRange(location: location, length: rendered.length)
        blocks.insert(.init(id: id, range: range, kind: snapshot.kind), at: index)
        indexByID[id] = index
        adjustRanges(startingAt: index + 1, delta: rendered.length)
    }

    private func refreshBlock(id: BlockID) async {
        guard let index = indexByID[id] else { return }
        guard let snapshot = await snapshotProvider(id) else { return }
        let rendered = render(snapshot: snapshot)
        let oldRange = blocks[index].range
        storage.replaceCharacters(in: oldRange, with: rendered)
        let delta = rendered.length - oldRange.length
        blocks[index].range = NSRange(location: oldRange.location, length: rendered.length)
        blocks[index].kind = snapshot.kind
        if delta != 0 {
            adjustRanges(startingAt: index + 1, delta: delta)
        }
    }

    private func removeBlocks(in range: Range<Int>) {
        guard !blocks.isEmpty else { return }
        let lower = max(range.lowerBound, 0)
        let upper = min(range.upperBound, blocks.count)
        guard lower < upper else { return }
        let removalRange = lower..<upper
        let location = blocks[lower].range.location
        let endLocation = blocks[upper - 1].range.upperBound
        let length = endLocation - location
        if length > 0 {
            storage.deleteCharacters(in: NSRange(location: location, length: length))
        }
        let removed = blocks[removalRange]
        blocks.removeSubrange(removalRange)
        for block in removed {
            indexByID[block.id] = nil
        }
        for idx in lower..<blocks.count {
            indexByID[blocks[idx].id] = idx
            blocks[idx].range.location -= length
        }
    }

    private func adjustRanges(startingAt index: Int, delta: Int) {
        guard delta != 0, index < blocks.count else { return }
        for idx in index..<blocks.count {
            blocks[idx].range.location += delta
            indexByID[blocks[idx].id] = idx
        }
    }

    private func render(snapshot: BlockSnapshot) -> NSAttributedString {
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
            return renderTable(snapshot.table, font: theme.bodyFont)
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

    private func renderTable(_ table: TableSnapshot?, font: PlatformFont) -> NSAttributedString {
        guard let table else { return NSAttributedString() }
        let result = NSMutableAttributedString()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font
        ]

        if let headers = table.headerCells {
            let headerLine = NSMutableAttributedString()
            for (index, cell) in headers.enumerated() {
                headerLine.append(renderInline(cell, font: font))
                if index < headers.count - 1 {
                    headerLine.append(NSAttributedString(string: " | ", attributes: attrs))
                }
            }
            headerLine.append(NSAttributedString(string: "\n", attributes: attrs))
            result.append(headerLine)
        }

        for row in table.rows {
            let rowLine = NSMutableAttributedString()
            for (index, cell) in row.enumerated() {
                rowLine.append(renderInline(cell, font: font))
                if index < row.count - 1 {
                    rowLine.append(NSAttributedString(string: " | ", attributes: attrs))
                }
            }
            rowLine.append(NSAttributedString(string: "\n", attributes: attrs))
            result.append(rowLine)
        }

        result.append(NSAttributedString(string: "\n", attributes: attrs))
        return result
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

private struct BlockRenderState {
    var id: BlockID
    var range: NSRange
    var kind: BlockKind = .paragraph
}

private extension NSRange {
    var upperBound: Int { location + length }
}

private extension NSMutableAttributedString {
    func insert(_ attrString: NSAttributedString, at index: Int) {
        self.replaceCharacters(in: NSRange(location: index, length: 0), with: attrString)
    }
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
