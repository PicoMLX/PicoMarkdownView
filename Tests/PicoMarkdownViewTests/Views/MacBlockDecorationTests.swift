#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import SwiftUI
import Testing
@testable import PicoMarkdownView

/// These are rendering tests: the observations below come from NSView's real
/// bitmap cache, with geometry supplied by each engine's laid-out text. The
/// frozen TK1 renderer is an independent baseline, not the production path.
@Suite("macOS block decoration pixels", .serialized)
@MainActor
struct MacBlockDecorationTests {
    @Test("Nested quote bars stay in their gutter and join through paragraph gaps",
          arguments: [300.0, 600.0], [1.0, 1.5])
    func nestedQuotePixels(width: Double, scale: Double) async throws {
        let fixture = try await DecorationFixture(markdown: """
        Before quote.

        > Outer alpha.
        >
        > > Nested beta.
        >
        > Back gamma.

        Outside omega.

        """, width: width, scale: scale)
        defer { fixture.close() }
        let actual = try fixture.capture()
        let baseline = try fixture.captureBaseline()
        for (text, count) in [("Outer alpha", 1), ("Nested beta", 2), ("Back gamma", 1)] {
            let row = try fixture.row(containing: text)
            let oldRow = try fixture.baselineRow(containing: text)
            let bars = actual.barRuns(at: row.midY)
            let oldBars = baseline.barRuns(at: oldRow.midY)
            #expect(bars.count == count, "\(text): rendered bars \(bars)")
            #expect(oldBars.count == count, "frozen TK1 baseline must exercise the same quote")
            if let bar = bars.first, let oldBar = oldBars.first {
                #expect(abs(bar.lowerBound - oldBar.lowerBound) <= 1,
                        "\(text): gutter moved from \(oldBar) to \(bar)")
            }
            let glyphs = try fixture.textRect(containing: text)
            #expect(bars.allSatisfy { $0.upperBound <= glyphs.minX - 2 },
                    "quote bars overlap text at \(glyphs), bars \(bars)")
        }
        let top = try fixture.row(containing: "Outer alpha").midY
        let bottom = try fixture.row(containing: "Back gamma").midY
        let oldTop = try fixture.baselineRow(containing: "Outer alpha").midY
        let oldBottom = try fixture.baselineRow(containing: "Back gamma").midY
        let barX = fixture.view.textContainerOrigin.x + 1.5
        #expect(actual.barCoverage(x: barX, from: top, to: bottom) > 0.98,
                "outer bar must stay continuous through 1→2→1 nesting")
        #expect(baseline.barCoverage(x: barX, from: oldTop, to: oldBottom) > 0.98)
        let outside = try fixture.row(containing: "Outside omega")
        #expect(actual.barRuns(at: outside.midY).isEmpty, "quote bars must stop at unquoted text")
        #expect(actual.barRuns(at: max(0, top - 60)).isEmpty, "quote bar must not leak above its block")

        // A partial repaint must keep a joining bar even when the prior
        // paragraph's text is outside the invalidated rectangle.
        let nested = try fixture.row(containing: "Nested beta")
        let partialRect = CGRect(x: 0, y: nested.minY - 3, width: 90,
                                 height: bottom - nested.minY + 6)
        let partial = try fixture.capture(rect: partialRect)
        #expect(partial.barCoverage(x: barX, from: nested.minY, to: bottom) > 0.98)
        #expect(fixture.view.textLayoutManager != nil, "bitmap capture must not downgrade TK2")
    }

    @Test("List content does not move an enclosing bar, and a quote in a list uses its own inset",
          arguments: [300.0, 600.0], [1.0, 1.5])
    func listQuotePixels(width: Double, scale: Double) async throws {
        let fixture = try await DecorationFixture(markdown: """
        > Parent quote.
        >
        > - List alpha.
        > - List beta.
        >
        > Tail quote.

        Outside separator.

        - Parent list.

          > Inset quote.

        Outside final.

        """, width: width, scale: scale)
        defer { fixture.close() }
        let actual = try fixture.capture()
        let baseline = try fixture.captureBaseline()
        for text in ["Parent quote", "List alpha", "List beta", "Tail quote", "Inset quote"] {
            let row = try fixture.row(containing: text)
            let oldRow = try fixture.baselineRow(containing: text)
            let bars = actual.barRuns(at: row.midY)
            let oldBars = baseline.barRuns(at: oldRow.midY)
            #expect(bars.count == 1, "\(text): \(bars)")
            #expect(oldBars.count == 1)
            if let bar = bars.first, let oldBar = oldBars.first {
                #expect(abs(bar.lowerBound - oldBar.lowerBound) <= 1,
                        "\(text): expected container-relative inset \(oldBar), got \(bar)")
                #expect(bar.upperBound < (try fixture.textRect(containing: text)).minX)
            }
        }
        let first = try fixture.row(containing: "Parent quote")
        let tail = try fixture.row(containing: "Tail quote")
        #expect(actual.barCoverage(x: fixture.view.textContainerOrigin.x + 1.5,
                                   from: first.midY, to: tail.midY) > 0.98)
        for text in ["Outside separator", "Parent list", "Outside final"] {
            #expect(actual.barRuns(at: try fixture.row(containing: text).midY).isEmpty)
        }
        let inset = try fixture.row(containing: "Inset quote")
        let insetBars = actual.barRuns(at: inset.midY)
        #expect((insetBars.first?.lowerBound ?? 0) > fixture.view.textContainerOrigin.x + 5,
                "the list-contained quote must use a different gutter")
    }

    @Test("Fenced code fills short and empty lines, preserves fence gaps, and leaves inline code alone",
          arguments: [300.0, 600.0], [1.0, 1.5])
    func codeBackgroundPixels(width: Double, scale: Double) async throws {
        let fixture = try await DecorationFixture(markdown: """
        Before code.

        ```
        short

        a longer code line
        ```

        ```
        second fence
        ```

        After code with `inline only`.

        """, width: width, scale: scale)
        defer { fixture.close() }
        let actual = try fixture.capture()
        let baseline = try fixture.captureBaseline()
        let right = fixture.view.bounds.width - fixture.view.textContainerInset.width - 6
        for text in ["short", "a longer code line", "second fence"] {
            #expect(actual.isCode(at: CGPoint(x: right, y: try fixture.row(containing: text).midY)),
                    "fenced background must extend past the last glyph of \(text)")
            #expect(baseline.isCode(at: CGPoint(x: right, y: try fixture.baselineRow(containing: text).midY)),
                    "the TK1 baseline fills trailing line whitespace")
        }
        let blankIndex = try fixture.index(of: "short") + "short\n".utf16.count
        let blank = try fixture.row(at: blankIndex)
        #expect(actual.codeCoverage(y: blank.midY, from: fixture.view.textContainerOrigin.x + 3, to: right) > 0.98,
                "a blank line inside a fence needs the same full-width background")
        let oldBlank = try fixture.baselineRow(at: blankIndex)
        #expect(baseline.codeCoverage(y: oldBlank.midY, from: fixture.baseline.textContainerOrigin.x + 3, to: right) > 0.98)

        let firstLast = try fixture.row(containing: "a longer code line")
        let second = try fixture.row(containing: "second fence")
        #expect(actual.hasClearCodeGap(x: right, from: firstLast.maxY, to: second.minY),
                "adjacent fences are separate blocks, including their final empty line")
        #expect(baseline.hasClearCodeGap(x: right,
                                        from: try fixture.baselineRow(containing: "a longer code line").maxY,
                                        to: try fixture.baselineRow(containing: "second fence").minY),
                "the reference keeps a clear margin between distinct fences")
        let after = try fixture.row(containing: "After code")
        #expect(!actual.isCode(at: CGPoint(x: right, y: after.midY)))
        let inline = try fixture.textRect(containing: "inline only")
        #expect(!actual.isCode(at: CGPoint(x: right, y: inline.midY)),
                "inline code must not acquire a fenced-code line fill")
        #expect(fixture.view.textLayoutManager != nil)
    }

    @Test("Quote gutters and fenced backgrounds compose without covering each other")
    func quotedCodePixels() async throws {
        let fixture = try await DecorationFixture(markdown: """
        > Before fence.
        >
        > ```
        > quoted code
        >
        > last quoted code
        > ```
        >
        > After fence.

        Outside.

        """, width: 360, scale: 1)
        defer { fixture.close() }
        let bitmap = try fixture.capture()
        let row = try fixture.row(containing: "quoted code")
        let bars = bitmap.barRuns(at: row.midY)
        #expect(bars.count == 1)
        #expect(abs((bars.first?.lowerBound ?? 0) - fixture.view.textContainerOrigin.x) <= 1)
        #expect(bitmap.isCode(at: CGPoint(x: fixture.view.bounds.width - 24, y: row.midY)))
        if let bar = bars.first {
            #expect(!bitmap.isCode(at: CGPoint(x: bar.lowerBound + 1, y: row.midY)),
                    "code fill must leave the quote gutter visible")
        }
        let before = try fixture.row(containing: "Before fence")
        let after = try fixture.row(containing: "After fence")
        #expect(bitmap.barCoverage(x: fixture.view.textContainerOrigin.x + 1.5,
                                   from: before.midY, to: after.midY) > 0.98)
    }

    @Test("Horizontal rules paint a full-width line in light and dark appearances",
          arguments: [300.0, 600.0], [false, true])
    func horizontalRulePixels(width: Double, dark: Bool) async throws {
        let fixture = try await DecorationFixture(markdown: """
        Before rules.

        ---

        Between first and second.

        ***

        Between second and third.

        ___

        After rules.

        """, width: width, scale: 1, dark: dark)
        defer { fixture.close() }
        let rows = try fixture.horizontalRuleRows()
        #expect(rows.count == 3, "all thematic-break spellings must reach the native renderer")
        try expectRulePixels(in: fixture)

        let resizedWidth = width == 300 ? 600.0 : 300.0
        await fixture.resize(to: resizedWidth)
        let resized = try fixture.horizontalRuleRows()
        #expect(resized.count == 3)
        for row in resized {
            #expect(abs(row.width - (resizedWidth - 32)) <= 1,
                    "the line must follow the available width after reflow")
        }
        try expectRulePixels(in: fixture)
        if let row = resized.first {
            let partial = try fixture.capture(rect: row.insetBy(dx: -4, dy: -3))
            #expect(partial.horizontalRuleY(in: row) != nil,
                    "a partial redraw must retain the rule")
        }
        #expect(fixture.view.textLayoutManager != nil)
    }

    @Test("Rules retain quote gutters and list indentation", arguments: [false, true])
    func nestedHorizontalRulePixels(dark: Bool) async throws {
        let fixture = try await DecorationFixture(markdown: """
        > Before quoted rule.
        >
        > ---
        >
        > After quoted rule.

        - Before list rule.

          ***

          After list rule.

        Outside.

        """, width: 360, scale: 1, dark: dark)
        defer { fixture.close() }
        let rows = try fixture.horizontalRuleRows()
        #expect(rows.count == 2)
        try expectRulePixels(in: fixture)
        let quoted = try #require(rows.first)
        let bitmap = try fixture.capture()
        let y = try #require(bitmap.horizontalRuleY(in: quoted))
        #expect(bitmap.isBar(at: CGPoint(x: fixture.view.textContainerOrigin.x + 1.5, y: y)),
                "the enclosing quote bar must coexist with its horizontal rule")
        #expect(quoted.minX > fixture.view.textContainerOrigin.x + 6,
                "a quoted rule must leave its gutter clear")
        if rows.count == 2 {
            #expect(rows[1].minX > fixture.view.textContainerOrigin.x + 6,
                    "a list-contained rule must retain the list indentation")
        }
    }

    @Test("Character-by-character rules draw without disturbing selected streamed text",
          arguments: ["---", "***", "___"])
    func streamingHorizontalRulePixels(spelling: String) async throws {
        let fixture = try await DecorationFixture(markdown: "Selected prefix.\n\n", width: 300, scale: 1,
                                                  chunkSize: 1, finish: false)
        defer { fixture.close() }
        let selection = NSRange(location: 0, length: 8)
        fixture.view.setSelectedRange(selection)
        try await fixture.append(String(spelling.prefix(2)), chunkSize: 1, finish: false)
        #expect(try fixture.horizontalRuleRows().isEmpty,
                "an incomplete delimiter must not emit a provisional rule")
        try await fixture.append(String(spelling.suffix(1)) + "\n\n", chunkSize: 1, finish: false)
        #expect(try fixture.horizontalRuleRows().count == 1)
        try expectRulePixels(in: fixture)
        let beforeAppend = fixture.view.string
        try await fixture.append("After streamed rule.\n\n", chunkSize: 1, finish: true)
        #expect(fixture.view.string.hasPrefix(beforeAppend))
        #expect(fixture.view.selectedRange() == selection)
        #expect(try fixture.horizontalRuleRows().count == 1)
        try expectRulePixels(in: fixture)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        #expect(fixture.view.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == "Selected")
        #expect(fixture.view.textLayoutManager != nil)
    }

    private func expectRulePixels(in fixture: DecorationFixture) throws {
        let bitmap = try fixture.capture()
        for row in try fixture.horizontalRuleRows() {
            let y = try #require(bitmap.horizontalRuleY(in: row),
                                 "the native bitmap must contain a full-width horizontal line at \(row)")
            #expect(!bitmap.isRule(at: CGPoint(x: row.minX - 4, y: y)), "rule paints outside its left boundary")
            #expect(!bitmap.isRule(at: CGPoint(x: row.maxX + 4, y: y)), "rule paints outside its right boundary")
            #expect(!bitmap.isRule(at: CGPoint(x: row.midX, y: row.minY - 3)))
            #expect(!bitmap.isRule(at: CGPoint(x: row.midX, y: row.maxY + 3)))
        }
    }

    @Test("Only first- and second-level headings paint a bottom border",
          arguments: [300.0, 600.0], [1.0, 1.5])
    func headingLevelPixels(width: Double, scale: Double) async throws {
        let fixture = try await DecorationFixture(markdown: """
        # First title

        Body one.

        ## Second title

        Body two.

        ### Third title

        Body three.

        #### Fourth title

        Body four.

        ##### Fifth title

        Body five.

        ###### Sixth title

        Body six.

        """, width: width, scale: scale, headingFonts: MarkdownRenderTheme.default().headingFonts)
        defer { fixture.close() }
        let bitmap = try fixture.capture()
        for (title, bordered) in [("First title", true), ("Second title", true),
                                  ("Third title", false), ("Fourth title", false),
                                  ("Fifth title", false), ("Sixth title", false)] {
            let heading = try fixture.headingParagraph(containing: title)
            let bands = bitmap.fullWidthBands(in: heading.borderSearchRect)
            #expect(bands.count == (bordered ? 1 : 0), "\(title): painted bands \(bands)")
            if bordered { try expectHeadingBorder(heading, bitmap: bitmap) }
        }
        #expect(try fixture.horizontalRuleRows().isEmpty, "heading borders must not introduce horizontal-rule attachments")
        #expect(fixture.view.textLayoutManager != nil)
    }

    @Test("A wrapped heading has one border after its final line and reflows at larger text sizes",
          arguments: [false, true], [1.0, 1.5])
    func wrappedHeadingBorderPixels(dark: Bool, scale: Double) async throws {
        let title = "A long first-level heading that wraps over several lines and still has only one bottom border"
        let fixture = try await DecorationFixture(markdown: "# \(title)\n\nFollowing body.\n\n", width: 300,
                                                  scale: scale, dark: dark,
                                                  headingFonts: MarkdownRenderTheme.default().headingFonts)
        defer { fixture.close() }
        let heading = try fixture.headingParagraph(containing: "A long first-level")
        #expect(heading.lines.count > 1)
        let bitmap = try fixture.capture()
        try expectHeadingBorder(heading, bitmap: bitmap)
        let complete = CGRect(x: heading.expectedBorder.minX, y: heading.lines[0].minY,
                              width: heading.expectedBorder.width,
                              height: heading.expectedBorder.maxY - heading.lines[0].minY + 2)
        #expect(bitmap.fullWidthBands(in: complete).count == 1,
                "wrapping must not produce a separator under every visual line")
        let body = try fixture.row(containing: "Following body")
        #expect(body.minY > heading.expectedBorder.maxY,
                "the reserved heading margin must keep the separator above following text")

        await fixture.resize(to: 600)
        let resized = try fixture.headingParagraph(containing: "A long first-level")
        #expect(resized.lines.count <= heading.lines.count)
        #expect(abs(resized.expectedBorder.width - 568) <= 1)
        try expectHeadingBorder(resized, bitmap: fixture.capture())
        let partial = try fixture.capture(rect: resized.expectedBorder.insetBy(dx: -4, dy: -3))
        #expect(partial.fullWidthBands(in: resized.borderSearchRect).count == 1)
        #expect(fixture.view.string.contains(title), "decoration must leave native heading text intact")
    }

    @Test("Heading borders respect quote and list content gutters", arguments: [false, true])
    func nestedHeadingBorderPixels(dark: Bool) async throws {
        let fixture = try await DecorationFixture(markdown: """
        > ## Quoted title
        >
        > Following quote.

        - ## List title

          Following list.

        Outside.

        """, width: 360, scale: 1, dark: dark, headingFonts: MarkdownRenderTheme.default().headingFonts)
        defer { fixture.close() }
        let bitmap = try fixture.capture()
        for title in ["Quoted title", "List title"] {
            let heading = try fixture.headingParagraph(containing: title)
            #expect(heading.expectedBorder.minX > fixture.view.textContainerOrigin.x + 6,
                    "\(title): separator must leave the quote/list gutter clear")
            try expectHeadingBorder(heading, bitmap: bitmap)
        }
        let quote = try fixture.row(containing: "Quoted title")
        #expect(bitmap.isBar(at: CGPoint(x: fixture.view.textContainerOrigin.x + 1.5, y: quote.midY)))
    }

    @Test("A terminal quoted heading keeps its gutter beside the bottom border", arguments: [false, true])
    func terminalQuotedHeadingBorderPixels(dark: Bool) async throws {
        let fixture = try await DecorationFixture(markdown: "> ## Terminal quoted title\n\nOutside.\n\n",
                                                  width: 360, scale: 1, dark: dark,
                                                  headingFonts: MarkdownRenderTheme.default().headingFonts)
        defer { fixture.close() }
        let heading = try fixture.headingParagraph(containing: "Terminal quoted title")
        let bitmap = try fixture.capture()
        try expectHeadingBorder(heading, bitmap: bitmap)
        let band = try #require(bitmap.fullWidthBands(in: heading.borderSearchRect).only)
        #expect(bitmap.isBar(at: CGPoint(x: fixture.view.textContainerOrigin.x + 1.5,
                                        y: (band.lowerBound + band.upperBound) / 2)),
                "the quote gutter must extend alongside its heading's separator")
    }

    @Test("Streaming past a decorated heading preserves native text selection and copying")
    func streamingHeadingBorderPixels() async throws {
        let fixture = try await DecorationFixture(markdown: "Selected prefix.\n\n", width: 300, scale: 1,
                                                  chunkSize: 1, finish: false,
                                                  headingFonts: MarkdownRenderTheme.default().headingFonts)
        defer { fixture.close() }
        let selection = NSRange(location: 0, length: 8)
        fixture.view.setSelectedRange(selection)
        try await fixture.append("## Streamed title\n\n", chunkSize: 1, finish: false)
        try expectHeadingBorder(fixture.headingParagraph(containing: "Streamed title"), bitmap: fixture.capture())
        let prefix = fixture.view.string
        try await fixture.append("Following streamed body.\n\n", chunkSize: 1, finish: true)
        #expect(fixture.view.string.hasPrefix(prefix))
        #expect(fixture.view.selectedRange() == selection)
        try expectHeadingBorder(fixture.headingParagraph(containing: "Streamed title"), bitmap: fixture.capture())
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        #expect(fixture.view.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == "Selected")
        #expect(fixture.view.textLayoutManager != nil)
    }

    private func expectHeadingBorder(_ heading: HeadingParagraph, bitmap: DecorationBitmap) throws {
        let band = try #require(bitmap.fullWidthBands(in: heading.borderSearchRect).only,
                                "expected one painted heading separator at \(heading.expectedBorder)")
        #expect(abs(band.lowerBound - heading.expectedBorder.minY) <= 1)
        #expect(band.upperBound - band.lowerBound <= 2, "heading border must remain a hairline")
        #expect(!bitmap.isHeadingBorder(at: CGPoint(x: heading.expectedBorder.minX - 4, y: band.lowerBound)))
        #expect(!bitmap.isHeadingBorder(at: CGPoint(x: heading.expectedBorder.maxX + 4, y: band.lowerBound)))
    }

    @Test("Appending a nested quote repaints the earlier paragraph's joining gutter", arguments: [1, 17])
    func streamingQuotePixels(chunkSize: Int) async throws {
        let fixture = try await DecorationFixture(markdown: "> First streamed paragraph.\n>\n", width: 300, scale: 1,
                                                  chunkSize: chunkSize, finish: false)
        defer { fixture.close() }
        _ = try fixture.capture()
        try await fixture.append("> > Nested streamed paragraph.\n>\n> Final streamed paragraph.\n\nOutside.\n\n",
                                 chunkSize: chunkSize, finish: true)
        let bitmap = try fixture.capture()
        let top = try fixture.row(containing: "First streamed paragraph").midY
        let bottom = try fixture.row(containing: "Final streamed paragraph").midY
        #expect(bitmap.barCoverage(x: fixture.view.textContainerOrigin.x + 1.5, from: top, to: bottom) > 0.98)
        #expect(bitmap.barRuns(at: try fixture.row(containing: "Nested streamed paragraph").midY).count == 2)
        #expect(bitmap.barRuns(at: try fixture.row(containing: "Outside").midY).isEmpty)
    }
}

