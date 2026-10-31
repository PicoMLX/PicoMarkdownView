#if os(macOS)
import AppKit
import CoreFoundation
import Foundation
import Observation
import PicoOpenUIRuntime
@preconcurrency import WebKit

/// One completed source occurrence owns its browser and form state.
@MainActor
@Observable
final class PicoHostedOpenUIModel: NSObject, WKNavigationDelegate {
    static let initialHeight: CGFloat = 350
    static let maximumHeight: CGFloat = 20_000

    let source: String
    let language: String?
    let sourceID = UUID().uuidString
    private(set) var measuredHeight = initialHeight
    private(set) var textScale: CGFloat = 1
    private(set) var isReady = false
    private(set) var isDisposed = false
    private var runtimeError: String?
    private var rendererError: String?
    private var heightError: String?
    var error: String? { runtimeError ?? rendererError ?? heightError }
    private(set) var lastAction: PicoOpenUIActionEvent?
    private(set) var webViewCreationCount = 0
    private(set) var renderCount = 0
    private(set) var sizeMessageCount = 0
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private(set) var scrollRegions: [PicoHostedOpenUIScrollRegion] = []
    @ObservationIgnored var onAction: ((PicoOpenUIActionEvent) -> Void)?
    @ObservationIgnored var onHeightChanged: (() -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?
    @ObservationIgnored private var assetRoot: URL?
    @ObservationIgnored private var colorScheme = "light"
    @ObservationIgnored private var lastContentHeight: CGFloat?
    @ObservationIgnored private var pendingHeight: CGFloat?
    @ObservationIgnored private var heightScheduled = false
    @ObservationIgnored private var renderGeneration: UInt64 = 0
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var scrollRegionRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var readyTimeout: Task<Void, Never>?

    init(source: String, language: String?) {
        self.source = source
        self.language = language
        super.init()
    }

    isolated deinit {
        renderTask?.cancel()
        scrollRegionRefreshTask?.cancel()
        readyTimeout?.cancel()
        if let webView {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "picoOpenUI")
            (webView as? PicoHostedOpenUIWebView)?.stopForwardingScroll()
            webView.stopLoading()
        }
    }

    var markdown: String {
        let info = language ?? "openui"
        let marker: Character = info.contains("`") ? "~" : "`"
        var longest = 0
        var current = 0
        for character in source {
            if character == marker { current += 1; longest = max(longest, current) }
            else { current = 0 }
        }
        let fence = String(repeating: String(marker), count: max(3, longest + 1))
        return fence + info + "\n" + source + (source.hasSuffix("\n") ? "" : "\n") + fence
    }

