#if os(macOS)
import AppKit
import Testing
@preconcurrency import WebKit
@testable import PicoMarkdownView

/// Exercises the shipped web bundle through the real streaming pipeline and
/// TextKit attachment provider, including an official OpenUI form action.
@Suite("OpenUI web runtime in TextKit 2", .serialized)
@MainActor
struct MacOpenUIWebRuntimeTests {
    @Test("Completed child keeps form state while native text streams, resizes and changes appearance", .timeLimit(.minutes(1)))
    func liveChildInNativeDocument() async throws {
        _ = NSApplication.shared
        let backend = TextKitStreamingBackend()
        let textView = StreamingTextKit2View(backend: backend)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 700))
        scroll.hasVerticalScroller = true
        textView.frame = NSRect(x: 0, y: 0, width: 660, height: 1400)
        scroll.documentView = textView
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.close() }
        var receivedActions: [PicoOpenUIActionEvent] = []
        backend.onOpenUIAction = { receivedActions.append($0) }
        let pipeline = MarkdownStreamingPipeline(theme: .default().withOpenUIRendering())
        let prefix = "Native introduction.\n\n```openui\n" + source + "\n"
        let open = try #require(await pipeline.feed(prefix))
        _ = backend.apply(blocks: open.blocks, diffs: [open.diff], selection: .init(location: 0, length: 0))
        #expect(!open.blocks.contains { $0.openUI != nil })
        #expect(textView.textStorage?.string.contains("tripForm =") == true)
        let closed = try #require(await pipeline.feed("```\n\nNative tail.\n\n"))
        _ = backend.apply(blocks: closed.blocks, diffs: [closed.diff], selection: .init(location: 0, length: 0))
        let id = try #require(closed.blocks.first { $0.openUI != nil }?.id)
        let model = try #require(backend.hostedOpenUIModel(for: id))
        let attachment = try #require(backend.hostedAttachment(for: id))
        backend.updateHostedAttachments(width: 630, selection: [])
        func layout() {
            scroll.layoutSubtreeIfNeeded()
            if let manager = textView.textLayoutManager, let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
            }
            textView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        try await waitUntil("TextKit creates the visible child", whileWaiting: layout) {
            model.webView?.window === window && model.isReady && model.sizeMessageCount > 0
        }
        let webView = try #require(model.webView)
        let fields = try await webView.callAsyncJavaScript("return document.querySelectorAll('input').length;",
                                                         arguments: [:], in: nil, contentWorld: .page) as? Int
        #expect(fields == 2)
        #expect(model.error == nil)
        #expect(model.webViewCreationCount == 1)
        #expect(textView.textLayoutManager != nil)
        #expect(textView.textStorage?.string == "Native introduction.\n\u{FFFC}\nNative tail.\n")

        _ = try await webView.callAsyncJavaScript("""
            for (const [name, value] of Object.entries(values)) {
              const input = document.querySelector('input[name="' + name + '"]');
              if (!input) throw new Error('Missing input ' + name);
              Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, value);
              input.dispatchEvent(new Event('input', {bubbles:true}));
              input.dispatchEvent(new Event('change', {bubbles:true}));
              input.dispatchEvent(new FocusEvent('blur', {bubbles:true}));
            }
            return true;
            """, arguments: ["values": ["traveler": "Ada Lovelace", "email": "ada@example.com"]],
            in: nil, contentWorld: .page)
        let initialRenderCount = model.renderCount
        let tail = try #require(await pipeline.feed("Another **incremental** paragraph.\n\n|A|B|\n|---|---|\n|1|2|\n"))
        _ = backend.apply(blocks: tail.blocks, diffs: [tail.diff], selection: .init(location: 0, length: 0))
        let rows = try #require(await pipeline.feed("|3|4|\n"))
        _ = backend.apply(blocks: rows.blocks, diffs: [rows.diff], selection: .init(location: 0, length: 0))
        #expect(backend.hostedOpenUIModel(for: id) === model)
        #expect(backend.hostedAttachment(for: id) === attachment)
        #expect(model.renderCount == initialRenderCount, "Tail streaming must not call the OpenUI renderer")
        #expect(rows.blocks.first { $0.table != nil }?.table?.rows.count == 2)
        for width: CGFloat in [330, 760] {
            textView.setFrameSize(NSSize(width: width, height: 1800))
            backend.updateHostedAttachments(width: width - 20, selection: [])
            layout()
            let measuredWidth = try await webView.callAsyncJavaScript("return window.innerWidth;",
                arguments: [:], in: nil, contentWorld: .page) as? Double
            #expect((measuredWidth ?? 0) > 0)
        }
        let previousScale = model.textScale
        let scaled = try #require(await pipeline.updateTextScale(1.5))
        _ = backend.apply(blocks: scaled, selection: .init(location: 0, length: 0))
        layout()
        #expect(model.textScale == previousScale * 1.5)
        #expect(webView.pageZoom == model.textScale)
        #expect(model.webView === webView && backend.hostedAttachment(for: id) === attachment)
        #expect(model.renderCount == initialRenderCount, "Text sizing must not resubmit OpenUI source")
        try await waitUntil("Scaled WebKit height reaches its native attachment", whileWaiting: layout) {
            abs(attachment.measuredSize.height - model.measuredHeight) <= 2
        }
        model.updateAppearance(dark: true)
        try await waitUntil("Appearance update reaches the retained child", whileWaiting: layout) {
            model.renderCount > initialRenderCount
        }
        let values = try await webView.callAsyncJavaScript("""
            return {traveler:document.querySelector('input[name="traveler"]').value,
                    email:document.querySelector('input[name="email"]').value};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: String]
        #expect(values?["traveler"] == "Ada Lovelace")
        #expect(values?["email"] == "ada@example.com")
        #expect(model.webView === webView && model.webViewCreationCount == 1)
        _ = try await webView.callAsyncJavaScript("""
            const button = [...document.querySelectorAll('button')].find(b => b.textContent.trim() === 'Plan trip');
            if (!button) throw new Error('Missing submit button');
            button.click(); return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        try await waitUntil("Semantic form action arrives", whileWaiting: layout) { model.lastAction != nil }
        let event = try #require(model.lastAction)
        #expect(event.type == "continue_conversation")
        #expect(event.humanFriendlyMessage == "Plan my weekend")
        #expect(event.formName == "trip")
        // Upstream retains the named form and per-field metadata; the native
        // bridge must preserve that structure rather than flattening it.
        if case .object(let trip)? = event.formState?["trip"] {
            for (name, value) in [("traveler", "Ada Lovelace"), ("email", "ada@example.com")] {
                if case .object(let field)? = trip[name] {
                    #expect(field["value"] == .string(value))
                } else { Issue.record("Missing scoped field: \(name)") }
            }
        } else { Issue.record("Missing scoped trip form state") }
        #expect(receivedActions == [event])
        #expect(event.params["context"] == .object(["viewId": .string("trip-form"), "itineraryId": .number(42)]))

        let storage = try #require(textView.textStorage)
        textView.setSelectedRange(NSRange(location: 0, length: storage.length))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(textView.writeSelection(to: pasteboard, types: [.string]))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.contains("Native introduction."))
        #expect(copied.contains("```openui\n" + source + "\n```"))
        #expect(copied.contains("Another incremental paragraph."))
        #expect(copied.contains("| 3 | 4 |"))
        #expect(!copied.contains("\u{FFFC}"))
        #expect(textView.textLayoutManager != nil)
        #expect(attachment.measuredSize.height.isFinite && attachment.measuredSize.height > 80)
        // Preserve a rendering artifact for local visual inspection without
        // adding test-only hooks or fixture data to the shipped web bundle.
        if let directory = ProcessInfo.processInfo.environment["PICO_OPENUI_SNAPSHOT_DIRECTORY"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let image = try await webView.takeSnapshot(configuration: nil)
            if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: url.appendingPathComponent("integrated-openui.png"))
            }
        }
        _ = backend.apply(blocks: [], selection: .init(location: 0, length: 0))
        #expect(model.isDisposed && model.webView == nil)
    }

    @Test("A valid implicit root with an upstream warning remains visible", .timeLimit(.minutes(1)))
    func parserWarningRemainsVisible() async throws {
        _ = NSApplication.shared
        let model = PicoHostedOpenUIModel(source: "content = Stack([TextContent(\"Hello from fallback root\")])",
                                          language: "openui")
        let webView = try #require(model.makeWebView())
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFront(nil)
        defer { model.dispose(); window.close() }
        try await waitUntil("Implicit-root content is measured", whileWaiting: { window.displayIfNeeded() }) {
            model.isReady && model.sizeMessageCount > 0
        }
        let text = try await webView.callAsyncJavaScript("return document.body.textContent;",
            arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(text?.contains("Hello from fallback root") == true)
        #expect(model.error == nil, "Nonfatal upstream warnings must not replace valid content with fallback")
    }

    private func waitUntil(_ description: String, whileWaiting layout: () -> Void,
                           condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() {
            layout()
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out: \(description)")
                throw RuntimeTimeout()
            }
            // WebKit delivers its DOM and native bridge callbacks asynchronously.
            // Wait for the observed readiness condition, with a bounded deadline.
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct RuntimeTimeout: Error {}
    private let source = """
    root = Stack([card])
    card = Card([CardHeader("Plan a weekend", "Official OpenUI in TextKit 2"), tripForm])
    tripForm = Form("trip", buttons, [travelerField, emailField])
    travelerField = FormControl("Traveler", Input("traveler", "Your name", "text", {required: true, minLength: 2}), "Who is travelling?")
    emailField = FormControl("Email", Input("email", "you@example.com", "email", {required: true, email: true}), "Included in the action")
    buttons = Buttons([submit], "row")
    submit = Button("Plan trip", @ToAssistant("Plan my weekend", {viewId: "trip-form", itineraryId: 42}), "primary")
    """
}
#endif
