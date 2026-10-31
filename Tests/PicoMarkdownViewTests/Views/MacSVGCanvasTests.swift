#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS SVG canvas controls")
@MainActor
struct MacSVGCanvasTests {
    private let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100">
      <title>Two colors</title><desc>Red above blue</desc>
      <rect width="200" height="50" fill="red"/>
      <rect y="50" width="200" height="50" fill="blue"/>
    </svg>
    """

    @Test("SVG controls expose source-specific labels, help and Markdown copy")
    func accessibleControlsAndCopy() throws {
        _ = NSApplication.shared
        let model = PicoHostedVectorModel(svg: svg, source: svg, language: "svg title=Colors", isClosed: true, kind: .svg)
        let canvas = PicoHostedVectorCanvasView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        canvas.layoutSubtreeIfNeeded()
        #expect(canvas.accessibilityLabel() == "SVG graphic: Two colors. Red above blue")
        let actions = canvas.accessibilityCustomActions()?.map(\.name) ?? []
        #expect(actions.contains("Zoom in"))
        #expect(actions.contains("Zoom out"))
        #expect(actions.contains("Copy SVG"))
        #expect(!actions.contains("Copy Mermaid"))
        let copy = try #require(descendants(of: canvas).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Copy SVG" })
        #expect(copy.toolTip?.contains("code fences") == true)
        #expect(copy.accessibilityHelp()?.contains("SVG") == true)
        #expect(copy.accessibilityHelp()?.contains("code fences") == true)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(model.copyMarkdown(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "```svg title=Colors\n" + svg + "\n```")
        #expect(model.copySource(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == svg)
    }

    @Test("SVG shares navigation policy and Escape reset without reparsing")
    func navigationPolicy() throws {
        _ = NSApplication.shared
        let model = PicoHostedVectorModel(svg: svg, source: svg, language: "svg", isClosed: true, kind: .svg)
        let canvas = PicoHostedVectorCanvasView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        canvas.layoutSubtreeIfNeeded()
        #expect(!canvas.acceptsHostedAttachmentHit(at: CGPoint(x: 100, y: 100)))
        #expect(canvas.acceptsHostedAttachmentMagnification(at: CGPoint(x: 100, y: 100)))
        model.zoom(by: 2)
        #expect(canvas.acceptsHostedAttachmentHit(at: CGPoint(x: 100, y: 100)))
        model.pan(by: CGPoint(x: 20, y: 10))
        canvas.cancelOperation(nil)
        #expect(model.zoom == 1)
        #expect(model.pan == .zero)
        #expect(!model.capturesScroll)
        #expect(model.parseCount == 1)
    }

    @Test("Invalid SVG updates clear the previous drawing and preserve export source")
    func invalidUpdateClearsDrawing() {
        let model = PicoHostedVectorModel(svg: svg, source: svg, language: "svg", isClosed: true, kind: .svg)
        #expect(model.isRenderable)
        let invalid = "<svg><rect"
        model.update(svg: invalid, source: invalid, language: "svg", isClosed: true)
        #expect(!model.isRenderable)
        #expect(model.intrinsicSize == .zero)
        #expect(model.source == invalid)
        #expect(model.markdownRepresentation() == "```svg\n" + invalid + "\n```")
        model.update(svg: svg, source: svg, language: "svg", isClosed: true)
        #expect(model.isRenderable)
        #expect(model.parseCount == 3)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
#endif
