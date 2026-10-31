//
//  MarkdownView.swift
//  MarkdownExample
//
//  Created by Ronald Mannak on 10/15/25.
//

import SwiftUI
import Observation
import PicoMarkdownView
import WebKit

struct MarkdownView: View {

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let webURL: URL
    @State private var markdown: String?
    @State private var loadError: String?
    @State private var streamPacing = ExampleStreamPacing()
    private let localPath: String
    private let tagPrefixes: Set<TagPrefix>
    private let inputID: UUID
    private let isLargeFixture: Bool
    private let svgRenderingEnabled: Bool
#if os(macOS)
    private var imageTapHandler: (@MainActor (MarkdownImageActivation) -> Void)?
#endif
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isAutoScrolling = true
    @State private var autoScrollSuppressionDeadline: ContinuousClock.Instant?

    // Tag/link interaction readouts driven by PicoMarkdownView's callbacks.
    // Tag and link hover are tracked separately: hovering a tag also reports a
    // nil link-hover (and vice versa), so a single combined string would get
    // clobbered by the "exit" of the other source.
    @State private var lastTappedTag: TagReference?
    @State private var tagHoverReadout: String?
    @State private var linkHoverReadout: String?
    @State private var contentSize: CGSize?
    @State private var lastOpenUIAction: String?

    private let autoScrollClock = ContinuousClock()

    init(_ example: MarkdownExample) {
        self.webURL = example.webURL
        self.localPath = example.localPath
        self._markdown = State(initialValue: example.isLargeFixture ? nil : try! example.loadMarkdown())
        self.tagPrefixes = example.tagPrefixes
        self.inputID = example.id
        self.isLargeFixture = example.isLargeFixture
        self.svgRenderingEnabled = example.svgRenderingEnabled
    }

#if os(macOS)
    func onImageTap(_ handler: @escaping @MainActor (MarkdownImageActivation) -> Void) -> Self {
        var view = self
        view.imageTapHandler = handler
        return view
    }
#endif