    /// Creation is deferred until SwiftUI makes the actual attachment content.
    func makeWebView() -> WKWebView? {
        guard !isDisposed else { return nil }
        if let webView { return webView }
        guard let index = PicoOpenUIResources.indexURL else {
            setError("The OpenUI renderer is unavailable.")
            return nil
        }
        assetRoot = index.deletingLastPathComponent().standardizedFileURL
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let messages = WKUserContentController()
        messages.add(PicoHostedOpenUIMessageBridge(model: self), name: "picoOpenUI")
        configuration.userContentController = messages
        let view = PicoHostedOpenUIWebView(frame: NSRect(x: 0, y: 0, width: 600, height: Self.initialHeight),
                                          configuration: configuration)
        view.navigationDelegate = self
        view.pageZoom = textScale
        view.updateScrollRegions(scrollRegions, pageZoom: textScale)
        view.underPageBackgroundColor = .clear
        view.setAccessibilityLabel("Interactive OpenUI content")
        #if DEBUG
        view.isInspectable = true
        #endif
        webView = view
        webViewCreationCount += 1
        view.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        readyTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, !self.isDisposed, !self.isReady else { return }
            self.setError("The OpenUI renderer could not start.")
        }
        return view
    }

    func updateAppearance(dark: Bool) {
        let next = dark ? "dark" : "light"
        guard colorScheme != next else { return }
        colorScheme = next
        if isReady { render() }
    }

    /// Zoom is native WebKit presentation, not a new OpenUI source delivery.
    /// Keep CSS measurements separate because pageZoom changes points per CSS px.
    func updateTextScale(_ scale: CGFloat) {
        guard !isDisposed, scale.isFinite, scale > 0, textScale != scale else { return }
        textScale = scale
        setScrollRegions([])
        webView?.pageZoom = scale
        refreshScrollRegions()
        if let height = lastContentHeight { acceptContentHeight(height) }
    }

    func receive(_ body: Any, isMainFrame: Bool = true) {
        guard !isDisposed, isMainFrame, let envelope = body as? [String: Any],
              let kind = envelope["kind"] as? String else { return }
        if kind == "ready" {
            if let incoming = envelope["sourceID"], !(incoming is NSNull) {
                guard incoming as? String == sourceID else { return }
            }
        } else {
            guard envelope["sourceID"] as? String == sourceID else { return }
        }
        let payload = envelope["payload"]
        switch kind {
        case "ready":
            guard !isReady else { return }
            isReady = true
            runtimeError = nil
            readyTimeout?.cancel()
            readyTimeout = nil
            render()
        case "size":
            let value = (payload as? [String: Any])?["height"] as? Double
            guard let value, value.isFinite, value > 0 else { return }
            sizeMessageCount += 1
            acceptContentHeight(value)
        case "scrollRegions":
            receiveScrollRegions(payload)
        case "action":
            guard let payload, JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload),
                  let event = try? JSONDecoder().decode(PicoOpenUIActionEvent.self, from: data) else { return }
            lastAction = event
            onAction?(event)
        case "error":
            if let diagnostics = payload as? [Any], !diagnostics.contains(where: { value in
                guard let item = value as? [String: Any], let severity = item["severity"] as? String else { return true }
                return !["warning", "info"].contains(severity.lowercased())
            }) { rendererError = nil }
            else {
                let message = "OpenUI could not display this content."
                rendererError = message
                onError?(message)
            }
        default: break
        }
    }

    private func receiveScrollRegions(_ payload: Any?) {
        guard let records = payload as? [[String: Any]], records.count <= 64 else {
            setScrollRegions([])
            return
        }
        var regions: [PicoHostedOpenUIScrollRegion] = []
        regions.reserveCapacity(records.count)
        for record in records {
            func number(_ key: String) -> Double? {
                guard let value = record[key] as? NSNumber,
                      CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
                return value.doubleValue
            }
            func boolean(_ key: String) -> Bool? {
                guard let value = record[key] as? NSNumber,
                      CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
                return value.boolValue
            }
            guard let x = number("x"), let y = number("y"),
                  let width = number("width"), let height = number("height"),
                  x >= 0, y >= 0, width > 0, height > 0,
                  x + width <= 1_000_000, y + height <= 1_000_000,
                  let up = boolean("canScrollUp"), let down = boolean("canScrollDown") else {
                setScrollRegions([])
                return
            }
            regions.append(PicoHostedOpenUIScrollRegion(rect: CGRect(x: x, y: y, width: width, height: height),
                                                       canScrollUp: up, canScrollDown: down))
        }
        setScrollRegions(regions)
    }

    private func setScrollRegions(_ regions: [PicoHostedOpenUIScrollRegion]) {
        scrollRegions = regions
        (webView as? PicoHostedOpenUIWebView)?.updateScrollRegions(regions, pageZoom: textScale)
    }

    private func refreshScrollRegions() {
        scrollRegionRefreshTask?.cancel()
        guard !isDisposed, isReady, let webView else { return }
        let scale = textScale
        scrollRegionRefreshTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, !self.isDisposed, self.textScale == scale,
                  !Task.isCancelled else { return }
            _ = try? await webView.callAsyncJavaScript("window.dispatchEvent(new Event('resize')); return true;",
                arguments: [:], in: nil, contentWorld: .page)
        }
    }

    private func acceptContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        lastContentHeight = height
        let points = height * textScale
        guard points.isFinite, points <= Self.maximumHeight else {
            let message = "This OpenUI content is too tall to display inline."
            heightError = message
            onError?(message)
            return
        }
        heightError = nil
        pendingHeight = max(80, ceil(points))
        scheduleHeight()
    }

    private func scheduleHeight() {
        guard !heightScheduled else { return }
        heightScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.heightScheduled = false
            guard !self.isDisposed, let next = self.pendingHeight,
                  abs(next - self.measuredHeight) > 1 else { return }
            self.measuredHeight = next
            self.onHeightChanged?()
        }
    }

    private func render() {
        guard !isDisposed, isReady, let webView else { return }
        renderGeneration &+= 1
        let generation = renderGeneration
        renderTask?.cancel()
        let options: [String: Any] = ["source": source, "sourceID": sourceID,
                                    "colorScheme": colorScheme, "isStreaming": false]
        renderCount += 1
        renderTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, !self.isDisposed,
                  self.renderGeneration == generation, !Task.isCancelled else { return }
            do {
                _ = try await webView.callAsyncJavaScript("return window.picoOpenUI.render(options);",
                    arguments: ["options": options], in: nil, contentWorld: .page)
            } catch {
                guard !self.isDisposed, self.renderGeneration == generation, !Task.isCancelled else { return }
                self.setError("The OpenUI renderer could not display this content.")
            }
        }
    }

    private func setError(_ message: String) {
        guard !isDisposed else { return }
        runtimeError = message
        onError?(message)
    }

    @discardableResult
    func copySource() -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(source, forType: .string)
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        setScrollRegions([])
        renderGeneration &+= 1
        renderTask?.cancel()
        renderTask = nil
        scrollRegionRefreshTask?.cancel()
        scrollRegionRefreshTask = nil
        readyTimeout?.cancel()
        readyTimeout = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "picoOpenUI")
        (webView as? PicoHostedOpenUIWebView)?.stopForwardingScroll()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        onAction = nil
        onHeightChanged = nil
        onError = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        setError("The OpenUI renderer could not be loaded.")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        setError("The OpenUI renderer could not be loaded.")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        setError("The OpenUI renderer stopped. Copy the source to keep this content.")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !isDisposed, let url = navigationAction.request.url else { return .cancel }
        if url.absoluteString == "about:blank" { return .allow }
        guard url.isFileURL, let root = assetRoot else { return .cancel }
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root.path + "/") ? .allow : .cancel
    }
}

@MainActor
private final class PicoHostedOpenUIMessageBridge: NSObject, WKScriptMessageHandler {
    weak var model: PicoHostedOpenUIModel?
    init(model: PicoHostedOpenUIModel) { self.model = model }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let model, message.webView === model.webView else { return }
        model.receive(message.body, isMainFrame: message.frameInfo.isMainFrame)
    }
}
#endif
