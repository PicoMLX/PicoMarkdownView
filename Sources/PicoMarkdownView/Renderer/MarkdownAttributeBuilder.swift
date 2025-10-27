import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct RenderedContentResult {
    var attributed: AttributedString
    var table: RenderedTable?
    var listItem: RenderedListItem?
    var blockquote: RenderedBlockquote?
    var math: RenderedMath?
    var images: [RenderedImage]
    var codeBlock: RenderedCodeBlock?
}

actor MarkdownAttributeBuilder {
    private let theme: MarkdownRenderTheme

    init(theme: MarkdownRenderTheme) {
        self.theme = theme
    }

    func render(snapshot: BlockSnapshot) async -> RenderedContentResult {
        switch snapshot.kind {
        case .table:
            let (fallback, table, images) = renderTable(snapshot, font: theme.bodyFont)
            return RenderedContentResult(attributed: AttributedString(fallback),
                                        table: table,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: images,
                                        codeBlock: nil)
        case .listItem(let ordered, let index, let task):
            return renderListItem(snapshot: snapshot, ordered: ordered, index: index, task: task)
        case .blockquote:
            return renderBlockquote(snapshot: snapshot)
        case .fencedCode:
            let text = snapshot.codeText ?? ""
            let attributes: [NSAttributedString.Key: Any] = [
                .font: theme.codeFont,
                .foregroundColor: PlatformColor.rendererLabel
            ]
            let content = NSMutableAttributedString(string: text, attributes: attributes)
            content.append(NSAttributedString(string: "\n\n", attributes: attributes))
            let language: String?
            if case let .fencedCode(value) = snapshot.kind {
                language = value
            } else {
                language = nil
            }
            return RenderedContentResult(attributed: AttributedString(content),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: [],
                                        codeBlock: RenderedCodeBlock(code: text, language: language))
        case .heading(let level):
            let font = theme.headingFonts[level] ?? theme.headingFonts[theme.headingFonts.keys.sorted().last ?? 1] ?? theme.bodyFont
            let spacing = headingParagraphSpacing(for: level)
            let (ns, images) = renderInlineBlock(snapshot,
                                                prefix: nil,
                                                suffix: "\n",
                                                font: font,
                                                spacing: spacing)
            return RenderedContentResult(attributed: AttributedString(ns),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: images,
                                        codeBlock: nil)
        case .paragraph:
            fallthrough
        case .unknown:
            let suffix = snapshot.kind == .paragraph ? "\n\n" : "\n\n"
            let spacing = paragraphSpacing()
            let (ns, images) = renderInlineBlock(snapshot,
                                                prefix: nil,
                                                suffix: suffix,
                                                font: theme.bodyFont,
                                                spacing: spacing)
            return RenderedContentResult(attributed: AttributedString(ns),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: images,
                                        codeBlock: nil)
        case .math(let display):
            let tex = snapshot.mathText ?? snapshot.inlineRuns?.map { $0.text }.joined() ?? ""
            let suffix = display ? "\n\n" : ""
            let attributed = AttributedString(tex + suffix)
            return RenderedContentResult(attributed: attributed,
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: RenderedMath(tex: tex,
                                                           display: display,
                                                           fontSize: theme.bodyFont.pointSize),
                                        images: [],
                                        codeBlock: nil)
        }
    }

    private func renderInlineBlock(_ snapshot: BlockSnapshot,
                                   prefix: String?,
                                   suffix: String,
                                   font: PlatformFont,
                                   spacing: ParagraphSpacing) -> (NSAttributedString, [RenderedImage]) {
        var imageIndex = 0
        let result = NSMutableAttributedString()
        if let prefix {
            result.append(NSAttributedString(string: prefix, attributes: [.font: font]))
        }
        let bodyRuns = sanitizeInlineRuns(snapshot.inlineRuns ?? [], kind: snapshot.kind)
        let inlineImages = collectImages(from: bodyRuns, blockID: snapshot.id, counter: &imageIndex)
        let body = renderInline(bodyRuns, font: font)
        result.append(body)
        let paragraph = makeParagraphStyle(spacing)
        if result.length > 0 {
            result.addAttributes([.paragraphStyle: paragraph], range: NSRange(location: 0, length: result.length))
        }
        let suffixAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]
        result.append(NSAttributedString(string: suffix, attributes: suffixAttributes))
        return (result, inlineImages)
    }

    private func collectImages(from runs: [InlineRun],
                               blockID: BlockID,
                               counter: inout Int) -> [RenderedImage] {
        guard !runs.isEmpty else { return [] }
        var images: [RenderedImage] = []
        for run in runs {
            guard let image = run.image else { continue }
            let id = RenderedImage.Identifier.make(blockID: blockID, index: counter)
            counter += 1
            let url = URL(string: image.source)
            images.append(RenderedImage(id: id,
                                        source: image.source,
                                        url: url,
                                        altText: run.text,
                                        title: image.title))
        }
        return images
    }

    private func renderInline(_ runs: [InlineRun], font: PlatformFont) -> NSMutableAttributedString {
        let fragments = runs.map { render(run: $0, baseFont: font) }
        let reduced = fragments.reduce(into: NSMutableAttributedString()) { result, fragment in
            result.append(fragment)
        }
        return reduced
    }

    private func renderListItem(snapshot: BlockSnapshot,
                                ordered: Bool,
                                index: Int?,
                                task: TaskListState?) -> RenderedContentResult {
        let bulletText: String
        if let task {
            bulletText = task.checked ? "☑︎" : "☐"
        } else if ordered {
            let number = index ?? 1
            bulletText = "\(number)."
        } else {
            bulletText = "•"
        }

        var imageIndex = 0
        let runs = sanitizeInlineRuns(snapshot.inlineRuns ?? [], kind: snapshot.kind)
        let inlineImages = collectImages(from: runs, blockID: snapshot.id, counter: &imageIndex)
        let body = renderInline(runs, font: theme.bodyFont)
        trimLeadingWhitespace(in: body)
        let rendered = NSMutableAttributedString(string: bulletText + " ", attributes: [.font: theme.bodyFont])
        rendered.append(body)
        let paragraph = makeParagraphStyle(paragraphSpacing())
        rendered.addAttributes([.paragraphStyle: paragraph], range: NSRange(location: 0, length: rendered.length))
        let listSpacing = paragraphSpacing()
        let separator = makeParagraphStyle(ParagraphSpacing(lineHeightMultiple: listSpacing.lineHeightMultiple,
                                                           spacingBefore: 0,
                                                           spacingAfter: 2))
        rendered.append(NSAttributedString(string: "\n", attributes: [.font: theme.bodyFont, .paragraphStyle: separator]))

        let metadata = RenderedListItem(bullet: bulletText,
                                        content: AttributedString(body),
                                        ordered: ordered,
                                        index: index,
                                        task: task)

        return RenderedContentResult(attributed: AttributedString(rendered),
                                    table: nil,
                                    listItem: metadata,
                                    blockquote: nil,
                                    math: nil,
                                    images: inlineImages,
                                    codeBlock: nil)
    }

    private struct ParagraphSpacing {
        var lineHeightMultiple: CGFloat
        var spacingBefore: CGFloat
        var spacingAfter: CGFloat
    }

    private func paragraphSpacing() -> ParagraphSpacing {
        ParagraphSpacing(lineHeightMultiple: 1.24,
                         spacingBefore: 0,
                         spacingAfter: 4)
    }

    private func headingParagraphSpacing(for level: Int) -> ParagraphSpacing {
        switch level {
        case 1:
            return ParagraphSpacing(lineHeightMultiple: 1.18,
                                    spacingBefore: 16,
                                    spacingAfter: 10)
        case 2:
            return ParagraphSpacing(lineHeightMultiple: 1.16,
                                    spacingBefore: 14,
                                    spacingAfter: 8)
        case 3:
            return ParagraphSpacing(lineHeightMultiple: 1.14,
                                    spacingBefore: 10,
                                    spacingAfter: 6)
        default:
            return ParagraphSpacing(lineHeightMultiple: 1.12,
                                    spacingBefore: 8,
                                    spacingAfter: 6)
        }
    }

    private func makeParagraphStyle(_ spacing: ParagraphSpacing) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineHeightMultiple = spacing.lineHeightMultiple
        style.paragraphSpacingBefore = spacing.spacingBefore
        style.paragraphSpacing = spacing.spacingAfter
        style.headIndent = 0
        style.firstLineHeadIndent = 0
        return style
    }

    private func trimLeadingWhitespace(in attributedString: NSMutableAttributedString) {
        guard attributedString.length > 0 else { return }
        while attributedString.length > 0 {
            let range = NSRange(location: 0, length: 1)
            let firstCharacter = attributedString.attributedSubstring(from: range).string
            guard firstCharacter == " " || firstCharacter == "\t" else { break }
            attributedString.deleteCharacters(in: range)
        }
    }

    private func renderBlockquote(snapshot: BlockSnapshot) -> RenderedContentResult {
        var imageIndex = 0
        let bodyRuns = sanitizeInlineRuns(snapshot.inlineRuns ?? [], kind: snapshot.kind)
        let inlineImages = collectImages(from: bodyRuns, blockID: snapshot.id, counter: &imageIndex)
        let body = renderInline(bodyRuns, font: theme.bodyFont)
        let paragraphStyle = makeBlockquoteParagraphStyle()
        let lineColor = theme.blockquoteColor.withAlphaComponent(0.6)
        let textColor = PlatformColor.rendererLabel

        let prefixAttributes: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: lineColor,
            .paragraphStyle: paragraphStyle
        ]

        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]

        let result = NSMutableAttributedString(string: "│ ", attributes: prefixAttributes)
        let styledBody = NSMutableAttributedString(attributedString: body)
        if styledBody.length > 0 {
            styledBody.addAttributes(bodyAttributes, range: NSRange(location: 0, length: styledBody.length))
        }
        result.append(styledBody)

        let mutableString = result.mutableString
        let prefixLength = ("│ " as NSString).length
        var searchLocation = prefixLength
        while searchLocation < mutableString.length {
            let range = mutableString.range(of: "\n", options: [], range: NSRange(location: searchLocation, length: mutableString.length - searchLocation))
            if range.location == NSNotFound { break }
            let insertLocation = range.location + range.length
            result.insert(NSAttributedString(string: "│ ", attributes: prefixAttributes), at: insertLocation)
            searchLocation = insertLocation + prefixLength
        }

        result.append(NSAttributedString(string: "\n", attributes: prefixAttributes))
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))

        return RenderedContentResult(attributed: AttributedString(result),
                                    table: nil,
                                    listItem: nil,
                                    blockquote: RenderedBlockquote(content: AttributedString(styledBody)),
                                    math: nil,
                                    images: inlineImages,
                                    codeBlock: nil)
    }

    private func makeBlockquoteParagraphStyle() -> NSMutableParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.firstLineHeadIndent = 0
        paragraphStyle.headIndent = 0
        paragraphStyle.paragraphSpacing = 8
        paragraphStyle.paragraphSpacingBefore = 4
        return paragraphStyle
    }

    private func renderTable(_ snapshot: BlockSnapshot, font: PlatformFont) -> (NSAttributedString, RenderedTable?, [RenderedImage]) {
        guard let table = snapshot.table else { return (NSAttributedString(), nil, []) }

        let maxRowColumns = table.rows.reduce(0) { max($0, $1.count) }
        let columnCount = max(table.headerCells?.count ?? 0, maxRowColumns)
        guard columnCount > 0 else { return (NSAttributedString(), nil, []) }

        let textTable = NSTextTable()
        textTable.numberOfColumns = columnCount
        textTable.collapsesBorders = false
        textTable.setContentWidth(100, type: .percentageValueType)
        textTable.setWidth(tableBorderWidth, type: .absoluteValueType, for: .border)
        textTable.setBorderColor(PlatformColor.rendererTableBorder)

        var renderedTable = RenderedTable(headers: nil, rows: [], alignments: table.alignments)
        var collectedImages: [RenderedImage] = []
        var imageIndex = 0
        let result = NSMutableAttributedString()
        var currentRow = 0

        if let headers = table.headerCells, !headers.isEmpty {
            let (headerAttributed, headerCells) = renderTableRow(cells: headers,
                                                                 rowIndex: currentRow,
                                                                 numberOfColumns: columnCount,
                                                                 textTable: textTable,
                                                                 font: font,
                                                                 alignments: table.alignments,
                                                                 blockID: snapshot.id,
                                                                 imageCounter: &imageIndex,
                                                                 collectedImages: &collectedImages,
                                                                 isHeader: true)
            renderedTable.headers = headerCells
            result.append(headerAttributed)
            currentRow += 1
        }

        var renderedRows: [[AttributedString]] = []
        for row in table.rows {
            let (rowAttributed, renderedCells) = renderTableRow(cells: row,
                                                                rowIndex: currentRow,
                                                                numberOfColumns: columnCount,
                                                                textTable: textTable,
                                                                font: font,
                                                                alignments: table.alignments,
                                                                blockID: snapshot.id,
                                                                imageCounter: &imageIndex,
                                                                collectedImages: &collectedImages,
                                                                isHeader: false)
            renderedRows.append(renderedCells)
            result.append(rowAttributed)
            currentRow += 1
        }

        renderedTable.rows = renderedRows
        result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        return (result, renderedTable, collectedImages)
    }

    private func renderTableRow(cells: [[InlineRun]],
                                rowIndex: Int,
                                numberOfColumns: Int,
                                textTable: NSTextTable,
                                font: PlatformFont,
                                alignments: [TableAlignment]?,
                                blockID: BlockID,
                                imageCounter: inout Int,
                                collectedImages: inout [RenderedImage],
                                isHeader: Bool) -> (NSAttributedString, [AttributedString]) {
        let rowAttributed = NSMutableAttributedString()
        var renderedCells: [AttributedString] = []
        let displayFont = isHeader ? boldFont(from: font) : font

        for column in 0..<numberOfColumns {
            let block = NSTextTableBlock(table: textTable, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
            block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
            block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxY)
            block.setWidth(tableBorderWidth, type: .absoluteValueType, for: .border)
            block.setBorderColor(PlatformColor.rendererTableBorder)
            block.backgroundColor = isHeader ? PlatformColor.rendererTableHeaderBackground : PlatformColor.rendererTableRowBackground

            let paragraph = NSMutableParagraphStyle()
            paragraph.textBlocks = [block]
            paragraph.alignment = tableTextAlignment(for: column, alignments: alignments)
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.paragraphSpacing = 0
            paragraph.paragraphSpacingBefore = rowIndex == 0 ? 0 : 0

            let inlineRuns = column < cells.count ? cells[column] : []
            let inline = renderInline(inlineRuns, font: displayFont)
            let images = collectImages(from: inlineRuns, blockID: blockID, counter: &imageCounter)
            if !images.isEmpty {
                collectedImages.append(contentsOf: images)
            }

            let cellContent = inline.length > 0 ? NSMutableAttributedString(attributedString: inline) : NSMutableAttributedString(string: " ")
            cellContent.addAttributes([
                .paragraphStyle: paragraph,
                .font: displayFont,
                .foregroundColor: PlatformColor.rendererLabel
            ], range: NSRange(location: 0, length: cellContent.length))

            renderedCells.append(AttributedString(cellContent))
            rowAttributed.append(cellContent)
            rowAttributed.append(NSAttributedString(string: "\n", attributes: [
                .paragraphStyle: paragraph,
                .font: displayFont
            ]))
        }

        return (rowAttributed, renderedCells)
    }

    private func tableTextAlignment(for column: Int, alignments: [TableAlignment]?) -> NSTextAlignment {
        guard let alignments, column < alignments.count else { return .left }
        switch alignments[column] {
        case .left, .none:
            return .left
        case .center:
            return .center
        case .right:
            return .right
        }
    }

    private var tableBorderWidth: CGFloat {
#if canImport(UIKit)
        return max(1.0 / UIScreen.main.scale, 0.5)
#else
        return 1.0
#endif
    }

    private func render(run: InlineRun, baseFont: PlatformFont) -> NSAttributedString {
        if run.style.contains(.math), let payload = run.math {
            return InlineMathAttachment.mathString(tex: payload.tex,
                                                   display: payload.display,
                                                   baseFont: baseFont)
        }

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

        if run.image != nil {
            return NSAttributedString()
        }

        return NSAttributedString(string: run.text, attributes: attributes)
    }

    private func sanitizeInlineRuns(_ runs: [InlineRun], kind: BlockKind) -> [InlineRun] {
        guard !runs.isEmpty else { return runs }
        switch kind {
        case .paragraph, .heading, .listItem, .blockquote:
            return runs.map { run in
                guard run.text.contains("\n"), run.text != "\n" else { return run }
                guard !run.style.contains(.math) else { return run }
                var copy = run
                copy.text = run.text.replacingOccurrences(of: "\n", with: " ")
                return copy
            }
        default:
            return runs
        }
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
}

private extension PlatformColor {
    static var rendererLabel: PlatformColor {
#if canImport(UIKit)
        return .label
#else
        return .labelColor
#endif
    }

    static var rendererTableBorder: PlatformColor {
#if canImport(UIKit)
        return .separator
#else
        return .separatorColor
#endif
    }

    static var rendererTableHeaderBackground: PlatformColor {
#if canImport(UIKit)
        return .secondarySystemBackground
#else
        return NSColor.alternatingContentBackgroundColors.first ?? .windowBackgroundColor
#endif
    }

    static var rendererTableRowBackground: PlatformColor {
#if canImport(UIKit)
        return .systemBackground
#else
        return .textBackgroundColor
#endif
    }
}