@MainActor
private final class DecorationFixture {
    let controller = TextKitStreamingController()
    let view: NSTextView
    let baseline: NSTextView
    let pipeline: MarkdownStreamingPipeline
    private let window: NSWindow
    private let oldWindow: NSWindow
    private let configuration: PicoTextKitConfiguration

    init(markdown: String, width: Double, scale: Double, chunkSize: Int = 11, finish: Bool = true,
         dark: Bool = false, headingFonts: [Int: FontSpec] = [:]) async throws {
        _ = NSApplication.shared
        configuration = PicoTextKitConfiguration(backgroundColor: dark ? .black : .white,
            contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
        let font = FontSpec(size: 15)
        let theme = MarkdownRenderTheme(bodyFont: font, codeFont: font,
            blockquoteColor: ThemeColor(.init(red: 1, green: 0, blue: 1)), linkColor: .link,
            headingFonts: headingFonts, codeBlockTheme: CodeBlockTheme(font: font,
                foregroundColor: ThemeColor(.init(red: 0, green: 0, blue: 0)),
                backgroundColor: ThemeColor(.init(red: 0, green: 0.8, blue: 0.8))),
            codeHighlighter: AnyCodeSyntaxHighlighter(PlainCodeSyntaxHighlighter())).scaled(by: scale)
        pipeline = MarkdownStreamingPipeline(theme: theme)
        view = controller.makeTextKit2View(configuration: configuration)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 1400)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.drawsBackground = true
        view.usesAdaptiveColorMappingForDarkAppearance = false
        window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view

        let storage = NSTextStorage()
        let manager = FrozenMainBlockquoteLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width - 32, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        baseline = NSTextView(frame: view.frame, textContainer: container)
        baseline.textContainerInset = NSSize(width: 16, height: 16)
        baseline.backgroundColor = dark ? .black : .white
        baseline.drawsBackground = true
        baseline.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        baseline.usesAdaptiveColorMappingForDarkAppearance = false
        baseline.isEditable = false
        oldWindow = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        oldWindow.isReleasedWhenClosed = false
        oldWindow.contentView = baseline
        try await append(markdown, chunkSize: chunkSize, finish: finish)
    }

