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
        var renderer = PicoEmbeddedBlockRenderer(selectors: [.htmlBlock, .fencedCode(language: "html-preview")]) { context in
            // Only a cheap size preflight runs in the attachment factory.
            // Parsing/sanitization starts off the main actor when presented.
            guard !context.source.isEmpty,
                  context.source.utf8.count <= HTMLPreviewPolicy.maximumSourceBytes else { return nil }
            let preparation = HTMLPreviewPreparation(source: context.source)
            return AnyView(HTMLPreview(context: context, preparation: preparation))
        }
        renderer.showsLoadingPlaceholder = true
        return renderer
    }
}

@MainActor
struct HTMLPreview: View {
    let context: PicoEmbeddedBlockContext
    let preparation: HTMLPreviewPreparation
    let loadingState: PicoEmbeddedLoadingState
    @Environment(\.colorScheme) private var colorScheme
    @State private var failed = false
    @State private var isReady = false

    init(context: PicoEmbeddedBlockContext, preparation: HTMLPreviewPreparation) {
        self.context = context
        self.preparation = preparation
        self.loadingState = context.loadingState ?? PicoEmbeddedLoadingState()
    }

    var body: some View {
        let cachedHeight = preparation.measuredHeight
        Group {
            if failed {
                Text(context.source)
                    .font(.system(size: context.bodyFontSize, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(height: cachedHeight ?? PicoEmbeddedLoadingState.height)
                        .accessibilityHidden(true)
                    if !isReady {
                        PicoEmbeddedLoadingView(state: loadingState, isSelected: false)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .background(alignment: .topLeading) {
            if !failed {
                HTMLPreviewRepresentable(
                    preparation: preparation,
                    style: style,
                    onReadinessChanged: updateReadiness,
                    onFailure: showSourceFallback
                )
                .opacity(isReady ? 1 : 0)
                .accessibilityHidden(!isReady)
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

    private func updateReadiness(_ ready: Bool) {
        isReady = ready
        if ready { loadingState.finishLoading() }
        else if !failed { loadingState.startLoading() }
    }

    private func showSourceFallback() {
        isReady = false
        failed = true
        loadingState.finishLoading()
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
    let preparation: HTMLPreviewPreparation
    let style: HTMLPreviewStyle
    let onReadinessChanged: (Bool) -> Void
    let onFailure: () -> Void

    func makeNSView(context: Context) -> HTMLPreviewContainer {
        HTMLPreviewContainer(preparation: preparation)
    }

    func updateNSView(_ view: HTMLPreviewContainer, context: Context) {
        view.onFailure = onFailure
        view.onReadinessChanged = onReadinessChanged
        view.configure(source: preparation.source, style: style)
    }

    static func dismantleNSView(_ view: HTMLPreviewContainer, coordinator: ()) {
        view.suspend()
    }
}

/// The attachment keeps prepared content and size while offscreen. Only a
/// visible or focused presentation owns a WebPage; width changes reflow its DOM.
@MainActor
final class HTMLPreviewContainer: NSView {
    var onHeight: ((CGFloat) -> Void)?
    var onFailure: (() -> Void)?
    var onReady: (() -> Void)?
    var onReadinessChanged: ((Bool) -> Void)?
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
    private var preparation: HTMLPreviewPreparation?
    private let prepare: HTMLPreviewPreparation.Prepare
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    var pendingPresentation: Task<Void, Never>? { loadTask }
    private(set) var pendingFailureNotification: Task<Void, Never>?
    private lazy var viewport = HTMLPreviewViewport(view: self) { [weak self] in
        self?.updatePresentationForViewport()
    }
    var pendingVisibilityUpdate: Task<Void, Never>? { viewport.pendingUpdate }
    var isInViewport: Bool { viewport.isEligible(pinning: pageHost) }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(preparation: HTMLPreviewPreparation? = nil,
         prepare: @escaping HTMLPreviewPreparation.Prepare = { source in
             try await HTMLPreviewPolicy.prepareOffMainActor(source: source)
         }) {
        self.preparation = preparation
        self.prepare = prepare
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "HTML preview", bundle: .module))
        setAccessibilityHelp(String(localized: "Select this block with the surrounding text to copy its HTML source.", bundle: .module))
    }

    required init?(coder: NSCoder) { nil }

    func configure(source: String, style: HTMLPreviewStyle) {
        guard self.source != source || self.style != style || preparation == nil else { return }
        if preparation?.source != source {
            preparation = HTMLPreviewPreparation(source: source, prepare: prepare)
            hasFailed = false
        }
        self.source = source
        self.style = style
        if let cachedHeight = preparation?.measuredHeight { measuredHeight = cachedHeight }
        suspend()
        viewport.refreshHierarchy()
        viewport.scheduleUpdate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            viewport.stop()
            suspend()
        } else {
            viewport.refreshHierarchy()
            viewport.scheduleUpdate()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        viewport.refreshHierarchy()
        viewport.scheduleUpdate()
    }

    override func viewDidHide() {
        super.viewDidHide()
        viewport.scheduleUpdate()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        viewport.scheduleUpdate()
    }

    override func layout() {
        super.layout()
        pageHost?.frame = bounds
        viewport.refreshHierarchy()
        viewport.scheduleUpdate()
    }

    private func updatePresentationForViewport() {
        if isInViewport { resume() }
        else if page != nil || loadTask != nil || navigationTask != nil || isReady { suspend() }
    }

    func suspend() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        navigationTask?.cancel()
        navigationTask = nil
        isReady = false
        let token = generation
        // configure/dismantle can run during SwiftUI's update pass. Publish
        // readiness later and discard notifications from an older generation.
        Task { @MainActor [weak self] in
            guard let self, self.generation == token else { return }
            self.onReadinessChanged?(self.isReady)
        }
        page?.stopLoading()
        userContentController?.removeScriptMessageHandler(forName: "picoHTMLHeight", contentWorld: .defaultClient)
        userContentController?.removeAllUserScripts()
        userContentController = nil
        pageHost?.removeFromSuperview()
        pageHost = nil
        page = nil
    }

    private func resume() {
        guard page == nil, loadTask == nil, let preparation, !hasFailed, isInViewport else { return }
        let token = generation
        let style = style
        let preparationTask = preparation.resultTask()
        loadTask = Task { [weak self] in
            defer { if self?.generation == token { self?.loadTask = nil } }
            do {
                let content = try await preparationTask.value
                guard !Task.isCancelled, self?.generation == token, self?.isInViewport == true else { return }
                let rules = try await HTMLPreviewContentRules.compiled.value
                guard !Task.isCancelled, let self, self.generation == token, self.isInViewport else { return }
                self.install(document: content.document(style: style), rules: rules, token: token)
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
        host.layoutSubtreeIfNeeded()
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
        guard isInViewport else { updatePresentationForViewport(); return }
        // WebKit can deliver its first layout before SwiftUI applies the host
        // width. Wait for the resize observation at the actual text width.
        guard let width = body["width"] as? NSNumber,
              width.doubleValue.isFinite,
              abs(CGFloat(width.doubleValue) - bounds.width) <= 2 else { return }
        let height = CGFloat(value.doubleValue)
        guard height.isFinite, height >= 0, height <= HTMLPreviewPolicy.maximumHeight else {
            fail()
            return
        }
        let next = max(HTMLPreviewPolicy.minimumHeight, ceil(height))
        preparation?.retainMeasurement(next)
        if next != measuredHeight {
            measuredHeight = next
            onHeight?(next)
        }
        pageHost?.isHidden = false
        if !isReady {
            isReady = true
            onReadinessChanged?(true)
            onReady?()
        }
    }

    func fail() {
        suspend()
        hasFailed = true
        // Defer SwiftUI state writes out of updateNSView/layout, without
        // allowing a discarded source's failure to affect a replacement.
        let token = generation
        pendingFailureNotification = Task { @MainActor [weak self] in
            guard let self, self.generation == token, self.hasFailed else { return }
            self.onFailure?()
        }
    }

    private static func measurementScript(token: UUID) -> String {
        """
        (() => {
          const body = document.body;
          if (!body) return;
          // Neutralize declarations once, before exposing this page. A reset
          // selector cannot defeat stronger author !important/hover rules.
          // Author scripts and external sheets are disabled, so later hover,
          // focus or media changes can only activate these same static rules.
          const motionDisabled = (() => {
            const stripDeclaration = style => {
              for (const name of Array.from(style)) {
                if (/^(?:-webkit-)?(?:animation|transition)(?:-|$)/.test(name.toLowerCase())) {
                  style.removeProperty(name);
                }
              }
            };
            const stripRules = rules => {
              for (const rule of Array.from(rules)) {
                if (rule.style) stripDeclaration(rule.style);
                if (rule.cssRules) stripRules(rule.cssRules);
              }
            };
            try {
              for (const sheet of Array.from(document.styleSheets)) {
                if (sheet.ownerNode?.hasAttribute('data-pico-static-motion')) continue;
                stripRules(sheet.cssRules);
              }
              for (const element of document.querySelectorAll('*')) {
                if (element.style) stripDeclaration(element.style);
              }
              document.getAnimations().forEach(animation => animation.cancel());
              return true;
            } catch {
              // A page whose styles cannot be made static must use source
              // fallback, rather than hanging the loader or exposing motion.
              document.getAnimations().forEach(animation => animation.cancel());
              return false;
            }
          })();
          const measure = () => {
            const bodyRect = body.getBoundingClientRect();
            const bodyStyle = getComputedStyle(body);
            const trailingBodySpacing = (parseFloat(bodyStyle.paddingBottom) || 0)
              + (parseFloat(bodyStyle.borderBottomWidth) || 0);
            // The app-owned doctype keeps standards mode: body.scrollHeight
            // is intrinsic overflow, unlike the viewport-floored root metric.
            // Keep the border-box path for borders and global body offsets.
            const bodyFlowBottom = Math.max(0, bodyRect.bottom + window.scrollY);
            const bodyOverflowBottom = bodyRect.top + window.scrollY
              + (parseFloat(bodyStyle.borderTopWidth) || 0) + body.scrollHeight;
            let height = Math.max(bodyFlowBottom, bodyOverflowBottom);
            // This static preview has no horizontal scrolling. Allow one CSS
            // pixel for fractional layout rounding, then fall back to source
            // when a body or visible descendant extends outside the viewport.
            const outsideHorizontalViewport = rect => rect.left + window.scrollX < -1
              || rect.right + window.scrollX > window.innerWidth + 1;
            const hasTransform = style => ['transform', 'translate', 'rotate', 'scale']
              .some(property => style[property] && style[property] !== 'none');
            const unsupportedGeneratedContent = element => ['::before', '::after'].some(selector => {
              const pseudo = getComputedStyle(element, selector);
              const active = pseudo.content !== 'none' && pseudo.content !== 'normal'
                && pseudo.display !== 'none' && !['hidden', 'collapse'].includes(pseudo.visibility);
              if (!active) return false;
              // Element rectangles cannot describe positioned/transformed
              // generated boxes or content attached outside the body shell.
              return element === document.documentElement || pseudo.position !== 'static'
                || hasTransform(pseudo);
            });
            // Enlarging the viewport cannot reveal content above document
            // origin, including a bottom-anchored absolute body.
            // scrollWidth also includes static generated boxes that have no
            // element rectangle. This validates width only; it never sets height.
            let unsupported = !motionDisabled || bodyStyle.position === 'fixed' || bodyRect.top + window.scrollY < 0
              || outsideHorizontalViewport(bodyRect) || body.scrollWidth > window.innerWidth + 1
              // A body's own transforms do not scale its local scroll metrics.
              || (body.scrollHeight > body.clientHeight + 1 && hasTransform(bodyStyle));
            const suppressed = new Set();
            for (const element of [document.documentElement, body, ...body.querySelectorAll('*')]) {
              const style = element === body ? bodyStyle : getComputedStyle(element);
              if (style.display === 'none' || suppressed.has(element.parentElement)) {
                suppressed.add(element);
                continue;
              }
              // Check before geometry: an empty box can still generate a
              // visible pseudo-element, while display:none ancestors cannot.
              if (unsupportedGeneratedContent(element)) unsupported = true;
              if (element === document.documentElement || element === body) continue;
              const rect = element.getBoundingClientRect();
              const visible = rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden';
              if (!visible) continue;
              // Viewport-fixed or heightless content has no usable intrinsic
              // document extent. Show its source instead of clipping it.
              if (bodyFlowBottom === 0 || style.position === 'fixed' || rect.top + window.scrollY < 0
                || outsideHorizontalViewport(rect)) unsupported = true;
              height = Math.max(height, rect.bottom + window.scrollY + trailingBodySpacing);
            }
            if (unsupported) height = \(HTMLPreviewPolicy.maximumHeight + 1);
            window.webkit.messageHandlers.picoHTMLHeight.postMessage({
              token: '\(token.uuidString)', height, width: window.innerWidth
            });
          };
          const observer = new ResizeObserver(measure);
          observer.observe(body, { box: 'border-box' });
          // Fixed-size body boxes may not resize with their viewport.
          window.addEventListener('resize', measure);
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