    var body: some View {
        Group {
            if let markdown {
                loadedContent(markdown)
            } else if let loadError {
                ContentUnavailableView("Unable to load gallery", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                ProgressView("Loading gallery…")
            }
        }
        .task(id: inputID) {
            guard markdown == nil, isLargeFixture else { return }
            do {
                let text = try await loadGalleryMarkdown(from: localPath)
                try Task.checkCancellation()
                markdown = text
            } catch is CancellationError {
                return
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func loadedContent(_ markdown: String) -> some View {
        HStack {
            TabView {
                Tab("Markdown", systemImage: "square.fill.text.grid.1x2") {
                    VStack(spacing: 0) {
                        tagStatusPanel
                        ScrollView {
                            // Extracted into an Equatable subview with no dynamic
                            // properties so scrollPosition state changes don't
                            // re-evaluate PicoMarkdownView's body (restarting the stream).
                            StreamingMarkdownContent(markdown: markdown,
                                                     inputID: inputID,
                                                     pacing: streamPacing,
                                                     tagPrefixes: tagPrefixes,
                                                     svgRenderingEnabled: svgRenderingEnabled,
                                                     onOpenURL: { openURL($0) },
                                                     onTagTap: { lastTappedTag = $0 },
                                                     onTagHover: { tagHoverReadout = $0 },
                                                     onLinkHover: { linkHoverReadout = $0 },
                                                     onContentSize: { handleContentSizeChange($0) },
                                                     onOpenUIAction: { lastOpenUIAction = $0.humanFriendlyMessage })
#if os(macOS)
                                .onImageTap(imageTapHandler)
#endif
                                .equatable()
                        }
                        .scrollPosition($scrollPosition)
                        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                            let offsetY = geometry.contentOffset.y
                            let visibleBottom = offsetY + geometry.containerSize.height
                            let isNearBottom = geometry.contentSize.height - visibleBottom < AutoScrollConfig.nearBottomThreshold
                            return ScrollMetrics(offsetY: offsetY, isNearBottom: isNearBottom,
                                                 contentHeight: isLargeFixture ? geometry.contentSize.height : 0)
                        } action: { oldMetrics, newMetrics in
                            handleScrollMetricsChange(from: oldMetrics, to: newMetrics)
                        }
                    }
                }
                if !isLargeFixture {
                    Tab("Diagnostics", systemImage: "ladybug") {
                        ScrollView {
                            PicoMarkdownDebugView(text: markdown)
                        }
                    }
                    Tab("Plain Text", systemImage: "text.alignleft") {
                        ScrollView {
                            Text(markdown)
                        }
                    }
                }
            }
            .textSelection(.enabled)

            WebView(url: webURL) { configuration in
                // To shut up Nyan Cat
                configuration.mediaTypesRequiringUserActionForPlayback = .all
            }
                .id(webURL)
        }
    }

    /// Live readout of the inline-tag / link / content-size callbacks, shown
    /// above the rendered Markdown so the demo makes each callback observable.
    @ViewBuilder
    private var tagStatusPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if let tag = lastTappedTag {
                    Label {
                        Text("Selected Tag: \(Text(verbatim: "\(tag.prefix)\(tag.identifier)").bold())")
                    } icon: {
                        Image(systemName: "hand.tap")
                    }
                    .font(.callout)
                } else {
                    Label("Select a tag to see its details.", systemImage: "hand.tap")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                streamSpeedButton
            }

#if os(macOS)
            if let lastOpenUIAction {
                Label {
                    Text(verbatim: lastOpenUIAction)
                } icon: {
                    Image(systemName: "rectangle.and.hand.point.up.left")
                }
                    .font(.callout)
                    .accessibilityLabel("OpenUI action: \(lastOpenUIAction)")
            }
#endif
            HStack(spacing: 16) {
                #if os(macOS)
                let hover = tagHoverReadout ?? linkHoverReadout
                Label(hover ?? String(localized: "Point to a tag or link."), systemImage: "cursorarrow.rays")
                    .foregroundStyle(hover == nil ? .secondary : .primary)
                #endif
                if let contentSize {
                    Label("Content Size: \(Int(contentSize.width.rounded())) × \(Int(contentSize.height.rounded())) pt",
                          systemImage: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var streamSpeedButton: some View {
        @Bindable var pacing = streamPacing
        return Toggle(isOn: $pacing.isFast) {
            Text("10×", tableName: "ExampleStreaming")
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(Text("Stream the example at ten times the normal speed.", tableName: "ExampleStreaming"))
    }

    /// Content-growth → scroll-to-bottom, driven by PicoMarkdownView's
    /// `onContentSize` callback for ordinary examples. The gallery follows the
    /// scroll view's applied geometry below because its large code-to-chart
    /// replacements can shrink the document. Also feeds the status readout.
    private func handleContentSizeChange(_ size: CGSize) {
        contentSize = size
        guard !isLargeFixture, isAutoScrolling else { return }
        // Suppress the brief window after our own programmatic scroll so its
        // animation frames aren't later misread by the scroll observer as a
        // user scroll-up.
        autoScrollSuppressionDeadline = autoScrollClock.now.advanced(by: AutoScrollConfig.suppressionWindow)
        scrollToBottom(animated: !reduceMotion)
    }

    /// Scroll position pauses/resumes following. The gallery additionally follows
    /// height changes after SwiftUI has applied them to the scroll view.
    private func handleScrollMetricsChange(from old: ScrollMetrics, to new: ScrollMetrics) {
        if isLargeFixture {
            // A closed fence can replace thousands of source lines with one chart.
            // Follow only once SwiftUI knows the new height, not from the earlier
            // NSTextView size callback. Reflow is not a user scroll gesture.
            let positionedByUser = scrollPosition.isPositionedByUser
            if positionedByUser {
                isAutoScrolling = new.isNearBottom
            }
            if isAutoScrolling, positionedByUser || new.contentHeight != old.contentHeight {
                scrollToBottom(animated: false)
            }
            return
        }
        let scrollDeltaY = new.offsetY - old.offsetY

        let now = autoScrollClock.now
        // Ignore transient "not at bottom" snapshots while our own short scroll animation catches up.
        let suppressionActive = autoScrollSuppressionDeadline.map { $0 > now } ?? false
        if !suppressionActive, autoScrollSuppressionDeadline != nil {
            autoScrollSuppressionDeadline = nil
        }

        if new.isNearBottom {
            if !isAutoScrolling {
                isAutoScrolling = true
            }
            return
        }

        if suppressionActive {
            if scrollDeltaY < -AutoScrollConfig.manualCancelDeltaThreshold {
                if isAutoScrolling {
                    isAutoScrolling = false
                }
                autoScrollSuppressionDeadline = nil
            }
            return
        }

        if isAutoScrolling {
            isAutoScrolling = false
        }
    }

    private func scrollToBottom(animated: Bool) {
        if animated {
            withAnimation(.smooth(duration: AutoScrollConfig.animationDuration)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        } else {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }
}

private struct ScrollMetrics: Equatable {
    let offsetY: CGFloat
    let isNearBottom: Bool
    let contentHeight: CGFloat
}

private enum AutoScrollConfig {
    static let nearBottomThreshold: CGFloat = 80
    static let manualCancelDeltaThreshold: CGFloat = 3
    static let animationDuration: Double = 0.10
    static let suppressionWindow: Duration = .milliseconds(140)
}

/// Equatable subview with ZERO DynamicProperty (@Environment, @State, etc.).
/// SwiftUI compares the stable input identity and its SVG presentation option,
/// skipping body re-evaluation when the parent re-renders due to scroll-position
/// changes so the stream does not restart. The closures and `tagPrefixes` are
/// excluded from `==` — they're stable for a given document.
private struct StreamingMarkdownContent: View, Equatable {
    let markdown: String
    let inputID: UUID
    let pacing: ExampleStreamPacing
    let tagPrefixes: Set<TagPrefix>
    let svgRenderingEnabled: Bool
    let onOpenURL: (URL) -> Void
    let onTagTap: (TagReference) -> Void
    let onTagHover: (String?) -> Void
    let onLinkHover: (String?) -> Void
    let onContentSize: (CGSize) -> Void
    let onOpenUIAction: (PicoOpenUIActionEvent) -> Void
#if os(macOS)
    var imageTapHandler: (@MainActor (MarkdownImageActivation) -> Void)? = nil

    func onImageTap(_ handler: (@MainActor (MarkdownImageActivation) -> Void)?) -> Self {
        var view = self
        view.imageTapHandler = handler
        return view
    }
#endif

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.inputID == rhs.inputID && lhs.svgRenderingEnabled == rhs.svgRenderingEnabled
    }

    var body: some View {
        PicoMarkdownView(stream: { [markdown, pacing] in
            wordStream(from: markdown, pacing: pacing)
        }, theme: exampleTheme, tagPrefixes: tagPrefixes)
#if os(macOS)
            .onImageTap { [imageTapHandler] image in imageTapHandler?(image) }
#endif
            .id(inputID)
            .textSelection(.enabled)
            .modifier(MentionPreviewPresenter(inputID: inputID,
                                               onTagTap: onTagTap,
                                               onTagHover: onTagHover))
            .padding()
            .onOpenLink { [onOpenURL] url in
                guard !MockLinkContextMenus.isDemoURL(url) else { return .handled }
                onOpenURL(url)
                return .handled
            }
            .onLinkHover { [onLinkHover] url, _ in
                onLinkHover(url.map { String(localized: "Link: \($0.absoluteString)") })
            }
#if os(macOS)
            .onOpenUIAction(onOpenUIAction)
#endif
            .onContentSize { [onContentSize] size in
                onContentSize(size)
            }
#if os(macOS)
            .linkContextMenu(MockLinkContextMenus.customize)
#endif
    }

    private var exampleTheme: MarkdownRenderTheme {
#if os(macOS)
        .default()
            .withMermaidRendering(.bestEffortDebounced(milliseconds: 200))
            .withSVGRendering(svgRenderingEnabled)
            .withOpenUIRendering()
#else
        .default()
#endif
    }
}

/// The producer reads the live setting without changing the stream's identity.
@MainActor
@Observable
private final class ExampleStreamPacing {
    var isFast = false

    var wordDelay: Duration {
        .nanoseconds(isFast ? 3_333_333 : 33_333_333)
    }
}

/// Preserves word chunks at approximately 30 or 300 words per second.
private func wordStream(from markdown: String, pacing: ExampleStreamPacing) -> AsyncStream<String> {
    AsyncStream<String> { continuation in
        let task = Task {
            var chunk = ""
            var wordSeen = false
            for char in markdown {
                guard !Task.isCancelled else { break }
                chunk.append(char)
                if char.isWhitespace {
                    if wordSeen {
                        continuation.yield(chunk)
                        chunk = ""
                        wordSeen = false
                        try? await Task.sleep(for: pacing.wordDelay)
                    }
                } else {
                    wordSeen = true
                }
            }
            if !chunk.isEmpty && !Task.isCancelled {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

/// The full corpus is a deliberately large test fixture. Inflate it away from
/// the UI actor; ordinary examples retain their existing small-file path.
@concurrent
private func loadGalleryMarkdown(from path: String) async throws -> String {
    try Task.checkCancellation()
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let decoded = try (data as NSData).decompressed(using: .zlib) as Data
    try Task.checkCancellation()
    return String(decoding: decoded, as: UTF8.self)
}