    func append(_ markdown: String, chunkSize: Int, finish: Bool) async throws {
        var start = markdown.startIndex
        while start < markdown.endIndex {
            let end = markdown.index(start, offsetBy: chunkSize, limitedBy: markdown.endIndex) ?? markdown.endIndex
            apply(await pipeline.feed(String(markdown[start..<end])))
            start = end
        }
        if finish { apply(await pipeline.finish()) }
        let storage = try #require(view.textStorage)
        baseline.textStorage?.setAttributedString(storage)
        await settleLayout()
    }

    func resize(to width: Double) async {
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
        await settleLayout()
    }

    func horizontalRuleRows() throws -> [CGRect] {
        let storage = try #require(view.textStorage)
        var indexes: [Int] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value is MacHorizontalRuleAttachment { indexes.append(range.location) }
        }
        return try indexes.map { try row(at: $0) }
    }

    func headingParagraph(containing text: String) throws -> HeadingParagraph {
        let manager = try #require(view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: index(of: text)))
        let fragment = try #require(manager.textLayoutFragment(for: location))
        let paragraph = try #require(fragment.textElement as? NSTextParagraph)
        let attributes = paragraph.attributedString.attributes(at: paragraph.attributedString.length - 1, effectiveRange: nil)
        let style = try #require(attributes[.paragraphStyle] as? NSParagraphStyle)
        let font = try #require(attributes[.font] as? NSFont)
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }.map {
            $0.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x,
                                          dy: fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y)
        }
        let last = try #require(lines.last)
        let left = max(0, style.headIndent, style.firstLineHeadIndent)
        let container = try #require(view.textContainer)
        let right = style.tailIndent > 0 ? style.tailIndent : container.size.width + style.tailIndent
        return HeadingParagraph(lines: lines,
            expectedBorder: CGRect(x: view.textContainerOrigin.x + left, y: last.maxY + font.pointSize * 0.3,
                                   width: right - left, height: 1))
    }

    private func settleLayout() async {
        for _ in 0..<3 {
            if let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
            }
            view.layoutSubtreeIfNeeded()
            baseline.layoutManager?.ensureLayout(for: baseline.textContainer!)
            baseline.layoutSubtreeIfNeeded()
            await Task.yield()
        }
    }

    private func apply(_ update: StreamingUpdate?) {
        guard let update else { return }
        controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                          replaceToken: 1, configuration: configuration)
        // Keep the fixture's fixed pixel colors; the controller enables
        // adaptive mapping for normal application content on every update.
        view.usesAdaptiveColorMappingForDarkAppearance = false
    }

    func close() { window.close(); oldWindow.close() }

    func index(of text: String) throws -> Int {
        let range = ((view.string) as NSString).range(of: text)
        return try #require(range.location == NSNotFound ? nil : range.location, "missing fixture text: \(text)")
    }

    func row(containing text: String) throws -> CGRect { try row(at: index(of: text)) }
    func baselineRow(containing text: String) throws -> CGRect { try baselineRow(at: index(of: text)) }

    func row(at index: Int) throws -> CGRect {
        let manager = try #require(view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: index))
        let fragment = try #require(manager.textLayoutFragment(for: location))
        let line = try #require(fragment.textLineFragment(for: location, isUpstreamAffinity: false))
        return line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x,
                                               dy: fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y)
    }

    func baselineRow(at index: Int) throws -> CGRect {
        let manager = try #require(baseline.layoutManager)
        let glyph = manager.glyphIndexForCharacter(at: index)
        return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            .offsetBy(dx: baseline.textContainerOrigin.x, dy: baseline.textContainerOrigin.y)
    }

    func textRect(containing text: String) throws -> CGRect {
        let manager = try #require(view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let start = try #require(content.location(content.documentRange.location, offsetBy: index(of: text)))
        let end = try #require(content.location(start, offsetBy: text.utf16.count))
        let range = try #require(NSTextRange(location: start, end: end))
        var result = CGRect.null
        manager.enumerateTextSegments(in: range, type: .standard, options: []) { _, rect, _, _ in
            result = result.union(rect)
            return true
        }
        #expect(!result.isNull)
        return result.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    }

    func capture(rect: CGRect? = nil) throws -> DecorationBitmap { try bitmap(of: view, rect: rect) }
    func captureBaseline() throws -> DecorationBitmap { try bitmap(of: baseline, rect: nil) }

    private func bitmap(of target: NSTextView, rect requested: CGRect?) throws -> DecorationBitmap {
        let rect = requested ?? CGRect(x: 0, y: 0, width: target.bounds.width, height: min(1200, target.bounds.height))
        let representation = try #require(target.bitmapImageRepForCachingDisplay(in: rect))
        target.effectiveAppearance.performAsCurrentDrawingAppearance {
            target.cacheDisplay(in: rect, to: representation)
        }
        return DecorationBitmap(representation: representation, rect: rect)
    }
}

