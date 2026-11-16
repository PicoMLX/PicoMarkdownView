//
//  MarkdownView.swift
//  MarkdownExample
//
//  Created by Ronald Mannak on 10/15/25.
//

import SwiftUI
import Observation
import PicoMarkdownView
#if os(macOS)
import PicoMarkdownViewHTML
#endif

struct MarkdownView: View {

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let example: MarkdownExample
    @State private var markdown: String?
    @State private var loadError: String?
    @State private var streamPacing: ExampleStreamPacing
    private let tagPrefixes: Set<TagPrefix>
    private let htmlPreviewsEnabled: Bool
    @State private var inputID: UUID
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
    @State private var lastOpenUIAction: String?

    private let autoScrollClock = ContinuousClock()

    init(_ example: MarkdownExample) {
        self.example = example
        self._streamPacing = State(initialValue: ExampleStreamPacing(speed: .fullText))
        self._inputID = State(initialValue: example.id)
        self.tagPrefixes = example.tagPrefixes
        self.htmlPreviewsEnabled = example.htmlPreviewsEnabled
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
                ContentUnavailableView("Unable to load example", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                ProgressView("Loading example…")
            }
        }
        .task(id: example.id) {
            guard markdown == nil else { return }
            do {
                let text = try await loadExampleMarkdown(example)
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
        Group {
            TabView {
                Tab("Preview", systemImage: "square.fill.text.grid.1x2") {
                    VStack(spacing: 0) {
                        playbackPanel
                        ScrollView {
                            // Extracted into an Equatable subview with no dynamic
                            // properties so scrollPosition state changes don't
                            // re-evaluate PicoMarkdownView's body (restarting the stream).
                            StreamingMarkdownContent(markdown: markdown,
                                                     inputID: inputID,
                                                     pacing: streamPacing,
                                                     tagPrefixes: tagPrefixes,
                                                     htmlPreviewsEnabled: htmlPreviewsEnabled,
                                                     svgRenderingEnabled: svgRenderingEnabled,
                                                     usesBundledImages: example.usesBundledImages,
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
                    Tab("Source", systemImage: "text.alignleft") {
                        ScrollView {
                            Text(markdown)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    /// Playback is shared by every example; interaction feedback appears only when relevant.
    private var playbackPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    if !tagPrefixes.isEmpty { tagSelectionReadout }
                    Spacer(minLength: 8)
                    playbackControls
                }
                VStack(alignment: .leading) {
                    if !tagPrefixes.isEmpty { tagSelectionReadout }
                    playbackControls
                }
            }
#if os(macOS)
            if let lastOpenUIAction {
                Label(lastOpenUIAction, systemImage: "rectangle.and.hand.point.up.left")
                    .font(.callout)
            }
            if !tagPrefixes.isEmpty || example.localFilename == "LinkMenus" {
                // Stable height keeps hover feedback from moving the mention anchor.
                Label(tagHoverReadout ?? linkHoverReadout ?? String(localized: "Point to a tag or link."),
                      systemImage: "cursorarrow.rays")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
#endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var tagSelectionReadout: some View {
        Label {
            if let tag = lastTappedTag {
                Text("Selected Tag: \(tag.prefix)\(tag.identifier)")
            } else {
                Text("Select a tag to see its details.")
            }
        } icon: {
            Image(systemName: "hand.tap")
        }
        .font(.callout)
    }

    private var playbackControls: some View {
        @Bindable var pacing = streamPacing
        return HStack {
            Picker("Playback", selection: $pacing.speed) {
                ForEach(ExamplePlaybackSpeed.allCases) { speed in
                    Text(speed.rawValue).tag(speed)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Choose a speed. Use Replay to start the example again.")
            Button("Replay", systemImage: "arrow.clockwise", action: replay)
                .keyboardShortcut("r", modifiers: .command)
                .frame(minHeight: 44)
        }
    }

    private func replay() {
        inputID = UUID()
        lastTappedTag = nil
        tagHoverReadout = nil
        linkHoverReadout = nil
        lastOpenUIAction = nil
        isAutoScrolling = true
        autoScrollSuppressionDeadline = nil
    }

    /// Content-growth → scroll-to-bottom, driven by PicoMarkdownView's
    /// `onContentSize` callback for ordinary examples. The gallery follows the
    /// scroll view's applied geometry below because its large code-to-chart
    /// replacements can shrink the document.
    private func handleContentSizeChange(_ size: CGSize) {
        guard streamPacing.speed != .fullText, !isLargeFixture, isAutoScrolling else { return }
        // Suppress the brief window after our own programmatic scroll so its
        // animation frames aren't later misread by the scroll observer as a
        // user scroll-up.
        autoScrollSuppressionDeadline = autoScrollClock.now.advanced(by: AutoScrollConfig.suppressionWindow)
        scrollToBottom(animated: !reduceMotion)
    }

    /// Scroll position pauses/resumes following. The gallery additionally follows
    /// height changes after SwiftUI has applied them to the scroll view.
    private func handleScrollMetricsChange(from old: ScrollMetrics, to new: ScrollMetrics) {
        guard streamPacing.speed != .fullText else { return }
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
/// SwiftUI compares the stable input identity and its presentation options,
/// skipping body re-evaluation when the parent re-renders due to scroll-position
/// changes so the stream does not restart. The closures and `tagPrefixes` are
/// excluded from `==` — they're stable for a given document.
private struct StreamingMarkdownContent: View, Equatable {
    let markdown: String
    let inputID: UUID
    let pacing: ExampleStreamPacing
    let tagPrefixes: Set<TagPrefix>
    let htmlPreviewsEnabled: Bool
    let svgRenderingEnabled: Bool
    let usesBundledImages: Bool
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
        lhs.inputID == rhs.inputID
            && lhs.htmlPreviewsEnabled == rhs.htmlPreviewsEnabled
            && lhs.svgRenderingEnabled == rhs.svgRenderingEnabled
    }

    private var streamingMarkdownView: PicoMarkdownView {
#if os(macOS)
        PicoMarkdownView(stream: { [markdown, pacing] in
            wordStream(from: markdown, pacing: pacing)
        }, theme: exampleTheme, imageProvider: usesBundledImages ? ExampleImageProvider() : nil,
           tagPrefixes: tagPrefixes,
           embeddedBlockRenderers: htmlPreviewsEnabled ? [.htmlPreview] : [])
            .onImageTap { [imageTapHandler] image in imageTapHandler?(image) }
#else
        PicoMarkdownView(stream: { [markdown, pacing] in
            wordStream(from: markdown, pacing: pacing)
        }, theme: exampleTheme, imageProvider: usesBundledImages ? ExampleImageProvider() : nil,
           tagPrefixes: tagPrefixes)
#endif
    }

    var body: some View {
        streamingMarkdownView
#if os(macOS)
            .id(htmlPreviewsEnabled)
            .id(svgRenderingEnabled)
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
    var speed: ExamplePlaybackSpeed

    init(speed: ExamplePlaybackSpeed) {
        self.speed = speed
    }

    var wordDelay: Duration {
        .nanoseconds(speed == .fast ? 3_333_333 : 33_333_333)
    }
}

private enum ExamplePlaybackSpeed: String, CaseIterable, Identifiable {
    case normal = "Stream"
    case fast = "Stream 10×"
    case fullText = "Full Text"

    var id: Self { self }
}

/// Ordinary playback preserves word boundaries. Full Text uses bounded chunks so
/// a large gallery can finish promptly while still allowing cancellation and UI work.
private func wordStream(from markdown: String, pacing: ExampleStreamPacing) -> AsyncStream<String> {
    AsyncStream<String> { continuation in
        let task = Task {
            var remaining = markdown[...]
            while !remaining.isEmpty, !Task.isCancelled {
                let end: Substring.Index
                if pacing.speed == .fullText {
                    end = remaining.index(remaining.startIndex, offsetBy: 16_384,
                                          limitedBy: remaining.endIndex) ?? remaining.endIndex
                } else {
                    var index = remaining.startIndex
                    var wordSeen = false
                    while index < remaining.endIndex {
                        let character = remaining[index]
                        index = remaining.index(after: index)
                        if character.isWhitespace {
                            if wordSeen { break }
                        } else {
                            wordSeen = true
                        }
                    }
                    end = index
                }
                continuation.yield(String(remaining[..<end]))
                remaining = remaining[end...]
                if pacing.speed == .fullText {
                    await Task.yield()
                } else {
                    do {
                        try await Task.sleep(for: pacing.wordDelay)
                    } catch {
                        break
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

@concurrent
private func loadExampleMarkdown(_ example: MarkdownExample) async throws -> String {
    try Task.checkCancellation()
    let markdown = try example.loadMarkdown()
    try Task.checkCancellation()
    return markdown
}
