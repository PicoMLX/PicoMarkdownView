#if os(macOS)
import AppKit
import PicoMarkdownView
import SwiftUI
import WebKit

extension PicoEmbeddedBlockRenderer {
    /// Static, offline previews of closed raw HTML blocks and `html-preview` fences.
    /// Ordinary `html` code fences remain native code. Import PicoMarkdownViewHTML
    /// and opt in using `embeddedBlockRenderers: [.htmlPreview]`.
    public static var htmlPreview: PicoEmbeddedBlockRenderer {
        PicoEmbeddedBlockRenderer(selectors: [.htmlBlock, .fencedCode(language: "html-preview")]) { context in
            // A rejected document keeps the core's native source presentation.
            guard (try? HTMLPreviewPolicy.prepare(source: context.source)) != nil else { return nil }
            return AnyView(HTMLPreview(context: context))
        }
    }
}

@MainActor
private struct HTMLPreview: View {
    let context: PicoEmbeddedBlockContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 1
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                Text(context.source)
                    .font(.system(size: context.bodyFontSize, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HTMLPreviewRepresentable(
                    source: context.source,
                    style: style,
                    onHeight: { height = $0 },
                    onFailure: { failed = true }
                )
                .frame(height: height)
            }
        }
        .frame(width: context.availableWidth, alignment: .leading)
        .overlay {
            if context.isSelected {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.16))
                    .overlay { Rectangle().strokeBorder(Color.accentColor, lineWidth: 1) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityAddTraits(context.isSelected ? .isSelected : [])
    }

    private var style: HTMLPreviewStyle {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        var foreground = "CanvasText"
        appearance?.performAsCurrentDrawingAppearance {
            if let color = NSColor.labelColor.usingColorSpace(.sRGB) {
                foreground = "rgba(\(Int((color.redComponent * 255).rounded())),\(Int((color.greenComponent * 255).rounded())),\(Int((color.blueComponent * 255).rounded())),\(color.alphaComponent))"
            }
        }
        return HTMLPreviewStyle(
            fontSize: Double(context.bodyFontSize),
            fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif",
            foregroundCSS: foreground,
            backgroundCSS: "transparent",
            isDark: colorScheme == .dark
        )
    }
}

@MainActor
private struct HTMLPreviewRepresentable: NSViewRepresentable {
    let source: String
    let style: HTMLPreviewStyle
    let onHeight: (CGFloat) -> Void
    let onFailure: () -> Void

    func makeNSView(context: Context) -> HTMLPreviewContainer {
        HTMLPreviewContainer()
    }

    func updateNSView(_ view: HTMLPreviewContainer, context: Context) {
        view.onHeight = onHeight
        view.onFailure = onFailure
        view.configure(source: source, style: style)
    }

    static func dismantleNSView(_ view: HTMLPreviewContainer, coordinator: ()) {
        view.suspend()
    }
}

/// The stable attachment view retains its measured size, but owns a WebView only
/// while it belongs to a window. Width changes reflow the same DOM without loads.
@MainActor
final class HTMLPreviewContainer: NSView {
    var onHeight: ((CGFloat) -> Void)?
    var onFailure: (() -> Void)?
    var onReady: (() -> Void)?
    private(set) var page: WebPage?
    private var pageHost: NSHostingView<AnyView>?
    private var userContentController: WKUserContentController?
    private var navigationTask: Task<Void, Never>?
    private(set) var measuredHeight: CGFloat = 1
    private(set) var loadCount = 0
    private(set) var isReady = false
    private(set) var hasFailed = false

