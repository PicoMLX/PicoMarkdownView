#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS native code block copying")
@MainActor
struct MacCodeBlockCopyTests {
    @Test("Copy preserves verbatim source and selection while the same fence streams")
    func streamingCopyUsesTheLatestBody() async throws {
        let fixture = CodeCopyFixture()
        defer { fixture.close() }
        let firstBody = " \tlet café = \"🧭\"\n"
        await fixture.feed("Before paragraph.\n\n```swift\n" + firstBody)
        let block = try #require(fixture.blocks.first { $0.codeBlock != nil })
        let firstButton = try #require(fixture.view.codeBlockCopyControls.buttons[block.id])
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        fixture.view.setSelectedRange(NSRange(location: 0, length: "Before".utf16.count))
        let selection = fixture.view.selectedRange()
        let textBeforeCopy = fixture.view.string
        #expect(firstButton.copy(to: board))
        #expect(board.string(forType: .string) == firstBody)
        #expect(fixture.view.selectedRange() == selection)
        #expect(fixture.view.string == textBeforeCopy)

        let secondBody = "\n  print(café)  \n"
        await fixture.feed(secondBody)
        let streamingButton = try #require(fixture.view.codeBlockCopyControls.buttons[block.id])
        #expect(streamingButton === firstButton, "Appending code must not recreate the control")
        #expect(streamingButton.copy(to: board))
        #expect(board.string(forType: .string) == firstBody + secondBody)
        #expect(fixture.backend.codeBlockForCopy(id: block.id)?.code == firstBody + secondBody)
        #expect(fixture.view.selectedRange() == selection)

        await fixture.feed("```\n\nAfter paragraph.\n\n")
        await fixture.finish()
        let closedButton = try #require(fixture.view.codeBlockCopyControls.buttons[block.id])
        #expect(closedButton === firstButton)
        #expect(closedButton.copy(to: board))
        #expect(board.string(forType: .string) == firstBody + secondBody,
                "Copy excludes the fence, language, and synthetic display suffix newline")
        let storage = try #require(fixture.view.textStorage)
        let range = try #require(fixture.backend.codeBlockRangeForCopy(id: block.id))
        #expect(storage.attributedSubstring(from: range).string == firstBody + secondBody + "\n")
        #expect(!storage.string.contains("\u{FFFC}"), "Code must remain native selectable text")
        fixture.view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let selectedText = fixture.view.markdownForSelection()
        #expect(selectedText.contains("Before paragraph."))
        #expect(selectedText.contains(firstBody + secondBody))
        #expect(selectedText.contains("After paragraph."))
        #expect(fixture.view.textLayoutManager != nil)
    }

    @Test("Copy supports transparent and unthemed fences, indented code and empty fences",
          arguments: [false, true])
    func copyDoesNotDependOnBackground(hasTransparentTheme: Bool) async throws {
        let defaults = MarkdownRenderTheme.default()
        let codeTheme: CodeBlockTheme? = hasTransparentTheme
            ? CodeBlockTheme(font: FontSpec(size: 15), foregroundColor: .label, backgroundColor: .clear)
            : nil
        let theme = defaults.withCodeHighlighting(codeBlockTheme: codeTheme, codeHighlighter: nil)
        let fixture = CodeCopyFixture(theme: theme)
        defer { fixture.close() }
        await fixture.feed("""
        ```unknown-language
        unknown code
        ```

        Between blocks.

            indented code

        ```
        ```

        """)
        await fixture.finish()
        let blocks = fixture.blocks.filter { $0.codeBlock != nil }
        try #require(blocks.count == 3)
        #expect(fixture.view.codeBlockCopyControls.buttons.count == 3)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        for block in blocks {
            let button = try #require(fixture.view.codeBlockCopyControls.buttons[block.id])
            let code = try #require(block.codeBlock)
            #expect(fixture.backend.codeBlockForCopy(id: block.id)?.code == code.code)
            let range = try #require(fixture.backend.codeBlockRangeForCopy(id: block.id))
            let storage = try #require(fixture.view.textStorage)
            #expect(storage.attribute(.picoCodeBlockCopyID, at: range.location, effectiveRange: nil) != nil)
            #expect(storage.attribute(.picoCodeBlockBackgroundColor, at: range.location, effectiveRange: nil) == nil)
            if !code.code.isEmpty {
                #expect(button.copy(to: board))
                #expect(board.string(forType: .string) == code.code)
            }
        }
        #expect(blocks.contains { $0.codeBlock?.code == "" })
    }

    @Test("Copy controls occupy their own header in wrapped quotes and lists",
          arguments: [150.0, 420.0])
    func headerKeepsControlsOutOfSelectableCode(width: Double) async throws {
        let fixture = CodeCopyFixture(width: width)
        defer { fixture.close() }
        await fixture.feed("""
        > ```text
        > very long quoted code with many words that wrap within the native text container
        > next quoted line
        > ```

        - List parent.

          ```text
          list code
          ```

        """)
        await fixture.finish()
        let codeBlocks = fixture.blocks.filter { $0.codeBlock != nil }
        try #require(codeBlocks.count == 2)
        for block in codeBlocks {
            try assertHeaderGeometry(block: block, fixture: fixture)
        }
        let resized = NSSize(width: width + 170, height: fixture.view.frame.height)
        fixture.window.setContentSize(resized)
        fixture.view.setFrameSize(resized)
        await fixture.settleLayout()
        for block in codeBlocks {
            try assertHeaderGeometry(block: block, fixture: fixture)
        }
        #expect(fixture.view.textLayoutManager != nil)
    }

    @Test("Hidden controls do not capture selection and provide native accessibility information")
    func hoverAndAccessibility() async throws {
        let fixture = CodeCopyFixture()
        defer { fixture.close() }
        await fixture.feed("```text\nfirst line\nsecond line\n```\n\n")
        await fixture.finish()
        let block = try #require(fixture.blocks.first { $0.codeBlock != nil })
        let button = try #require(fixture.view.codeBlockCopyControls.buttons[block.id])
        fixture.view.codeBlockCopyControls.updateHover(at: nil)
        #expect(button.alphaValue == 0)
        #expect(button.hitTest(button.frame.center) == nil)
        #expect(button.accessibilityLabel() == "Copy code")
        #expect(!(button.accessibilityHelp() ?? "").isEmpty)
        #expect(!(button.toolTip ?? "").isEmpty)
        #expect(button.action != nil)
        #expect(button.target != nil)
        let accessibleButtons = (fixture.view.accessibilityChildren() ?? []).compactMap { $0 as? NSButton }
        #expect(accessibleButtons.filter { $0 === button }.count == 1,
                "The native text view must expose its Copy control exactly once to accessibility")
        let point = try fixture.glyphRect(containing: "second line").center
        fixture.view.codeBlockCopyControls.updateHover(at: point)
        #expect(button.alphaValue == 1, "Hovering later code lines also reveals the header control")
        #expect(button.hitTest(button.frame.center) === button)
        fixture.view.codeBlockCopyControls.updateHover(at: nil)
        #expect(button.alphaValue == 0)
        try #require(fixture.window.makeFirstResponder(button))
        #expect(fixture.window.firstResponder === button)
        #expect(button.alphaValue == 1, "Keyboard focus must reveal an otherwise hidden control")
        try #require(fixture.window.makeFirstResponder(fixture.view))
        #expect(button.alphaValue == 0)
        button.setAccessibilityFocused(true)
        #expect(button.alphaValue == 1, "Accessibility focus must also reveal the control")
        button.setAccessibilityFocused(false)
        // AppKit may also move keyboard focus when accessibility focuses a control.
        try #require(fixture.window.makeFirstResponder(fixture.view))
        #expect(button.alphaValue == 0)
    }

    @Test("Retention and document replacement retire stale controls, including reused block IDs")
    func staleControlsCannotCopyAnotherDocument() async throws {
        let fixture = CodeCopyFixture()
        defer { fixture.close() }
        await fixture.feed("```text\nold code\n```\n\nRetained paragraph.\n\n")
        await fixture.finish()
        let block = try #require(fixture.blocks.first { $0.codeBlock != nil })
        let oldButton = try #require(fixture.view.codeBlockCopyControls.buttons[block.id])
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let retained = fixture.blocks.filter { $0.id != block.id }
        _ = fixture.backend.apply(blocks: retained, selection: NSRange(location: 0, length: 0))
        await fixture.settleLayout()
        #expect(fixture.view.codeBlockCopyControls.buttons[block.id] == nil)
        #expect(fixture.backend.codeBlockForCopy(id: block.id) == nil)
        #expect(!oldButton.copy(to: board))

        _ = fixture.backend.apply(blocks: fixture.blocks, selection: NSRange(location: 0, length: 0))
        await fixture.settleLayout()
        let activeBeforeReset = try #require(fixture.view.codeBlockCopyControls.buttons[block.id])
        #expect(activeBeforeReset !== oldButton)
        let replacement = MarkdownStreamingPipeline()
        guard let update = await replacement.feed("```text\nnew document code\n```\n\n") else {
            Issue.record("Expected replacement document update")
            return
        }
        let replacementBlock = try #require(update.blocks.first { $0.codeBlock != nil })
        #expect(replacementBlock.id == block.id, "Fresh tokenizer IDs exercise a recycled ID")
        fixture.backend.resetDocumentOnNextApply()
        _ = fixture.backend.apply(blocks: update.blocks, selection: NSRange(location: 0, length: 0))
        await fixture.settleLayout()
        let newButton = try #require(fixture.view.codeBlockCopyControls.buttons[replacementBlock.id])
        #expect(newButton !== oldButton)
        #expect(newButton !== activeBeforeReset)
        #expect(!oldButton.copy(to: board))
        #expect(!activeBeforeReset.copy(to: board), "Reset must retire an active control before IDs are reused")
        #expect(newButton.copy(to: board))
        #expect(board.string(forType: .string) == replacementBlock.codeBlock?.code)
    }

    @Test("Scrolling updates controls for newly visible code headers without a text edit")
    func scrollChangesVisibleControls() async throws {
        let fixture = CodeCopyFixture()
        defer { fixture.close() }
        let filler = String(repeating: "Filler paragraph between distant code blocks.\n\n", count: 24)
        await fixture.feed("```text\nfirst code\n```\n\n" + filler + "```text\nlast code\n```\n\n")
        await fixture.finish()
        let blocks = fixture.blocks.filter { $0.codeBlock != nil }
        try #require(blocks.count == 2)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 220))
        scroll.hasVerticalScroller = true
        fixture.window.contentView = scroll
        fixture.window.setContentSize(NSSize(width: 620, height: 220))
        scroll.documentView = fixture.view
        await fixture.settleLayout()
        #expect(fixture.view.codeBlockCopyControls.buttons[blocks[0].id] != nil)
        #expect(fixture.view.codeBlockCopyControls.buttons[blocks[1].id] == nil)
        let range = try #require(fixture.backend.codeBlockRangeForCopy(id: blocks[1].id))
        let fragment = try fixture.fragment(at: range.location)
        let localHeader = try #require(MacCodeBlockCopy.toolbarRect(for: fragment))
        let header = localHeader.offsetBy(dx: fragment.layoutFragmentFrame.minX + fixture.view.textContainerOrigin.x,
                                          dy: fragment.layoutFragmentFrame.minY + fixture.view.textContainerOrigin.y)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: header.minY - 8))
        scroll.reflectScrolledClipView(scroll.contentView)
        fixture.view.displayIfNeeded()
        await Task.yield()
        #expect(fixture.view.visibleRect.contains(header.center), "The second header really entered the clip viewport")
        #expect(fixture.view.codeBlockCopyControls.buttons[blocks[1].id] != nil,
                "Scrolling alone must install the newly visible header control")
        #expect(fixture.view.codeBlockCopyControls.buttons[blocks[0].id] == nil,
                "Offscreen controls should be retired without another source update")
        #expect(fixture.view.textLayoutManager != nil)
    }

    @Test("Outer scroll notifications refresh controls with a stale text viewport")
    func outerScrollNotificationsRefreshControls() async throws {
        let fixture = CodeCopyFixture()
        defer { fixture.close() }
        let filler = String(repeating: "Filler paragraph between distant code blocks.\n\n", count: 24)
        await fixture.feed("```text\nfirst code\n```\n\n" + filler + "```text\nlast code\n```\n\n")
        await fixture.finish()
        let blocks = fixture.blocks.filter { $0.codeBlock != nil }
        try #require(blocks.count == 2)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 220))
        scroll.hasVerticalScroller = true
        let document = CodeCopyFlippedDocumentView(frame: fixture.view.frame)
        fixture.window.contentView = scroll
        fixture.window.setContentSize(NSSize(width: 620, height: 220))
        document.addSubview(fixture.view)
        scroll.documentView = document
        await fixture.settleLayout()
        try #require(scroll.documentView !== fixture.view,
                     "The outer scroll view must not own the text view directly")
        try #require(fixture.view.enclosingScrollView === scroll)
        #expect(fixture.view.codeBlockCopyControls.buttons[blocks[0].id] != nil)
        #expect(fixture.view.codeBlockCopyControls.buttons[blocks[1].id] == nil)
        let range = try #require(fixture.backend.codeBlockRangeForCopy(id: blocks[1].id))
        let fragment = try fixture.fragment(at: range.location)
        let localHeader = try #require(MacCodeBlockCopy.toolbarRect(for: fragment))
        let header = localHeader.offsetBy(dx: fragment.layoutFragmentFrame.minX + fixture.view.textContainerOrigin.x,
                                          dy: fragment.layoutFragmentFrame.minY + fixture.view.textContainerOrigin.y)
        let manager = try #require(fixture.view.textLayoutManager)
        let initialViewport = try #require(manager.textViewportLayoutController.viewportRange)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: header.minY - 8))
        scroll.reflectScrolledClipView(scroll.contentView)
        // NSClipView does not promise observer delivery before scroll(to:) returns.
        // Post explicitly to test the registered handler against real, stale-viewport geometry.
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        #expect(fixture.view.visibleRect.contains(header.center))
        #expect(fixture.view.codeBlockCopyControls.buttons[blocks[1].id] != nil,
                "The clip-bounds notification alone must install the newly visible Copy button")
        #expect(fixture.view.codeBlockCopyControls.buttons[blocks[0].id] == nil)
        let cachedAfterScroll = try #require(manager.textViewportLayoutController.viewportRange)
        #expect(cachedAfterScroll.location.compare(initialViewport.location) == .orderedSame,
                "This exercises the stale text viewport before any display or layout turn")

        // Advance only TextKit's cached viewport, then exercise scrolling back
        // before another display, layout pass, task yield, or explicit toolbar refresh.
        manager.textViewportLayoutController.layoutViewport()
        let lowerViewport = try #require(manager.textViewportLayoutController.viewportRange)
        try #require(lowerViewport.location.compare(initialViewport.location) == .orderedDescending,
                     "The cached text viewport must now begin below the first code header")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        #expect(fixture.view.codeBlockCopyControls.buttons[blocks[0].id] != nil,
                "Scrolling back must not enumerate from the stale lower text viewport")
        #expect(fixture.view.codeBlockCopyControls.buttons[blocks[1].id] == nil)
        let cachedAfterReturn = try #require(manager.textViewportLayoutController.viewportRange)
        #expect(cachedAfterReturn.location.compare(lowerViewport.location) == .orderedSame)
        #expect(fixture.view.textLayoutManager != nil)
    }

    @Test("Hosted Mermaid keeps its own toolbar without a second native-code control")
    func hostedDiagramsDoNotGetCodeControls() async throws {
        let fixture = CodeCopyFixture(mermaidProvider: CodeCopyVectorProvider())
        defer { fixture.close() }
        await fixture.feed("```mermaid\nflowchart LR\nA --> B\n```\n\n```text\nordinary code\n```\n\n")
        await fixture.finish()
        let diagram = try #require(fixture.blocks.first { $0.mermaidDiagram?.svg != nil })
        let code = try #require(fixture.blocks.first { $0.codeBlock != nil && $0.mermaidDiagram == nil })
        #expect(fixture.backend.hostedAttachment(for: diagram.id) != nil)
        #expect(fixture.backend.codeBlockForCopy(id: diagram.id) == nil)
        #expect(fixture.backend.codeBlockRangeForCopy(id: diagram.id) == nil)
        #expect(fixture.view.codeBlockCopyControls.buttons[diagram.id] == nil)
        #expect(fixture.view.codeBlockCopyControls.buttons[code.id] != nil)
        #expect(fixture.view.codeBlockCopyControls.buttons.count == 1)
    }

    private func assertHeaderGeometry(block: RenderedBlock, fixture: CodeCopyFixture) throws {
        let range = try #require(fixture.backend.codeBlockRangeForCopy(id: block.id))
        let fragment = try fixture.fragment(at: range.location)
        let header = try #require(MacCodeBlockCopy.toolbarRect(for: fragment))
            .offsetBy(dx: fragment.layoutFragmentFrame.minX + fixture.view.textContainerOrigin.x,
                      dy: fragment.layoutFragmentFrame.minY + fixture.view.textContainerOrigin.y)
        let firstLine = try #require(fragment.textLineFragments.first { $0.characterRange.length > 0 })
        let codeTop = firstLine.typographicBounds.minY + fragment.layoutFragmentFrame.minY + fixture.view.textContainerOrigin.y
        let button = try #require(fixture.view.codeBlockCopyControls.buttons[block.id])
        #expect(header.contains(button.frame), "The button stays within its indented code header")
        #expect(button.frame.maxY <= codeTop, "Copy must not cover selectable code, including wrapped first lines")
        #expect(header.height == MacCodeBlockCopy.toolbarHeight)
        let storage = try #require(fixture.view.textStorage)
        let firstParagraph = (storage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0))
        let nextParagraph = NSMaxRange(firstParagraph)
        if nextParagraph < NSMaxRange(range) {
            #expect(storage.attribute(.picoCodeBlockToolbarHeight, at: nextParagraph, effectiveRange: nil) == nil,
                    "Only the first native paragraph reserves a toolbar")
        }
    }
}

