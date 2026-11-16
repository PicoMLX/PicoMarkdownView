#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PicoMarkdownView

@Suite("Delayed images publish without scrolling", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MacHostedImagePublicationTests {
    @Test("An asynchronously loaded standalone image mounts with its source aspect through native events")
    func delayedImageAppearsWithoutViewportIntervention() async throws {
        _ = NSApplication.shared
        let provider = PublicationImageProvider()
        let outer = NSHostingView(rootView: ScrollView {
            PicoMarkdownView("Before image.\n\n![pending](https://example.invalid/probe.png)\n\nAfter image.\n\n",
                             imageProvider: provider, remoteImagesEnabled: false)
                .padding(16)
        })
        outer.frame = CGRect(x: 0, y: 0, width: 368, height: 620)
        let window = NSWindow(contentRect: outer.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = outer
        window.orderFront(nil)
        defer { window.close() }
        outer.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await observe("initial prose") { textView(in: outer)?.string.contains("After image.") == true }
        let text = try #require(textView(in: outer))
        #expect(firstAttachment(in: text) == nil)
        if let manager = text.textLayoutManager, let content = manager.textContentManager {
            manager.ensureLayout(for: content.documentRange)
            manager.textViewportLayoutController.layoutViewport()
        }
        text.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // No layout, viewport, scroll or display requests follow availability.
        await provider.makeAvailable()
        try await observe("image attachment insertion") { firstAttachment(in: text) != nil }
        let attachment = try #require(firstAttachment(in: text))
        do {
            try await observe("image native mounting and geometry") {
                guard let host = attachment.hostingView, let native = canvas(in: host) else { return false }
                return host.window === window && native.window === window && !native.isHiddenOrHasHiddenAncestor
                    && native.bounds.width > 100 && native.bounds.height > 50
                    && host.visibleRect.height > 0 && native.visibleRect.height > 0
                    && abs(host.bounds.height - attachment.measuredSize.height) < 1
                    && abs(native.bounds.width / native.bounds.height - 480.0 / 180) < 0.05
                    && !native.needsDisplay
            }
        } catch {
            Issue.record("Natural image publication failed: \(geometry(attachment))")
            throw error
        }
        #expect(attachment.measuredSize == CGSize(width: 336, height: 126))
        #expect(attachment.markdownRepresentation() == "![pending](https://example.invalid/probe.png)")
        #expect(text.string.contains("Before image.") && text.string.contains("After image."))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        text.setSelectedRange(NSRange(location: 0, length: text.string.utf16.count))
        #expect(text.writeSelection(to: pasteboard, types: [.string]))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.contains("![pending](https://example.invalid/probe.png)"))
        #expect(copied.contains("Before image.") && copied.contains("After image."))
        #expect(!copied.contains("\u{FFFC}"))
    }

    private func observe(_ phase: String, until condition: () -> Bool) async throws {
        do {
            while !condition() {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
        } catch {
            Issue.record("Passive native events did not complete \(phase)")
            throw error
        }
    }

    private func textView(in view: NSView) -> StreamingTextKit2View? {
        if let text = view as? StreamingTextKit2View { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    private func canvas(in view: NSView?) -> PicoHostedMediaCanvasView? {
        guard let view else { return nil }
        if let canvas = view as? PicoHostedMediaCanvasView { return canvas }
        return view.subviews.lazy.compactMap { canvas(in: $0) }.first
    }

    private func firstAttachment(in text: NSTextView) -> PicoHostedAttachment? {
        guard let storage = text.textStorage else { return nil }
        var result: PicoHostedAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { result = attachment }
        }
        return result
    }

    private func geometry(_ attachment: PicoHostedAttachment) -> String {
        let host = attachment.hostingView
        let native = canvas(in: host)
        return "attachment=\(attachment.measuredSize), host=\(String(describing: host?.frame))"
            + " bounds=\(String(describing: host?.bounds)) window=\(host?.window != nil)"
            + " canvas=\(String(describing: native?.frame)) bounds=\(String(describing: native?.bounds))"
            + " visible=\(String(describing: native?.visibleRect)) hidden=\(String(describing: native?.isHidden))"
            + " needsDisplay=\(String(describing: native?.needsDisplay))"
    }
}

private actor PublicationImageProvider: MarkdownImagePrefetchingProvider {
    private var cached: MarkdownImageResult?
    private var waiting: [CheckedContinuation<MarkdownImageResult?, Never>] = []

    func image(for url: URL) async -> MarkdownImageResult? { cached }

    func prefetch(_ url: URL) async -> MarkdownImageResult? {
        if let cached { return cached }
        return await withCheckedContinuation { waiting.append($0) }
    }

    func makeAvailable() async {
        let result = await MainActor.run {
            let size = CGSize(width: 480, height: 180)
            let image = NSImage(size: size, flipped: false) { bounds in
                NSColor.systemGreen.setFill()
                bounds.fill()
                return true
            }
            return MarkdownImageResult(image: image, size: size)
        }
        cached = result
        for continuation in waiting { continuation.resume(returning: result) }
        waiting.removeAll()
    }
}
#endif