private struct DecorationBitmap {
    let representation: NSBitmapImageRep
    let rect: CGRect

    func color(at point: CGPoint) -> NSColor? {
        guard rect.contains(point) else { return nil }
        let x = Int((point.x - rect.minX) * CGFloat(representation.pixelsWide) / rect.width)
        let y = Int((point.y - rect.minY) * CGFloat(representation.pixelsHigh) / rect.height)
        return representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }
    func isBar(at point: CGPoint) -> Bool {
        guard let color = color(at: point) else { return false }
        // The quote theme uses translucent magenta. Its chroma remains
        // distinct against both the fixture's white and black backgrounds.
        return color.redComponent - color.greenComponent > 0.2
            && color.blueComponent - color.greenComponent > 0.2
    }
    func isRule(at point: CGPoint) -> Bool {
        isGrayLine(at: point, minimumContrast: 0.12)
    }
    func isHeadingBorder(at point: CGPoint) -> Bool {
        // separatorColor is deliberately subtler than a horizontal rule: on
        // the native light bitmap its fully painted pixel is ~0.92 on white.
        isGrayLine(at: point, minimumContrast: 0.03)
    }
    private func isGrayLine(at point: CGPoint, minimumContrast: CGFloat) -> Bool {
        guard let sample = color(at: point), let background = color(at: CGPoint(x: rect.minX + 1, y: rect.minY + 1)) else { return false }
        let components = [sample.redComponent, sample.greenComponent, sample.blueComponent]
        let gray = components.reduce(0, +) / 3
        let backgroundGray = (background.redComponent + background.greenComponent + background.blueComponent) / 3
        return (components.max()! - components.min()!) < 0.12 && abs(gray - backgroundGray) > minimumContrast
    }
    func horizontalRuleY(in row: CGRect) -> CGFloat? {
        stride(from: row.minY, through: row.maxY, by: 0.5).first { y in
            coverage(from: row.minX + 3, to: row.maxX - 3) { isRule(at: CGPoint(x: $0, y: y)) } > 0.98
        }
    }
    func fullWidthBands(in region: CGRect) -> [ClosedRange<CGFloat>] {
        var bands: [ClosedRange<CGFloat>] = []
        var start: CGFloat?
        var previous: CGFloat = region.minY
        for y in stride(from: region.minY, through: region.maxY, by: 0.5) {
            let painted = coverage(from: region.minX + 3, to: region.maxX - 3) { isHeadingBorder(at: CGPoint(x: $0, y: y)) } > 0.98
            if painted { if start == nil { start = y } }
            else if let first = start { bands.append(first...previous); start = nil }
            previous = y
        }
        if let start { bands.append(start...previous) }
        return bands
    }
    func isCode(at point: CGPoint) -> Bool {
        guard let color = color(at: point) else { return false }
        // Compare chroma rather than exact RGB; the bitmap uses the display's
        // color profile even when the test's source color is calibrated cyan.
        return color.greenComponent - color.redComponent > 0.2
            && color.blueComponent - color.redComponent > 0.2
    }
    func barRuns(at y: CGFloat) -> [Range<CGFloat>] {
        var result: [Range<CGFloat>] = []
        var start: CGFloat?
        for step in 0...Int(min(180, rect.maxX) * 2) {
            let x = CGFloat(step) / 2
            if isBar(at: CGPoint(x: x, y: y)) { if start == nil { start = x } }
            else if let current = start { result.append(current..<x); start = nil }
        }
        if let start { result.append(start..<min(180, rect.maxX)) }
        return result
    }
    func barCoverage(x: CGFloat, from start: CGFloat, to end: CGFloat) -> Double {
        coverage(from: start, to: end) { isBar(at: CGPoint(x: x, y: $0)) }
    }
    func codeCoverage(y: CGFloat, from start: CGFloat, to end: CGFloat) -> Double {
        coverage(from: start, to: end) { isCode(at: CGPoint(x: $0, y: y)) }
    }
    func hasClearCodeGap(x: CGFloat, from start: CGFloat, to end: CGFloat) -> Bool {
        guard end > start + 2 else { return false }
        return stride(from: start + 1, to: end - 1, by: 0.5).contains { !isCode(at: CGPoint(x: x, y: $0)) }
    }
    private func coverage(from start: CGFloat, to end: CGFloat, matching predicate: (CGFloat) -> Bool) -> Double {
        guard end > start else { return 0 }
        let samples = Array(stride(from: start, through: end, by: 0.5))
        return Double(samples.filter(predicate).count) / Double(samples.count)
    }
}

