#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PicoMarkdownView

@Suite("Natural hosted vector layout")
@MainActor
struct MacHostedSVGNaturalLayoutTests {
    @Test("The public SwiftUI view creates hosted SVG from its natural intrinsic height", .timeLimit(.minutes(1)))
    @available(macOS 27.0, *)
    func publicViewNaturalHeight() async throws {
        _ = NSApplication.shared
        // Keep the graphic in the initial viewport regardless of font/layout
        // work in parallel suites. Offscreen attachment views are deliberately
        // lazy and must not be required to instantiate in this regression.
        let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 480 200\"><circle cx=\"240\" cy=\"100\" r=\"75\" fill=\"#8b5cf6\"/></svg>"
        let sentinel = "Natural SVG document complete."
        let markdown = "Before.\n\n```svg\n" + source + "\n```\n\n" + sentinel + "\n\n"
        let host = NSHostingView(rootView: ScrollView {
            PicoMarkdownView(markdown, theme: .default().withSVGRendering())
                .frame(maxWidth: .infinity, alignment: .leading)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        var textView: NSTextView?
        var phase = "waiting for Markdown source"
        defer {
            if phase != "complete" {
                let view = findTextView(in: host)
                print("SVG natural layout cancellation: phase=\(phase), frame=\(String(describing:view?.frame)), visible=\(String(describing:view?.visibleRect)), sourceEnd=\(view?.textStorage?.string.contains(sentinel) ?? false), windowVisible=\(window.isVisible)")
            }
        }
        while true {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            textView = findTextView(in: host)
            if let view = textView, let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
                view.layoutSubtreeIfNeeded()
            }
            if let view = textView, let storage = view.textStorage,
               storage.string.contains(sentinel) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let view = try #require(textView)
        let storage = try #require(view.textStorage)
        var attachments: [PicoHostedAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { attachments.append(attachment) }
        }
        #expect(attachments.count == 1)
        let first = try #require(attachments.first)
        let marker = (storage.string as NSString).range(of: "\u{FFFC}")
        try #require(marker.location != NSNotFound)
        view.scrollRangeToVisible(marker)
        phase = "waiting for visible vector canvas; initial height=\(first.measuredSize.height)"
        while first.hostingView?.superview == nil || findCanvas(in: first.hostingView) == nil {
            host.layoutSubtreeIfNeeded()
            if let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
            }
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let canvas = try #require(findCanvas(in: first.hostingView))
        #expect(canvas.window === window)
        #expect(canvas.model.kind == .svg)
        #expect(canvas.model.isRenderable)
        #expect(first.attachmentCell == nil)
        #expect(canvas.bounds.height >= 140)
        #expect(first.measuredSize.height >= 140)
        phase = "complete"
    }

    private func findCanvas(in view: NSView?) -> PicoHostedVectorCanvasView? {
        guard let view else { return nil }
        if let canvas = view as? PicoHostedVectorCanvasView { return canvas }
        return view.subviews.lazy.compactMap { findCanvas(in: $0) }.first
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let view = view as? NSTextView { return view }
        return view.subviews.lazy.compactMap { findTextView(in: $0) }.first
    }

    @Test("TextKit creates and measures hosted vector views without explicit loading", .timeLimit(.minutes(1)), arguments: ["svg", "mermaid"])
    @available(macOS 27.0, *)
    func naturalProviderCreation(language: String) async throws {
        _ = NSApplication.shared
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering())
        let source = language == "svg"
            ? "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"320\" height=\"160\"><rect width=\"320\" height=\"160\" fill=\"#3973d5\"/></svg>"
            : "flowchart LR\nA --> B"
        func apply(_ update: StreamingUpdate?) {
            guard let update else { return }
            controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                              replaceToken: 1, configuration: .default())
        }
        apply(await pipeline.feed("Before paragraph.\n\n```" + language + "\n" + source + "\n```\n\nAfter paragraph.\n\n"))
        apply(await pipeline.finish())
        let storage = try #require(view.textStorage)
        var attachments: [PicoHostedAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { attachments.append(attachment) }
        }
        let attachment = try #require(attachments.first)
        while attachment.hostingView == nil || attachment.measuredSize.height < 140 {
            if let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
            }
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if attachment.hostingView != nil, attachment.measuredSize.height >= 140 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(attachment.hostingView != nil)
        #expect(attachment.measuredSize.height >= 140)
        #expect(attachment.hostingView?.superview != nil)
    }
}
#endif
