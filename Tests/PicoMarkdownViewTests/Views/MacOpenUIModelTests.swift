#if os(macOS)
import AppKit
import Testing
@preconcurrency import WebKit
@testable import PicoMarkdownView

@Suite("macOS OpenUI child lifecycle and bridge")
@MainActor
struct MacOpenUIModelTests {
    @Test("Creating a model and changing appearance do not create a browser")
    func browserCreationIsLazy() {
        let model = PicoHostedOpenUIModel(source: source, language: "openui")
        defer { model.dispose() }
        model.updateAppearance(dark: true)
        model.updateAppearance(dark: false)
        #expect(model.webView == nil)
        #expect(model.webViewCreationCount == 0)
        #expect(model.renderCount == 0)
        #expect(!model.isReady)
        #expect(model.markdown == "```openui\n" + source + "\n```")
        model.receive(["kind": "ready", "sourceID": "another-source"])
        #expect(!model.isReady)
        model.receive(["kind": "ready", "sourceID": NSNull()])
        #expect(model.isReady)
        #expect(model.webViewCreationCount == 0)
        #expect(model.renderCount == 0)
    }

    @Test("Text scale updates the retained browser's page zoom without rendering or recreating it")
    func textScaleDoesNotReloadBrowser() throws {
        let model = PicoHostedOpenUIModel(source: source, language: "openui")
        defer { model.dispose() }
        model.updateTextScale(1.25)
        #expect(model.textScale == 1.25)
        #expect(model.webView == nil)
        let webView = try #require(model.makeWebView())
        #expect(webView.pageZoom == 1.25)
        model.receive(["kind": "ready", "sourceID": model.sourceID])
        let initialRenderCount = model.renderCount
        #expect(initialRenderCount == 1)
        let sourceID = model.sourceID
        model.updateTextScale(1.5)
        #expect(model.textScale == 1.5)
        #expect(webView.pageZoom == 1.5)
        #expect(model.webView === webView)
        #expect(model.sourceID == sourceID)
        #expect(model.webViewCreationCount == 1)
        #expect(model.renderCount == initialRenderCount)
    }

