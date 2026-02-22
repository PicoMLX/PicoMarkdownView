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
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isAutoScrolling = true
    @State private var autoScrollSuppressionDeadline: ContinuousClock.Instant?

    private let autoScrollClock = ContinuousClock()

    init(_ example: MarkdownExample) {
        self.webURL = example.webURL
        self.markdown = try! String(contentsOfFile: example.localPath, encoding: .utf8)
    }

    var body: some View {

        HStack {
            TabView {
                Tab("Markdown", systemImage: "square.fill.text.grid.1x2") {
                    ScrollView {
                        // Extracted into an Equatable subview with no dynamic
                        // properties so scrollPosition state changes don't
                        // re-evaluate PicoMarkdownView's body (restarting the stream).
                        StreamingMarkdownContent(markdown: markdown, onOpenURL: { openURL($0) })
                    }
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                        let contentHeight = geometry.contentSize.height
                        let offsetY = geometry.contentOffset.y
                        let visibleBottom = offsetY + geometry.containerSize.height
                        let isNearBottom = contentHeight - visibleBottom < AutoScrollConfig.nearBottomThreshold
                        return ScrollMetrics(contentHeight: contentHeight,
                                             offsetY: offsetY,
                                             isNearBottom: isNearBottom)
                    } action: { oldMetrics, newMetrics in
                        handleScrollMetricsChange(from: oldMetrics, to: newMetrics)
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

    private func handleScrollMetricsChange(from old: ScrollMetrics, to new: ScrollMetrics) {
        let didGrow = new.contentHeight > old.contentHeight + AutoScrollConfig.heightEpsilon
        let scrollDeltaY = new.offsetY - old.offsetY

        let now = autoScrollClock.now
        // Ignore transient "not at bottom" snapshots while our own short scroll animation catches up.
        let suppressionActive = autoScrollSuppressionDeadline.map { $0 > now } ?? false
        if !suppressionActive, autoScrollSuppressionDeadline != nil {
            autoScrollSuppressionDeadline = nil
        }

        var requestedProgrammaticScroll = false
        if didGrow, isAutoScrolling {
            requestedProgrammaticScroll = true
            autoScrollSuppressionDeadline = now.advanced(by: AutoScrollConfig.suppressionWindow)
            scrollToBottom(animated: !reduceMotion)
        }

        if new.isNearBottom {
            if !isAutoScrolling {
                isAutoScrolling = true
            }
            return
        }

        if requestedProgrammaticScroll {
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
    let contentHeight: CGFloat
    let offsetY: CGFloat
    let isNearBottom: Bool
}

private enum AutoScrollConfig {
    static let nearBottomThreshold: CGFloat = 80
    static let manualCancelDeltaThreshold: CGFloat = 3
    static let heightEpsilon: CGFloat = 0.5
    static let animationDuration: Double = 0.10
    static let suppressionWindow: Duration = .milliseconds(140)
}

/// Equatable subview with ZERO DynamicProperty (@Environment, @State, etc.).
/// SwiftUI compares only the `markdown` string via `==` and skips body
/// re-evaluation when the parent re-renders due to scroll-position changes,
/// preventing the stream from restarting. The `onOpenURL` closure is excluded
/// from `==` — it's stable (captures the parent's openURL action).
private struct StreamingMarkdownContent: View, Equatable {
    let markdown: String
    let onOpenURL: (URL) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.markdown == rhs.markdown
    }

    var body: some View {
        let theme = MarkdownRenderTheme.default().withMermaidRendering(.onFenceClose)
        PicoMarkdownView(stream: { [markdown] in
            wordStream(from: markdown)
        }, theme: theme)
            .id(markdown)
            .textSelection(.enabled)
            .padding()
            .onOpenLink { [onOpenURL] url in
                onOpenURL(url)
                return .handled
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