@MainActor
private final class CodeCopyFixture {
    let backend = TextKitStreamingBackend()
    let pipeline: MarkdownStreamingPipeline
    let view: StreamingTextKit2View
    let window: NSWindow
    private(set) var blocks: [RenderedBlock] = []

    init(theme: MarkdownRenderTheme = .default(), width: Double = 620,
         mermaidProvider: (any MermaidDiagramProvider)? = nil) {
        _ = NSApplication.shared
        pipeline = MarkdownStreamingPipeline(theme: theme, mermaidProvider: mermaidProvider)
        view = StreamingTextKit2View(backend: backend)
        view.frame = CGRect(x: 0, y: 0, width: width, height: 1600)
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.textContainer?.lineFragmentPadding = 0
        view.isSelectable = true
        view.isVerticallyResizable = false
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
    }

    func feed(_ text: String) async {
        apply(await pipeline.feed(text))
        await settleLayout()
    }

    func finish() async {
        apply(await pipeline.finish())
        await settleLayout()
    }

    private func apply(_ update: StreamingUpdate?) {
        guard let update else { return }
        blocks = update.blocks
        let selection = backend.apply(blocks: update.blocks, diffs: [update.diff], selection: view.selectedRange())
        view.setSelectedRange(selection)
    }

    func settleLayout() async {
        for _ in 0..<3 {
            if let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
            }
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        view.codeBlockCopyControls.updateLayout()
    }

    func fragment(at index: Int) throws -> NSTextLayoutFragment {
        let manager = try #require(view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: index))
        return try #require(manager.textLayoutFragment(for: location))
    }

    func glyphRect(containing text: String) throws -> CGRect {
        let range = (view.string as NSString).range(of: text)
        try #require(range.location != NSNotFound)
        let fragment = try fragment(at: range.location)
        let line = try #require(fragment.textLineFragments.first { $0.characterRange.length > 0 })
        return line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x,
                                               dy: fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y)
    }

    func close() { window.close() }
}

@MainActor
private final class CodeCopyFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private actor CodeCopyVectorProvider: MermaidVectorDiagramProvider {
    func renderVector(_ request: MermaidRenderRequest) async -> MermaidVectorRenderResult? {
        MermaidVectorRenderResult(svg: "<svg width=\"200\" height=\"100\"><rect width=\"200\" height=\"100\"/></svg>",
                                  intrinsicSize: CGSize(width: 200, height: 100))
    }

    func render(_ request: MermaidRenderRequest) async -> MermaidRenderResult? { nil }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
#endif