    @Test("Changing zoom scales the last CSS height without another size message", .timeLimit(.minutes(1)))
    func textScaleUpdatesIntrinsicHeight() async {
        let model = PicoHostedOpenUIModel(source: source, language: "openui")
        defer { model.dispose() }
        await waitForHeightChange(of: model) {
            model.receive(["kind": "size", "payload": ["height": 200.0], "sourceID": model.sourceID])
        }
        #expect(model.measuredHeight == 200)
        await waitForHeightChange(of: model) { model.updateTextScale(1.5) }
        #expect(model.measuredHeight == 300)
        #expect(model.sizeMessageCount == 1,
                "Scaling must reuse the last known CSS height when ResizeObserver has nothing new to report")
        await waitForHeightChange(of: model) {
            model.receive(["kind": "size", "payload": ["height": 210.0], "sourceID": model.sourceID])
        }
        #expect(model.measuredHeight == 315)
        await waitForHeightChange(of: model) { model.updateTextScale(1) }
        #expect(model.measuredHeight == 210)
        #expect(model.sizeMessageCount == 2)
        #expect(model.webViewCreationCount == 0)
        #expect(model.renderCount == 0)
    }

    @Test("Export chooses a safe fence when raw source contains backticks", arguments: [
        "root = TextContent(\"embedded ``` marker\")\n",
        "root = TextContent(\"example\")\n````\nraw content\n"
    ])
    func markdownExportRoundTripsRawSource(_ body: String) async throws {
        let model = PicoHostedOpenUIModel(source: body, language: "OPENUI preview")
        defer { model.dispose() }
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed(model.markdown + "\n\n")
        _ = await pipeline.finish()
        let code = try #require(await pipeline.blocksSnapshot().first { $0.codeBlock != nil })
        #expect(code.codeBlock?.code == body)
        #expect(code.codeBlock?.language == "OPENUI preview")
        #expect(model.webView == nil)
    }

    @Test("Only a matching main-frame action reaches the host application")
    func actionsRejectUnrelatedFramesAndSources() {
        let model = PicoHostedOpenUIModel(source: source, language: "openui")
        defer { model.dispose() }
        var delivered: [PicoOpenUIActionEvent] = []
        model.onAction = { delivered.append($0) }
        let payload: [String: Any] = [
            "type": "continue_conversation",
            "params": ["reportID": 42, "selected": true],
            "humanFriendlyMessage": "Explain this report",
            "formState": ["trip": ["traveler": ["value": "Ada 🧭"]]], "formName": "trip"
        ]
        let valid: [String: Any] = ["kind": "action", "payload": payload, "sourceID": model.sourceID]
        model.receive(valid, isMainFrame: false)
        model.receive(["kind": "action", "payload": payload, "sourceID": "another-source"])
        model.receive(["kind": "action", "payload": payload])
        model.receive(["kind": "action", "payload": ["invalid": true], "sourceID": model.sourceID])
        #expect(delivered.isEmpty)
        #expect(model.lastAction == nil)

        model.receive(valid)
        #expect(delivered.count == 1)
        #expect(delivered.first?.params["reportID"] == .number(42))
        #expect(delivered.first?.params["selected"] == .bool(true))
        #expect(delivered.first?.formState?["trip"] == .object([
            "traveler": .object(["value": .string("Ada 🧭")])
        ]))
        #expect(delivered.first?.formName == "trip")
        #expect(model.lastAction == delivered.first)
        #expect(model.webView == nil)
    }

    @Test("Retired models ignore pending actions, errors, readiness and size messages")
    func disposalRejectsLateEvents() {
        let model = PicoHostedOpenUIModel(source: source, language: "openui")
        var actionCount = 0
        model.onAction = { _ in actionCount += 1 }
        model.dispose()
        model.dispose()
        model.receive(["kind": "ready", "payload": [:]])
        model.receive(["kind": "action", "payload": [
            "type": "open_url", "params": ["url": "https://example.com"],
            "humanFriendlyMessage": "Open docs"
        ], "sourceID": model.sourceID])
        model.receive(["kind": "error", "payload": ["late error"], "sourceID": model.sourceID])
        model.receive(["kind": "size", "payload": ["height": 500], "sourceID": model.sourceID])
        #expect(model.isDisposed)
        #expect(!model.isReady)
        #expect(model.lastAction == nil)
        #expect(model.error == nil)
        #expect(model.sizeMessageCount == 0)
        #expect(actionCount == 0)
        #expect(model.makeWebView() == nil)
        #expect(model.webViewCreationCount == 0)
    }

    @Test("Size messages reject invalid dimensions and excessive inline height")
    func invalidSizeDoesNotPoisonLayout() {
        let model = PicoHostedOpenUIModel(source: source, language: "openui")
        defer { model.dispose() }
        let initialHeight = model.measuredHeight
        for height in [Double.nan, .infinity, -.infinity, 0, -10] {
            model.receive(["kind": "size", "payload": ["height": height], "sourceID": model.sourceID])
        }
        #expect(model.sizeMessageCount == 0)
        #expect(model.measuredHeight == initialHeight)
        model.receive(["kind": "size", "payload": ["height": Double(PicoHostedOpenUIModel.maximumHeight) + 1],
                       "sourceID": model.sourceID])
        #expect(model.error != nil)
        #expect(model.measuredHeight == initialHeight)
        model.receive(["kind": "error", "payload": [Any](), "sourceID": model.sourceID])
        #expect(model.error == nil, "A successful renderer result must clear its earlier error")
    }

    @Test("Nonfatal parser diagnostics do not hide valid interactive content", arguments: ["warning", "info"])
    func nonfatalDiagnosticsKeepContent(severity: String) {
        let model = PicoHostedOpenUIModel(source: source, language: "openui")
        defer { model.dispose() }
        var failureCount = 0
        model.onError = { _ in failureCount += 1 }
        model.receive(["kind": "error", "payload": [["severity": severity, "message": "Optional diagnostic"]],
                       "sourceID": model.sourceID])
        #expect(model.error == nil)
        #expect(failureCount == 0)
    }

    @Test("Error and unclassified diagnostics preserve source fallback", arguments: [false, true])
    func fatalDiagnosticsShowFallback(missingSeverity: Bool) {
        let model = PicoHostedOpenUIModel(source: source, language: "openui")
        defer { model.dispose() }
        var diagnostic = ["message": "Invalid OpenUI source"]
        if !missingSeverity { diagnostic["severity"] = "error" }
        var failureCount = 0
        model.onError = { _ in failureCount += 1 }
        model.receive(["kind": "error", "payload": [diagnostic], "sourceID": model.sourceID])
        #expect(model.error != nil)
        #expect(failureCount == 1)
        #expect(model.markdown.contains(source))
    }

    @Test("A valid size updates layout through the height callback", .timeLimit(.minutes(1)))
    func validSizePublishesHeight() async {
        let model = PicoHostedOpenUIModel(source: source, language: "openui")
        defer { model.dispose() }
        await withCheckedContinuation { continuation in
            model.onHeightChanged = {
                model.onHeightChanged = nil
                continuation.resume()
            }
            model.receive(["kind": "size", "payload": ["height": 480.2], "sourceID": model.sourceID])
        }
        #expect(model.measuredHeight == 481)
        #expect(model.sizeMessageCount == 1)
        #expect(model.webView == nil)
    }

    private let source = "root = Stack([body])\nbody = TextContent(\"Hello 🧭\")"

    private func waitForHeightChange(of model: PicoHostedOpenUIModel, change: () -> Void) async {
        await withCheckedContinuation { continuation in
            model.onHeightChanged = {
                model.onHeightChanged = nil
                continuation.resume()
            }
            change()
        }
    }
}
#endif
