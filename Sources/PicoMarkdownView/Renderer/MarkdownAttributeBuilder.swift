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
}

actor MarkdownAttributeBuilder {
    private let theme: MarkdownRenderTheme

    init(theme: MarkdownRenderTheme) {
        self.theme = theme
    }

    func render(snapshot: BlockSnapshot) -> RenderedContentResult {
        switch snapshot.kind {
        case .table:
            let (fallback, table) = renderTable(snapshot.table, font: theme.bodyFont)
            return RenderedContentResult(attributed: AttributedString(fallback),
                                        table: table,
                                        listItem: nil,
                                        blockquote: nil)
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
            return RenderedContentResult(attributed: AttributedString(content),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil)
        case .heading(let level):
            let font = theme.headingFonts[level] ?? theme.headingFonts[theme.headingFonts.keys.sorted().last ?? 1] ?? theme.bodyFont
            let ns = renderInlineBlock(snapshot, prefix: nil, suffix: "\n", font: font)
            return RenderedContentResult(attributed: AttributedString(ns),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil)
        case .paragraph:
            fallthrough
        case .unknown:
            let suffix = snapshot.kind == .paragraph ? "\n\n" : "\n\n"
            let ns = renderInlineBlock(snapshot, prefix: nil, suffix: suffix, font: theme.bodyFont)
            return RenderedContentResult(attributed: AttributedString(ns),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil)
        }
    }

    private func renderInlineBlock(_ snapshot: BlockSnapshot,
                                   prefix: String?,
                                   suffix: String,
                                   font: PlatformFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let prefix {
            result.append(NSAttributedString(string: prefix, attributes: [.font: font]))
        }
        let body = renderInline(snapshot.inlineRuns ?? [], font: font)
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

        let body = renderInline(snapshot.inlineRuns ?? [], font: theme.bodyFont)
        let rendered = NSMutableAttributedString(string: bulletText + " ", attributes: [.font: theme.bodyFont])
        rendered.append(body)
        rendered.append(NSAttributedString(string: "\n", attributes: [.font: theme.bodyFont]))

        let metadata = RenderedListItem(bullet: bulletText,
                                        content: AttributedString(body),
                                        ordered: ordered,
                                        index: index,
                                        task: task)

        return RenderedContentResult(attributed: AttributedString(rendered),
                                    table: nil,
                                    listItem: metadata,
                                    blockquote: nil)
    }

    private func renderBlockquote(snapshot: BlockSnapshot) -> RenderedContentResult {
        let body = renderInline(snapshot.inlineRuns ?? [], font: theme.bodyFont)
        let paragraphStyle = makeBlockquoteParagraphStyle()
        let lineColor = theme.blockquoteColor.withAlphaComponent(0.6)

        let prefixAttributes: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: lineColor,
            .paragraphStyle: paragraphStyle
        ]

        let result = NSMutableAttributedString(string: "│ ", attributes: prefixAttributes)
        let styledBody = NSMutableAttributedString(attributedString: body)
        if styledBody.length > 0 {
            styledBody.addAttributes(prefixAttributes, range: NSRange(location: 0, length: styledBody.length))
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
                                    blockquote: RenderedBlockquote(content: AttributedString(styledBody)))
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
                if attributed.length > 0 {
                    attributed.addAttributes(headerAttributes, range: NSRange(location: 0, length: attributed.length))
                }
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
}
