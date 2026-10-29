#if canImport(AppKit)
import AppKit
import Foundation
import Testing
@testable import PicoMarkdownView

@Suite
struct HostedTableRendererTests {
    @Test("Appending table rows never reloads already rendered images")
    func appendsReuseRenderedCells() async {
        let firstURL = URL(string: "https://example.com/first.png")!
        let secondURL = URL(string: "https://example.com/second.png")!
        let provider = CountingTableImageProvider()
        let builder = MarkdownAttributeBuilder(theme: .default(), imageProvider: provider)
        var snapshot = tableSnapshot(rows: [[imageRun("first", url: firstURL)]])
        let initial = await builder.render(snapshot: snapshot)
        #expect(initial.table?.rows.count == 1)
        #expect(await provider.requests(for: firstURL) == 1)

        snapshot.table?.rows.append([[imageRun("second", url: secondURL)]])
        let appended = await builder.render(snapshot: snapshot)
        #expect(appended.table?.rows.count == 2)
        #expect(appended.images.count == 2)
        #expect(await provider.requests(for: firstURL) == 1)
        #expect(await provider.requests(for: secondURL) == 1)

        _ = await builder.render(snapshot: snapshot)
        #expect(await provider.requests(for: firstURL) == 1)
        await builder.invalidateTableCache(for: [snapshot.id])
        _ = await builder.render(snapshot: snapshot)
        #expect(await provider.requests(for: firstURL) == 2)
        #expect(await provider.requests(for: secondURL) == 2)

        snapshot.isClosed = true
        _ = await builder.render(snapshot: snapshot)
        #expect(await provider.requests(for: firstURL) == 2)
    }

    @Test("Hosted tables preserve quote and list placement on the attachment paragraph")
    func nestedTablePlacement() async throws {
        let builder = MarkdownAttributeBuilder(theme: .default())
        let rendered = await builder.render(snapshot: tableSnapshot(rows: [[InlineRun(text: "cell")]]),
                                            previousBlockKind: .paragraph, blockquoteLevel: 2, listIndent: 37)
        let content = NSAttributedString.picoConverted(from: rendered.attributed)
        #expect(content.string == "\u{FFFC}\n")
        #expect(content.attribute(.picoBlockquoteLevel, at: 0, effectiveRange: nil) as? Int == 2)
        let paragraph = try #require(content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.headIndent == 37 + BlockquoteBarMetrics.textIndent(level: 2))
        #expect(paragraph.textBlocks.isEmpty)
        #expect(paragraph.paragraphSpacing == 8)
        let cell = NSAttributedString(try #require(rendered.table?.rows.first?.first))
        let cellParagraph = try #require(cell.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(cellParagraph.headIndent == 0)
        #expect(cellParagraph.textBlocks.isEmpty)
    }

    @Test("Hosted table cells retain math, images, links and their fonts")
    @MainActor
    func richCellContent() async throws {
        let imageURL = URL(string: "https://example.com/cell.png")!
        let provider = CountingTableImageProvider(result: MarkdownImageResult(image: NSImage(size: NSSize(width: 48, height: 24))))
        let theme = MarkdownRenderTheme(bodyFont: FontSpec(size: 21), codeFont: FontSpec(size: 19, design: .monospaced),
                                        blockquoteColor: .secondaryLabel, linkColor: .link, headingFonts: [:])
        let builder = MarkdownAttributeBuilder(theme: theme, imageProvider: provider)
        var snapshot = tableSnapshot(rows: [[InlineRun(text: "bold", style: .bold)],
                                             [InlineRun(text: "docs", style: .link, linkURL: "https://developer.apple.com")],
                                             [InlineRun(text: "x^2", style: .math, math: MathInlinePayload(tex: "x^2", display: false))],
                                             [imageRun("diagram", url: imageURL)]])
        snapshot.table?.alignments = [.right]
        let result = await builder.render(snapshot: snapshot)
        let table = try #require(result.table)
        let bold = NSAttributedString(table.rows[0][0])
        let boldFont = try #require(bold.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(boldFont.pointSize == 21)
        #expect(boldFont.fontDescriptor.symbolicTraits.contains(.bold))
        let link = NSAttributedString(table.rows[1][0])
        #expect(link.attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "https://developer.apple.com"))
        for row in table.rows[2...] {
            let cell = NSAttributedString(row[0])
            #expect(cell.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
            let paragraph = try #require(cell.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            #expect(paragraph.alignment == .right)
            #expect(paragraph.textBlocks.isEmpty)
        }
        #expect(result.images.first?.source == imageURL.absoluteString)
    }

    @Test("Horizontal rules use a resizable attachment without text blocks")
    @MainActor
    func horizontalRuleTracksAvailableWidth() async throws {
        let builder = MarkdownAttributeBuilder(theme: .default())
        let rendered = await builder.render(snapshot: BlockSnapshot(id: 52, kind: .horizontalRule, isClosed: true))
        let content = NSAttributedString(rendered.attributed)
        let attachment = try #require(content.attribute(.attachment, at: 0, effectiveRange: nil) as? MacHorizontalRuleAttachment)
        let paragraph = try #require(content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.textBlocks.isEmpty)
        #expect(paragraph.paragraphSpacing == 20)
        let storage = NSTextContentStorage()
        storage.textStorage = NSTextStorage(string: "rule")
        let location = storage.documentRange.location
        let wide = attachment.attachmentBounds(for: [:], location: location, textContainer: nil,
                                                proposedLineFragment: CGRect(x: 0, y: 0, width: 400, height: 30),
                                                position: CGPoint(x: 32, y: 0))
        let narrow = attachment.attachmentBounds(for: [:], location: location, textContainer: nil,
                                                  proposedLineFragment: CGRect(x: 0, y: 0, width: 200, height: 30),
                                                  position: CGPoint(x: 32, y: 0))
        #expect(wide.width == 368)
        #expect(narrow.width == 168)
        #expect(wide.height == 1)
        #expect(attachment.image(for: narrow, attributes: [:], location: location, textContainer: nil)?.size == narrow.size)
    }

    private func imageRun(_ alt: String, url: URL) -> InlineRun {
        InlineRun(text: alt, style: .image, image: InlineImage(source: url.absoluteString))
    }

    private func tableSnapshot(rows: [[InlineRun]]) -> BlockSnapshot {
        BlockSnapshot(id: 41, kind: .table,
                      table: TableSnapshot(headerCells: [[InlineRun(text: "Header")]], alignments: [.left],
                                           rows: rows.map { [$0] }, isHeaderConfirmed: true), isClosed: false)
    }
}

private actor CountingTableImageProvider: MarkdownImageProvider {
    private var counts: [URL: Int] = [:]
    private let result: MarkdownImageResult?

    init(result: MarkdownImageResult? = nil) { self.result = result }

    func image(for url: URL) async -> MarkdownImageResult? {
        counts[url, default: 0] += 1
        return result
    }

    func requests(for url: URL) -> Int { counts[url, default: 0] }
}
#endif