    private var source = ""
    private var style: HTMLPreviewStyle = .default
    private var document: HTMLPreviewDocument?
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "HTML preview", bundle: .module))
        setAccessibilityHelp(String(localized: "Select this block with the surrounding text to copy its HTML source.", bundle: .module))
    }

    required init?(coder: NSCoder) { nil }

    func configure(source: String, style: HTMLPreviewStyle) {
        guard self.source != source || self.style != style || document == nil else { return }
        self.source = source
        self.style = style
        do {
            document = try HTMLPreviewPolicy.prepare(source: source, style: style)
        } catch {
            fail()
            return
        }
        suspend()
        if window != nil { resume() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { suspend() } else { resume() }
    }

    override func layout() {
        super.layout()
        pageHost?.frame = bounds
    }

    func suspend() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        navigationTask?.cancel()
        navigationTask = nil
        isReady = false
        page?.stopLoading()
        userContentController?.removeScriptMessageHandler(forName: "picoHTMLHeight", contentWorld: .defaultClient)
        userContentController?.removeAllUserScripts()
        userContentController = nil
        pageHost?.removeFromSuperview()
        pageHost = nil
        page = nil
    }

    private func resume() {
        guard page == nil, loadTask == nil, let document, !hasFailed else { return }
        let token = generation
        loadTask = Task { [weak self] in
            do {
                let rules = try await HTMLPreviewContentRules.compiled.value
                guard !Task.isCancelled, let self, self.generation == token, self.window != nil else { return }
                self.install(document: document, rules: rules, token: token)
                self.loadTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.loadTask = nil
                self.fail()
            }
        }
    }

    private func install(document: HTMLPreviewDocument, rules: WKContentRuleList, token: UUID) {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        configuration.suppressesIncrementalRendering = true
        configuration.loadsSubresources = false
        let controller = configuration.userContentController
        controller.add(rules)
        controller.add(HTMLPreviewMessageHandler(owner: self), contentWorld: .defaultClient, name: "picoHTMLHeight")
        controller.addUserScript(WKUserScript(
            source: Self.measurementScript(token: token),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        let page = WebPage(configuration: configuration, navigationDecider: HTMLPreviewNavigationDecider())
        let host = NSHostingView(rootView: AnyView(
            WebView(page)
                .webViewContentBackground(.hidden)
                .webViewTextSelection(.disabled)
                .webViewLinkPreviews(.disabled)
                .webViewMagnificationGestures(.disabled)
                .webViewBackForwardNavigationGestures(.disabled)
                .webViewElementFullscreenBehavior(.disabled)
                .webViewContextMenu { _ in EmptyView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        ))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        host.isHidden = true
        self.page = page
        self.pageHost = host
        self.userContentController = controller
        addSubview(host)
        loadCount += 1
        navigationTask = Task { [weak self] in
            do {
                for try await _ in page.load(html: document.html) {}
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.fail()
            }
        }
    }

    fileprivate func receiveHeight(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              body["token"] as? String == generation.uuidString,
              let value = body["height"] as? NSNumber else { return }
        let height = CGFloat(value.doubleValue)
        guard height.isFinite, height >= 0, height <= HTMLPreviewPolicy.maximumHeight else {
            fail()
            return
        }
        let next = max(HTMLPreviewPolicy.minimumHeight, ceil(height))
        if next != measuredHeight {
            measuredHeight = next
            onHeight?(next)
        }
        pageHost?.isHidden = false
        if !isReady {
            isReady = true
            onReady?()
        }
    }

    private func fail() {
        suspend()
        hasFailed = true
        // Defer SwiftUI state writes out of updateNSView/layout.
        Task { @MainActor [weak self] in self?.onFailure?() }
    }

    private static func measurementScript(token: UUID) -> String {
        """
        (() => {
          const root = document.getElementById('pico-html-content');
          if (!root) return;
          const measure = () => {
            // Author HTML is static, including inline !important animations
            // which can outrank our document's default stylesheet.
            document.getAnimations().forEach(animation => animation.cancel());
            let height = Math.max(root.getBoundingClientRect().height, root.scrollHeight);
            if (Array.from(root.querySelectorAll('*')).some(element => {
              const rect = element.getBoundingClientRect();
              const visible = rect.width > 0 && rect.height > 0 && getComputedStyle(element).visibility !== 'hidden';
              // Viewport-fixed content has no intrinsic document height, even
              // when ordinary flowing text precedes it. Show source safely.
              return visible && (height === 0 || getComputedStyle(element).position === 'fixed');
            })) height = \(HTMLPreviewPolicy.maximumHeight + 1);
            window.webkit.messageHandlers.picoHTMLHeight.postMessage({
              token: '\(token.uuidString)', height
            });
          };
          new ResizeObserver(measure).observe(root);
          measure();
          document.fonts.ready.then(measure);
        })();
        """
    }
}

@MainActor
private final class HTMLPreviewMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: HTMLPreviewContainer?
    init(owner: HTMLPreviewContainer) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receiveHeight(message)
    }
}

private struct HTMLPreviewNavigationDecider: WebPage.NavigationDeciding {
    private var awaitingInitialNavigation = true

    mutating func decidePolicy(for action: WebPage.NavigationAction,
                               preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        preferences.allowsContentJavaScript = false
        // Each page permits its one app-generated HTML document. No subsequent
        // navigation, popup, download, or local/remote destination is allowed.
        guard awaitingInitialNavigation, action.navigationType == .other,
              action.target?.isMainFrame == true,
              action.request.url?.absoluteString == "about:blank",
              !action.shouldPerformDownload else { return .cancel }
        awaitingInitialNavigation = false
        return .allow
    }
}

@MainActor
private enum HTMLPreviewContentRules {
    static let compiled = Task<WKContentRuleList, any Error> { @MainActor in
        // No network, bundle, local file, or data subresources. There are no
        // author scripts/images/fonts/media in the static HTML subset.
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "PicoMarkdownViewHTML.Offline.v1", encodedContentRuleList: rules
            ) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        return list
    }
}
#endif
