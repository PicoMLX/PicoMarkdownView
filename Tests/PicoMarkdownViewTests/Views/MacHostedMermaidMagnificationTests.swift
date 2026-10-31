#if os(macOS) && canImport(JavaScriptCore)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS hosted Mermaid magnification routing")
@MainActor
struct MacHostedMermaidMagnificationTests {
    @Test("A fresh selectable diagram receives a pinch through its parent text view", .timeLimit(.minutes(1)))
    @available(macOS 27.0, *)
    func freshDiagramMagnifiesWithoutToolbarInteraction() async throws {
        let fixture = try await makeFixture(markdown: """
        Before paragraph remains native.

        ```mermaid
        flowchart LR
          A[Start] --> B[Finish]
        ```

        After paragraph remains native.

        """)
        defer { fixture.window.close() }
        let attachment = try #require(fixture.attachments.first)
        let host = attachment.loadHostedView()
        let canvas = try #require(findCanvas(in: host))
        let model = canvas.model
        let source = model.source
        let parseCount = model.parseCount
        let storage = try #require(fixture.view.textStorage)
        let renderedText = storage.string
        fixture.view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let selection = fixture.view.selectedRange()
        let exported = copySelection(from: fixture.view)
        let point = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        #expect(host.isDescendant(of: fixture.view), "Exercise the actual TextKit attachment hierarchy")
        #expect(model.zoom == 1)
        #expect(!model.isNavigationActive && !model.capturesScroll,
                "Pinching must work before zoom buttons or navigation activate the diagram")
        #expect(host.hitTest(canvas.convert(point, to: host.superview)) == nil,
                "Ordinary pointer hits still belong to text selection on a fresh diagram")

        fixture.view.magnify(with: MagnificationTestEvent(point: canvas.convert(point, to: nil),
                                                         magnification: 0.2,
                                                         windowNumber: fixture.window.windowNumber))

        #expect(abs(model.zoom - exp(0.2)) < 0.0001)
        #expect(model.capturesScroll)
        #expect(fixture.view.selectedRange() == selection)
        #expect(storage.string == renderedText)
        #expect(hostedAttachments(in: storage).first === attachment)
        #expect(attachment.loadHostedView() === host)
        #expect(findCanvas(in: host)?.model === model)
        #expect(model.source == source && model.parseCount == parseCount)
        #expect(copySelection(from: fixture.view) == exported)
        #expect(exported.contains("```mermaid\n" + source), "Copying still exports the underlying diagram source")
    }

    @Test("Pinches over prose and another diagram do not zoom the wrong attachment", .timeLimit(.minutes(1)))
    @available(macOS 27.0, *)
    func magnificationStaysInsideItsDiagram() async throws {
        let fixture = try await makeFixture(markdown: """
        Before paragraph remains native.

        ```mermaid
        flowchart LR
          A[First] --> B[Diagram]
        ```

        Between diagrams remains native.

        ```mermaid
        flowchart LR
          C[Second] --> D[Diagram]
        ```

        After paragraph remains native.

        """, imageMaxWidth: 200)
        defer { fixture.window.close() }
        try #require(fixture.attachments.count == 2)
        let first = try #require(findCanvas(in: fixture.attachments[0].loadHostedView()))
        let second = try #require(findCanvas(in: fixture.attachments[1].loadHostedView()))
        let firstHost = fixture.attachments[0].loadHostedView()
        let drawing = first.convert(first.bounds, to: firstHost)
        let whitespace = CGPoint(x: firstHost.bounds.maxX - 20, y: drawing.midY)
        #expect(firstHost.bounds.contains(whitespace))
        #expect(!first.bounds.contains(first.convert(whitespace, from: firstHost)),
                "The width cap leaves selectable host space outside the actual canvas")
        fixture.view.magnify(with: MagnificationTestEvent(point: firstHost.convert(whitespace, to: nil),
                                                         magnification: 0.3,
                                                         windowNumber: fixture.window.windowNumber))
        #expect(first.model.zoom == 1 && second.model.zoom == 1)

        let paragraph = try paragraphPoint(containing: "Between diagrams", in: fixture.view)
        #expect(!first.bounds.contains(first.convert(paragraph, from: fixture.view)))
        #expect(!second.bounds.contains(second.convert(paragraph, from: fixture.view)))
        fixture.view.magnify(with: MagnificationTestEvent(point: fixture.view.convert(paragraph, to: nil),
                                                         magnification: 0.3,
                                                         windowNumber: fixture.window.windowNumber))
        #expect(first.model.zoom == 1 && second.model.zoom == 1)
        #expect(!first.model.capturesScroll && !second.model.capturesScroll)

        let point = CGPoint(x: second.bounds.midX, y: second.bounds.midY)
        fixture.view.magnify(with: MagnificationTestEvent(point: second.convert(point, to: nil),
                                                         magnification: 0.2,
                                                         windowNumber: fixture.window.windowNumber))
        #expect(first.model.zoom == 1, "Only the diagram under the pinch may consume it")
        #expect(abs(second.model.zoom - exp(0.2)) < 0.0001)
    }

    private func makeFixture(markdown: String, imageMaxWidth: CGFloat? = nil) async throws -> (window: NSWindow, view: NSTextView, attachments: [PicoHostedAttachment]) {
        _ = NSApplication.shared
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = CGRect(x: 0, y: 0, width: 700, height: 1400)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        var fixtureReady = false
        defer { if !fixtureReady { window.close() } }
        window.orderFront(nil)
        let base = MarkdownRenderTheme.default()
        let theme = MarkdownRenderTheme(bodyFont: base.bodyFont, codeFont: base.codeFont,
                                        blockquoteColor: base.blockquoteColor, linkColor: base.linkColor,
                                        headingFonts: base.headingFonts, imageMaxWidth: imageMaxWidth,
                                        codeBlockTheme: base.codeBlockTheme, codeHighlighter: base.codeHighlighter)
        let pipeline = MarkdownStreamingPipeline(theme: theme)
        for update in [await pipeline.feed(markdown), await pipeline.finish()] {
            guard let update else { continue }
            controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                              replaceToken: 1, configuration: .default())
        }
        let storage = try #require(view.textStorage)
        let attachments = hostedAttachments(in: storage)
        try #require(!attachments.isEmpty)
        var markerOffsets: [ObjectIdentifier: Int] = [:]
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attachment = value as? PicoHostedAttachment {
                markerOffsets[ObjectIdentifier(attachment)] = range.location
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while true {
            if let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
            }
            view.layoutSubtreeIfNeeded()
            for attachment in attachments { attachment.hostingView?.layoutSubtreeIfNeeded() }
            window.displayIfNeeded()
            if attachments.allSatisfy({ attachment in
                guard let host = attachment.hostingView, host.isDescendant(of: view),
                      let canvas = self.findCanvas(in: host),
                      abs(host.fittingSize.height - attachment.measuredSize.height) <= 1,
                      abs(host.bounds.height - attachment.measuredSize.height) <= 1,
                      let offset = markerOffsets[ObjectIdentifier(attachment)],
                      let manager = view.textLayoutManager, let content = manager.textContentManager,
                      let location = content.location(content.documentRange.location, offsetBy: offset),
                      let fragment = manager.textLayoutFragment(for: location),
                      fragment.layoutFragmentFrame.height >= attachment.measuredSize.height - 1 else { return false }
                return canvas.window === window && canvas.bounds.width > 0 && canvas.bounds.height > 0
            }) { break }
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for TextKit to mount the hosted Mermaid canvases")
                throw FixtureTimeout()
            }
            // Canvas creation precedes deferred intrinsic-size publication.
            // Wait until TextKit has also reserved the measured height, so the
            // native prose and each diagram occupy their settled coordinates.
            try await Task.sleep(for: .milliseconds(10))
        }
        fixtureReady = true
        return (window, view, attachments)
    }

    private struct FixtureTimeout: Error {}

    private func hostedAttachments(in storage: NSTextStorage) -> [PicoHostedAttachment] {
        var result: [PicoHostedAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { result.append(attachment) }
        }
        return result
    }

    private func findCanvas(in view: NSView) -> PicoHostedVectorCanvasView? {
        if let canvas = view as? PicoHostedVectorCanvasView { return canvas }
        return view.subviews.lazy.compactMap { findCanvas(in: $0) }.first
    }

    private func paragraphPoint(containing text: String, in view: NSTextView) throws -> CGPoint {
        let index = (view.string as NSString).range(of: text).location
        try #require(index != NSNotFound)
        let manager = try #require(view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: index))
        let fragment = try #require(manager.textLayoutFragment(for: location))
        let line = try #require(fragment.textLineFragment(for: location, isUpstreamAffinity: false))
        return CGPoint(x: view.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.midX,
                       y: view.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.midY)
    }

    private func copySelection(from view: NSTextView) -> String {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        return pasteboard.string(forType: .string) ?? ""
    }
}

private final class MagnificationTestEvent: NSEvent {
    private let point: NSPoint
    private let amount: CGFloat
    private let number: Int

    init(point: NSPoint, magnification: CGFloat, windowNumber: Int) {
        self.point = point
        amount = magnification
        number = windowNumber
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("Tests construct their own magnification event") }
    override var type: NSEvent.EventType { .magnify }
    override var locationInWindow: NSPoint { point }
    override var magnification: CGFloat { amount }
    override var windowNumber: Int { number }
    override var phase: NSEvent.Phase { .changed }
}
#endif
