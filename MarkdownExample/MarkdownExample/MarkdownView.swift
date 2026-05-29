//
//  MarkdownView.swift
//  MarkdownExample
//
//  Created by Ronald Mannak on 10/15/25.
//

import SwiftUI
import PicoMarkdownView
import WebKit

struct MarkdownView: View {

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let webURL: URL
    private let markdown: String
    private let tagPrefixes: Set<TagPrefix>
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

    private let autoScrollClock = ContinuousClock()

    init(_ example: MarkdownExample) {
        self.webURL = example.webURL
        self.markdown = try! String(contentsOfFile: example.localPath, encoding: .utf8)
        self.tagPrefixes = example.tagPrefixes
    }

    var body: some View {

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
                                                     tagPrefixes: tagPrefixes,
                                                     onOpenURL: { openURL($0) },
                                                     onTagTap: { lastTappedTag = $0 },
                                                     onTagHover: { tagHoverReadout = $0 },
                                                     onLinkHover: { linkHoverReadout = $0 },
                                                     onContentSize: { handleContentSizeChange($0) })
                        }
                        .scrollPosition($scrollPosition)
                        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                            let offsetY = geometry.contentOffset.y
                            let visibleBottom = offsetY + geometry.containerSize.height
                            let isNearBottom = geometry.contentSize.height - visibleBottom < AutoScrollConfig.nearBottomThreshold
                            return ScrollMetrics(offsetY: offsetY, isNearBottom: isNearBottom)
                        } action: { oldMetrics, newMetrics in
                            handleScrollMetricsChange(from: oldMetrics, to: newMetrics)
                        }
                    }
                }
                Tab("Debug", systemImage: "ladybug") {
                    ScrollView {
                        PicoMarkdownDebugView(text: markdown)
                    }
                }
                Tab("Text", systemImage: "text.alignleft") {
                    ScrollView {
                        Text(markdown)
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
            if let tag = lastTappedTag {
                Label {
                    Text("Tapped ")
                        + Text("\(tag.prefix)\(tag.identifier)").bold()
                        + Text("  ·  prefix \(tag.prefix)  ·  id \(tag.identifier)")
                } icon: {
                    Image(systemName: "hand.tap")
                }
                .font(.callout)
            } else {
                Label("Tap a tag (@mention, #hashtag, [[wiki]], $ticker)", systemImage: "hand.tap")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                #if os(macOS)
                let hover = tagHoverReadout ?? linkHoverReadout
                Label(hover ?? "Hover a tag or link", systemImage: "cursorarrow.rays")
                    .foregroundStyle(hover == nil ? .secondary : .primary)
                #endif
                if let contentSize {
                    Label(String(format: "Content %.0f × %.0f", contentSize.width, contentSize.height),
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

    /// Content-growth → scroll-to-bottom, driven by PicoMarkdownView's
    /// `onContentSize` callback. This is the *only* place we react to the
    /// document getting taller; scrolling never changes content size, so there
    /// is no feedback loop here. (Also feeds the status-panel readout.)
    private func handleContentSizeChange(_ size: CGSize) {
        contentSize = size
        guard isAutoScrolling else { return }
        // Suppress the brief window after our own programmatic scroll so its
        // animation frames aren't later misread by the scroll observer as a
        // user scroll-up.
        autoScrollSuppressionDeadline = autoScrollClock.now.advanced(by: AutoScrollConfig.suppressionWindow)
        scrollToBottom(animated: !reduceMotion)
    }

    /// Scroll *position* → pause/resume only. Growth detection now lives in
    /// `handleContentSizeChange`, so this no longer tracks content height.
    private func handleScrollMetricsChange(from old: ScrollMetrics, to new: ScrollMetrics) {
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
}

private enum AutoScrollConfig {
    static let nearBottomThreshold: CGFloat = 80
    static let manualCancelDeltaThreshold: CGFloat = 3
    static let animationDuration: Double = 0.10
    static let suppressionWindow: Duration = .milliseconds(140)
}

/// Equatable subview with ZERO DynamicProperty (@Environment, @State, etc.).
/// SwiftUI compares only the `markdown` string via `==` and skips body
/// re-evaluation when the parent re-renders due to scroll-position changes,
/// preventing the stream from restarting. The closures and `tagPrefixes` are
/// excluded from `==` — they're stable for a given document.
private struct StreamingMarkdownContent: View, Equatable {
    let markdown: String
    let tagPrefixes: Set<TagPrefix>
    let onOpenURL: (URL) -> Void
    let onTagTap: (TagReference) -> Void
    let onTagHover: (String?) -> Void
    let onLinkHover: (String?) -> Void
    let onContentSize: (CGSize) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.markdown == rhs.markdown
    }

    var body: some View {
        PicoMarkdownView(stream: { [markdown] in
            wordStream(from: markdown)
        }, tagPrefixes: tagPrefixes)
            .id(markdown)
            .textSelection(.enabled)
            .padding()
            .onOpenLink { [onOpenURL] url in
                onOpenURL(url)
                return .handled
            }
            .onTagTap { [onTagTap] tag in
                onTagTap(tag)
            }
            .onTagHover { [onTagHover] tag, _ in
                onTagHover(tag.map { "Hovering \($0.prefix)\($0.identifier)  ·  id \($0.identifier)" })
            }
            .onLinkHover { [onLinkHover] url, _ in
                onLinkHover(url.map { "Hovering link \($0.absoluteString)" })
            }
            .onContentSize { [onContentSize] size in
                onContentSize(size)
            }
    }
}

/// Creates a word-by-word AsyncStream from markdown text, simulating ~30 words/sec LLM inference.
private func wordStream(from markdown: String) -> AsyncStream<String> {
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
                        try? await Task.sleep(nanoseconds: 33_333_333)
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
