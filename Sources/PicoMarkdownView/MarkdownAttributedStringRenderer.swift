import Foundation
import Markdown

#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
typealias PlatformFont = NSFont
#endif

struct MarkdownRenderingConfiguration {
    var baseFont: PlatformFont
    var codeFont: PlatformFont
    var paragraphSpacing: CGFloat
    var parsingOptions: AttributedString.MarkdownParsingOptions

    static func `default`() -> MarkdownRenderingConfiguration {
    #if canImport(UIKit)
        let base = UIFont.preferredFont(forTextStyle: .body)
        let code = UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
        return MarkdownRenderingConfiguration(
            baseFont: base,
            codeFont: code,
            paragraphSpacing: 8,
            parsingOptions: .init(interpretedSyntax: .full)
        )
    #elseif canImport(AppKit)
        let base = NSFont.preferredFont(forTextStyle: .body)
        let code = NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
        return MarkdownRenderingConfiguration(
            baseFont: base,
            codeFont: code,
            paragraphSpacing: 8,
            parsingOptions: .init(interpretedSyntax: .full)
        )
    #else
        fatalError("Unsupported platform for Markdown rendering")
    #endif
    }
}

final class MarkdownAttributedStringRenderer {
    private let config: MarkdownRenderingConfiguration
    private let baseParagraphStyle: NSParagraphStyle
    private let baseAttributes: [NSAttributedString.Key: Any]

    init(configuration: MarkdownRenderingConfiguration = .default()) {
        self.config = configuration
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = configuration.paragraphSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping
        self.baseParagraphStyle = paragraphStyle
        self.baseAttributes = [
            .font: configuration.baseFont,
            .paragraphStyle: paragraphStyle
        ]
    }

    func render(document: Document) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var isFirstBlock = true

        for block in document.blockChildren {
            let renderedBlock = renderBlock(block)
            guard renderedBlock.length > 0 else { continue }

            if !isFirstBlock && !result.string.hasSuffix("\n\n") {
                result.append(NSAttributedString(string: "\n\n", attributes: baseAttributes))
            }

            result.append(renderedBlock)
            isFirstBlock = false
        }

        return result
    }

    private func renderBlock(_ block: BlockMarkup) -> NSAttributedString {
        if let table = block as? Table {
            return renderTable(table)
        }

        var formatter = MarkupFormatter()
        formatter.visit(Document([block]))
        let markdown = formatter.result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return NSAttributedString() }

        do {
            let attributed = try AttributedString(
                markdown: markdown,
                options: config.parsingOptions
            )
            return NSAttributedString(attributed)
        } catch {
            return NSAttributedString(string: markdown, attributes: baseAttributes)
        }
    }

    private func renderTable(_ table: Table) -> NSAttributedString {
        let headerCells = Array(table.head.cells.map { self.trimCell($0.plainText) })
        let bodyRows = Array(table.body.rows.map { row in
            Array(row.cells.map { self.trimCell($0.plainText) })
        })

        let columnCount = max(headerCells.count, bodyRows.map { $0.count }.max() ?? 0)
        guard columnCount > 0 else { return NSAttributedString() }

        let normalizedHeader = headerCells.isEmpty ? nil : normalize(row: headerCells, columnCount: columnCount)
        let normalizedBody = bodyRows.map { normalize(row: $0, columnCount: columnCount) }

        var widths = Array(repeating: 3, count: columnCount)
        if let headerRow = normalizedHeader {
            updateWidths(&widths, with: headerRow)
        }
        for row in normalizedBody {
            updateWidths(&widths, with: row)
        }

        let monospaceAttributes: [NSAttributedString.Key: Any] = [
            .font: config.codeFont,
            .paragraphStyle: baseParagraphStyle
        ]

        let builder = NSMutableAttributedString()

        if let headerRow = normalizedHeader {
            builder.append(NSAttributedString(string: formattedRow(headerRow, widths: widths) + "\n", attributes: monospaceAttributes))
            builder.append(NSAttributedString(string: separatorRow(widths: widths) + "\n", attributes: monospaceAttributes))
        }

        for row in normalizedBody {
            builder.append(NSAttributedString(string: formattedRow(row, widths: widths) + "\n", attributes: monospaceAttributes))
        }

        return builder
    }

    private func normalize(row: [String], columnCount: Int) -> [String] {
        if row.count >= columnCount {
            return Array(row.prefix(columnCount))
        }
        return row + Array(repeating: "", count: columnCount - row.count)
    }

    private func updateWidths(_ widths: inout [Int], with row: [String]) {
        for (index, cell) in row.enumerated() {
            widths[index] = max(widths[index], displayWidth(of: cell))
        }
    }

    private func formattedRow(_ row: [String], widths: [Int]) -> String {
        let cells = row.enumerated().map { index, value -> String in
            let width = widths[index]
            let padding = max(width - displayWidth(of: value), 0)
            return value + String(repeating: " ", count: padding)
        }
        return "| " + cells.joined(separator: " | ") + " |"
    }

    private func separatorRow(widths: [Int]) -> String {
        let cells = widths.map { width -> String in
            let length = max(width, 3)
            return String(repeating: "-", count: length)
        }
        return "| " + cells.joined(separator: " | ") + " |"
    }

    private func displayWidth(of text: String) -> Int {
        return text.count
    }

    private func trimCell(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}
