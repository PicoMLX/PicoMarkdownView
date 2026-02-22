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

    private let webURL: URL
    private let markdown: String
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isAutoScrolling = true

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
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                        return geometry.contentSize.height - visibleBottom < 80
                    } action: { _, isNearBottom in
                        isAutoScrolling = isNearBottom
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        geometry.contentSize.height
                    } action: { oldHeight, newHeight in
                        if newHeight > oldHeight, isAutoScrolling {
                            scrollPosition.scrollTo(edge: .bottom)
                        }
                        if newHeight < oldHeight {
                            isAutoScrolling = true
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
