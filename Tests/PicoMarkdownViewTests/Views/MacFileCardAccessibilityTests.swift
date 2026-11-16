#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS file-card accessibility hierarchy", .timeLimit(.minutes(1)))
@MainActor
struct MacFileCardAccessibilityTests {
    @Test("Native text-view accessibility exposes file metadata and live controls")
    func fileCardIsReachableFromNativeTextView() async throws {
        _ = NSApplication.shared
        let reference = URL(string: "artifact://files/accessibility-report")!
        let file = PicoFileAttachment(id: "report", referenceURL: reference,
                                      filename: "Report.md", typeDescription: "Markdown",
                                      state: .creating)
        let backend = TextKitStreamingBackend()
        var actions: [PicoFileCardAction.Kind] = []
        backend.setFileCards([file]) { actions.append($0.kind) }
        let view = StreamingTextKit2View(backend: backend)
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let pipeline = MarkdownStreamingPipeline()
        for update in [await pipeline.feed("Before.\n\n[Report](artifact://files/accessibility-report)\n\nAfter.\n\n"),
                       await pipeline.finish()] {
            if let update {
                view.setSelectedRange(backend.apply(blocks: update.blocks, diffs: [update.diff], selection: view.selectedRange()))
            }
        }
        func layout() {
            // AppKit can defer representable updates in occluded test windows.
            window.orderFront(nil)
            backend.updateHostedAttachments(width: view.bounds.width, selection: [view.selectedRange()])
            if let manager = view.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
            }
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func children() -> [NSView] { (view.accessibilityChildren() ?? []).compactMap { $0 as? NSView } }
        func buttons() -> [NSButton] { children().compactMap { $0 as? NSButton } }
        func metadata() -> NSView? {
            children().first { $0.accessibilityRole() == .staticText &&
                ($0.accessibilityLabel() ?? "").hasPrefix("Report.md.") }
        }
        try await waitUntil(layout: layout) {
            metadata()?.accessibilityLabel()?.contains("Creating") == true &&
                buttons().count == 2 && buttons().allSatisfy { !$0.isEnabled }
        }
        let initialChildren = children()
        let label = try #require(metadata())
        #expect(label.accessibilityParent() as? NSView === view)
        #expect(Set(buttons().map(\.title)) == ["Preview", "Download"])
        for button in buttons() {
            #expect(button.accessibilityParent() as? NSView === view)
            #expect(initialChildren.filter { $0 === button }.count == 1)
            #expect(!(button.accessibilityHelp() ?? "").isEmpty)
        }
        #expect(!PicoFileCardAccessibility.children(in: view).isEmpty)
        let storage = try #require(view.textStorage)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let selection = view.selectedRange()
        file.byteCount = 2_048
        file.state = .ready
        try await waitUntil(layout: layout) {
            metadata()?.accessibilityLabel()?.contains("Ready") == true &&
                buttons().count == 2 && buttons().allSatisfy(\.isEnabled)
        }
        let readyButtons = buttons()
        for button in readyButtons {
            #expect(window.makeFirstResponder(button), "Native file actions accept keyboard focus")
            #expect(window.firstResponder === button)
            let selector = try #require(button.action)
            #expect(NSApp.sendAction(selector, to: button.target, from: button))
        }
        #expect(actions == [.preview, .download])
        #expect(view.selectedRange() == selection)
        #expect(view.textLayoutManager != nil)

        backend.setFileCards([])
        view.setSelectedRange(backend.applyPendingFileCardUpdates(selection: view.selectedRange()))
        try await waitUntil(layout: layout) { PicoFileCardAccessibility.children(in: view).isEmpty }
        #expect(metadata() == nil && buttons().isEmpty, "Retired card controls leave the text accessibility tree")
    }

    private func waitUntil(layout: () -> Void, condition: () -> Bool) async throws {
        while true {
            try Task.checkCancellation()
            layout()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
#endif
