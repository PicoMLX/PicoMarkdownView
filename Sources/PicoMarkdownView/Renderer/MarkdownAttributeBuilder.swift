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
    private let imageProvider: MarkdownImageProvider?

    init(theme: MarkdownRenderTheme, imageProvider: MarkdownImageProvider? = nil) {
        self.theme = theme
        self.imageProvider = imageProvider
    }

    func render(snapshot: BlockSnapshot) async -> RenderedContentResult {
        switch snapshot.kind {
        case .table:
            let (fallback, table, images) = await renderTable(snapshot, font: theme.bodyFont)
            return RenderedContentResult(attributed: AttributedString(fallback),
                                        table: table,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: images,
                                        codeBlock: nil)
        case .listItem(let ordered, let index, let task):
            return await renderListItem(snapshot: snapshot, ordered: ordered, index: index, task: task)
        case .blockquote:
            return await renderBlockquote(snapshot: snapshot)
        case .fencedCode:
            let text = snapshot.codeText ?? ""
            let codeSpacing = makeParagraphStyle(ParagraphSpacing(lineHeightMultiple: 1.24, spacingBefore: 0, spacingAfter: 12))
            let content: NSMutableAttributedString
            if let codeTheme = theme.codeBlockTheme {
                let highlighter = theme.codeHighlighter ?? AnyCodeSyntaxHighlighter(PlainCodeSyntaxHighlighter())
                let highlighted = highlighter.highlight(text, language: {
                    if case let .fencedCode(value) = snapshot.kind {
                        return value
                    }
                    return nil
                }(), theme: codeTheme)
                content = NSMutableAttributedString(highlighted)

                if content.length > 0 {
                    content.addAttribute(.paragraphStyle, value: codeSpacing, range: NSRange(location: 0, length: content.length))
                    if codeTheme.backgroundColor != .clear {
                        content.addAttribute(.backgroundColor, value: codeTheme.backgroundColor, range: NSRange(location: 0, length: content.length))
                    }
                }

                var suffixAttrs: [NSAttributedString.Key: Any] = [
                    .font: codeTheme.font,
                    .paragraphStyle: codeSpacing
                ]
                suffixAttrs[.foregroundColor] = codeTheme.foregroundColor
                if codeTheme.backgroundColor != .clear {
                    suffixAttrs[.backgroundColor] = codeTheme.backgroundColor
                }
                content.append(NSAttributedString(string: "\n", attributes: suffixAttrs))
            } else {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: theme.codeFont,
                    .foregroundColor: PlatformColor.rendererLabel
                ]
                content = NSMutableAttributedString(string: text, attributes: attributes)
                let suffixAttrs: [NSAttributedString.Key: Any] = [
                    .font: theme.codeFont,
                    .foregroundColor: PlatformColor.rendererLabel,
                    .paragraphStyle: codeSpacing
                ]
                content.append(NSAttributedString(string: "\n", attributes: suffixAttrs))
            }
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
        case .horizontalRule:
            let content = renderHorizontalRule()
            return RenderedContentResult(attributed: AttributedString(content),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: [],
                                        codeBlock: nil)
        case .heading(let level):
            let font = theme.headingFonts[level] ?? theme.headingFonts[theme.headingFonts.keys.sorted().last ?? 1] ?? theme.bodyFont
            let spacing = headingParagraphSpacing(for: level)
            let (ns, images) = await renderInlineBlock(snapshot,
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
            let suffix = "\n"
            let spacing = paragraphSpacing()
            let (ns, images) = await renderInlineBlock(snapshot,
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
        case .footnoteDefinition(_, let index):
            let prefixText = "[\(index)] "
            let suffix = "\n"
            let spacing = paragraphSpacing()
            let (ns, images) = await renderInlineBlock(snapshot,
                                                prefix: prefixText,
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
        case .unknown:
            let suffix = "\n"
            let spacing = paragraphSpacing()
            let (ns, images) = await renderInlineBlock(snapshot,
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
            
            // Render math using InlineMathAttachment (same approach as inline math)
            let mathNS = InlineMathAttachment.mathString(tex: tex,
                                                        display: display,
                                                        baseFont: theme.bodyFont)
            let result = NSMutableAttributedString(attributedString: mathNS)
            
            let suffix = display ? "\n" : ""
            let mathSpacing = display ? makeParagraphStyle(ParagraphSpacing(lineHeightMultiple: 1.24, spacingBefore: 0, spacingAfter: 12)) : makeParagraphStyle(ParagraphSpacing(lineHeightMultiple: 1.24, spacingBefore: 0, spacingAfter: 0))
            let suffixAttrs: [NSAttributedString.Key: Any] = [.font: theme.bodyFont, .paragraphStyle: mathSpacing]
            result.append(NSAttributedString(string: suffix, attributes: suffixAttrs))
            
            return RenderedContentResult(attributed: AttributedString(result),
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

    private func renderHorizontalRule() -> NSAttributedString {
        _ = paragraphSpacing()

        // Use a 1-column NSTextTable that spans 100% width with a top border to emulate an HR
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.collapsesBorders = false
        table.setContentWidth(100, type: .percentageValueType)

        let block = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        // Minimal vertical padding so the rule is a thin line
        block.setWidth(0, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(0, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(0, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(0, type: .absoluteValueType, for: .padding, edge: .maxX)
        // Draw a single hairline using secondary label color; zero-out other edges
        block.setWidth(horizontalRuleBorderWidth, type: .absoluteValueType, for: .border, edge: .minY)
        block.setBorderColor(PlatformColor.rendererSecondaryLabel, for: .minY)
        block.setWidth(0, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(nil, for: .maxY)
        block.setWidth(0, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(nil, for: .minX)
        block.setWidth(0, type: .absoluteValueType, for: .border, edge: .maxX)
        block.setBorderColor(nil, for: .maxX)

        let blockParagraph = NSMutableParagraphStyle()
        blockParagraph.textBlocks = [block]
        blockParagraph.alignment = .left
        blockParagraph.lineBreakMode = .byWordWrapping
        blockParagraph.paragraphSpacing = 20
        blockParagraph.paragraphSpacingBefore = 20

        let result = NSMutableAttributedString()
        // Add a thin, non-breaking space to instantiate the block
        let cellContent = NSAttributedString(string: "\u{00A0}", attributes: [
            .paragraphStyle: blockParagraph,
            .font: theme.bodyFont,
            .foregroundColor: PlatformColor.rendererLabel
        ])
        result.append(cellContent)
        // Trailing spacing beneath the rule kept minimal; rely on next block's own spacing
//        result.append(NSAttributedString(string: "\n", attributes: [
//            .font: theme.bodyFont,
//            .paragraphStyle: blockParagraph
//        ]))
        // No extra blank paragraph appended here
        return result
    }

    private func renderInlineBlock(_ snapshot: BlockSnapshot,
                                   prefix: String?,
                                   suffix: String,
                                   font: PlatformFont,
                                   spacing: ParagraphSpacing) async -> (NSAttributedString, [RenderedImage]) {
        var imageIndex = 0
        let result = NSMutableAttributedString()
        if let prefix {
            result.append(NSAttributedString(string: prefix, attributes: [.font: font]))
        }
        let bodyRuns = sanitizeInlineRuns(snapshot.inlineRuns ?? [], kind: snapshot.kind)
        let inlineImages = collectImages(from: bodyRuns, blockID: snapshot.id, counter: &imageIndex)
        let body = await renderInline(bodyRuns, font: font)
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

    private func renderInline(_ runs: [InlineRun], font: PlatformFont) async -> NSMutableAttributedString {
        let reduced = NSMutableAttributedString()
        for run in runs {
            let fragment = await render(run: run, baseFont: font)
            reduced.append(fragment)
        }
        return reduced
    }

    private func renderListItem(snapshot: BlockSnapshot,
                                ordered: Bool,
                                index: Int?,
                                task: TaskListState?) async -> RenderedContentResult {
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
        let body = await renderInline(runs, font: theme.bodyFont)
        trimLeadingWhitespace(in: body)

        // 1. actual text has only ONE space so tests stay stable
        let bulletPrefix = bulletText + " "
        let rendered = NSMutableAttributedString(string: bulletPrefix, attributes: [.font: theme.bodyFont])
        rendered.append(body)

        // Calculate spacing - add extra space for empty lines between list items
        var listSpacing = paragraphSpacing()
        // If there's extra depth, this is part of a nested structure
        if snapshot.depth > 0 {
            // Reduce spacing for nested items
            listSpacing.spacingAfter = max(0, listSpacing.spacingAfter - 5)
        }
        let listParagraph = makeParagraphStyle(listSpacing)

        // 2. measure what we actually drew
        let bulletWidth = bulletPrefixWidth(for: bulletPrefix, font: theme.bodyFont)
        let minOrderedWidth = ordered ? orderedBulletMinWidth(font: theme.bodyFont) : 0

        // gap *after* the bullet before the text begins
        let bulletTextGap: CGFloat = 12
        
        // Add indentation for nested list items (depth 1 = 20pt, depth 2 = 40pt, etc.)
        let nestingIndent: CGFloat = CGFloat(snapshot.depth) * 20

        // 5. final column where ALL wrapped lines should start
        let headIndent = nestingIndent + max(bulletWidth, minOrderedWidth) + bulletTextGap

        // same alignment fix as before
        listParagraph.firstLineHeadIndent = headIndent - bulletWidth
        listParagraph.headIndent = headIndent
        
        
        
        // 2. measure what we actually drew
//        let bulletWidth = bulletPrefixWidth(for: bulletPrefix, font: theme.bodyFont)
//        // 3. reserved width for ordered lists ("10.", "100.")
//        let minOrderedWidth = ordered ? orderedBulletMinWidth(font: theme.bodyFont) : 0
//
//        // 4. this is the EXTRA horizontal gap you wanted
//        let extraPadding: CGFloat = 6   // <-- tweak here
//
//        // 5. final column where ALL wrapped lines should start
//        let headIndent = max(bulletWidth, minOrderedWidth) + extraPadding

        // 6. first line already contains the bullet text,
        // so only move it by the *difference* between what we drew and what we reserve
//        listParagraph.firstLineHeadIndent = headIndent - bulletWidth
//        listParagraph.headIndent = headIndent

        rendered.addAttributes([.paragraphStyle: listParagraph],
                               range: NSRange(location: 0, length: rendered.length))

        // your separator stays the same
        let separator = makeParagraphStyle(
            ParagraphSpacing(lineHeightMultiple: listSpacing.lineHeightMultiple,
                             spacingBefore: 0,
                             spacingAfter: 10)
        )
        rendered.append(NSAttributedString(string: "\n",
                                           attributes: [.font: theme.bodyFont,
                                                        .paragraphStyle: separator]))

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

    private func bulletPrefixWidth(for bullet: String, font: PlatformFont) -> CGFloat {
        let ns = bullet as NSString
        let size = ns.size(withAttributes: [.font: font])
        // Add a tiny extra padding so wrapped lines don't collide with the bullet
        return ceil(size.width)
    }

    private func orderedBulletMinWidth(font: PlatformFont) -> CGFloat {
        let sample = "99.  " as NSString
        let size = sample.size(withAttributes: [.font: font])
        return ceil(size.width)
    }

    private struct ParagraphSpacing {
        var lineHeightMultiple: CGFloat
        var spacingBefore: CGFloat
        var spacingAfter: CGFloat
    }

    private func paragraphSpacing() -> ParagraphSpacing {
        ParagraphSpacing(lineHeightMultiple: 1.24,
                         spacingBefore: 0,
                         spacingAfter: 12)
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
                                    spacingAfter: 12)
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

    private func renderBlockquote(snapshot: BlockSnapshot) async -> RenderedContentResult {
        var imageIndex = 0
        let bodyRuns = sanitizeInlineRuns(snapshot.inlineRuns ?? [], kind: snapshot.kind)
        let inlineImages = collectImages(from: bodyRuns, blockID: snapshot.id, counter: &imageIndex)
        let body = await renderInline(bodyRuns, font: theme.bodyFont)
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

    private func renderTable(_ snapshot: BlockSnapshot, font: PlatformFont) async -> (NSAttributedString, RenderedTable?, [RenderedImage]) {
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
            let (headerAttributed, headerCells) = await renderTableRow(cells: headers,
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
            let (rowAttributed, renderedCells) = await renderTableRow(cells: row,
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
                                isHeader: Bool) async -> (NSAttributedString, [AttributedString]) {
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
            let inline = await renderInline(inlineRuns, font: displayFont)
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

    private var horizontalRuleBorderWidth: CGFloat {
#if canImport(UIKit)
        let baseBorder = max(1.0 / UIScreen.main.scale, 0.5)
        let previousWidth = max(baseBorder / 2, 0.25)
        return max(previousWidth / 2, 0.125)
#else
        return 0.1
#endif
    }

    private func render(run: InlineRun, baseFont: PlatformFont) async -> NSAttributedString {
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
        if run.style.contains(.keyboard) {
            attributes[.font] = theme.codeFont
            attributes[.backgroundColor] = PlatformColor.rendererKeyboardBackground
            attributes[.foregroundColor] = PlatformColor.rendererLabel
        }

        if run.style.contains(.superscript) || run.style.contains(.subscriptText) {
            let baseFont = (attributes[.font] as? PlatformFont) ?? baseFont
            let size = baseFont.pointSize * 0.75
#if canImport(UIKit)
            let adjusted = UIFont(descriptor: baseFont.fontDescriptor, size: size)
#else
            let adjusted = NSFont(descriptor: baseFont.fontDescriptor, size: size) ?? baseFont
#endif
            attributes[.font] = adjusted
            let offset = baseFont.pointSize * (run.style.contains(.superscript) ? 0.35 : -0.2)
            attributes[.baselineOffset] = offset
        }

        if let imagePayload = run.image {
            if let url = URL(string: imagePayload.source), let provider = imageProvider {
                if let result = await provider.image(for: url) {
                    let attachment = NSTextAttachment()
                    attachment.image = result.image
                    let size = result.size ?? result.image.size
                    let target = constrainImageSize(size)
                    attachment.bounds = CGRect(origin: .zero, size: target)
                    return NSAttributedString(attachment: attachment)
                }
            }
            // Fallback: render alt text if image not available
            return NSAttributedString(string: run.text, attributes: attributes)
        }

        return NSAttributedString(string: run.text, attributes: attributes)
    }

    private func constrainImageSize(_ size: CGSize) -> CGSize {
        guard let maxWidth = theme.imageMaxWidth, maxWidth > 0 else { return size }
        guard size.width > maxWidth else { return size }
        let scale = maxWidth / size.width
        return CGSize(width: maxWidth, height: size.height * scale)
    }

    private func sanitizeInlineRuns(_ runs: [InlineRun], kind: BlockKind) -> [InlineRun] {
        guard !runs.isEmpty else { return runs }
        switch kind {
        case .paragraph, .heading, .listItem, .blockquote, .footnoteDefinition:
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

    static var rendererSecondaryLabel: PlatformColor {
#if canImport(UIKit)
        return .secondaryLabel
#else
        return .secondaryLabelColor
#endif
    }

    static var rendererKeyboardBackground: PlatformColor {
#if canImport(UIKit)
        return .systemGray5
#else
        return .controlBackgroundColor
#endif
    }
}