private struct HeadingParagraph {
    let lines: [CGRect]
    let expectedBorder: CGRect
    var borderSearchRect: CGRect { expectedBorder.insetBy(dx: 0, dy: -2) }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

/// Frozen from main's BlockquoteBarLayoutManager. Production TK2 code must not
/// call any of these legacy APIs; they are used solely for differential tests.
@MainActor
private final class FrozenMainBlockquoteLayoutManager: NSLayoutManager {
    private struct Segment { let level: Int; let color: NSColor; let inset: CGFloat; let range: NSRange; var rect: CGRect }
    override func drawBackground(forGlyphRange glyphs: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphs, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var start = min(chars.location, storage.length - 1)
        if start > 0 {
            var effective = NSRange()
            _ = storage.attribute(.picoBlockquoteLevel, at: start - 1, effectiveRange: &effective)
            if effective.length > 0 { start = effective.location }
        }
        var end = min(chars.upperBound, storage.length)
        if end < storage.length {
            var effective = NSRange()
            _ = storage.attribute(.picoBlockquoteLevel, at: end, effectiveRange: &effective)
            if effective.length > 0 { end = max(end, effective.upperBound) }
        }
        guard end > start else { return }
        var segments: [Segment] = []
        storage.enumerateAttribute(.picoBlockquoteLevel, in: NSRange(location: start, length: end - start)) { value, levels, _ in
            guard let level = value as? Int, level > 0 else { return }
            storage.enumerateAttribute(.picoBlockquoteBarInset, in: levels) { value, range, _ in
                let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                guard glyphRange.length > 0, let container = self.textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil) else { return }
                let inset = value as? CGFloat ?? 0
                var rect = self.boundingRect(forGlyphRange: glyphRange, in: container)
                rect.origin.x = origin.x + inset
                rect.origin.y += origin.y
                let color = storage.attribute(.picoBlockquoteBarColor, at: range.location, effectiveRange: nil) as? NSColor ?? .separatorColor
                segments.append(Segment(level: level, color: color, inset: inset, range: range, rect: rect))
            }
        }
        for (index, segment) in segments.enumerated() {
            let next = index + 1 < segments.count ? segments[index + 1] : nil
            let joins = next.map { segment.range.upperBound == $0.range.location && segment.inset == $0.inset } ?? false
            for bar in 0..<segment.level {
                let bottom = next.map { joins && $0.level > bar ? max(segment.rect.maxY, $0.rect.minY) : segment.rect.maxY } ?? segment.rect.maxY
                segment.color.setFill()
                NSBezierPath(rect: CGRect(x: segment.rect.minX + CGFloat(bar) * 12, y: segment.rect.minY,
                                         width: 3, height: bottom - segment.rect.minY)).fill()
            }
        }
    }
}
#endif
