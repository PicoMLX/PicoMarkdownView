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
    @State private var markdown: String?
    @State private var loadError: String?
    private let localPath: String
    private let tagPrefixes: Set<TagPrefix>
    private let inputID: UUID
    private let chunkCharacters: Int?
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
        self.localPath = example.localPath
        self._markdown = State(initialValue: example.chunkCharacters == nil ? try! example.loadMarkdown() : nil)
        self.tagPrefixes = example.tagPrefixes
        self.inputID = example.id
        self.chunkCharacters = example.chunkCharacters
    }

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
            guard markdown == nil, chunkCharacters != nil else { return }
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
                                                     chunkCharacters: chunkCharacters,
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
                if chunkCharacters == nil {
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
/// SwiftUI compares the stable input identity and skips body re-evaluation
/// when the parent re-renders due to scroll-position changes,
/// preventing the stream from restarting. The closures and `tagPrefixes` are
/// excluded from `==` — they're stable for a given document.
private struct StreamingMarkdownContent: View, Equatable {
    let markdown: String
    let inputID: UUID
    let chunkCharacters: Int?
    let tagPrefixes: Set<TagPrefix>
    let onOpenURL: (URL) -> Void
    let onTagTap: (TagReference) -> Void
    let onTagHover: (String?) -> Void
    let onLinkHover: (String?) -> Void
    let onContentSize: (CGSize) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.inputID == rhs.inputID && lhs.chunkCharacters == rhs.chunkCharacters
    }

    var body: some View {
        PicoMarkdownView(stream: { [markdown, chunkCharacters] in
            if let chunkCharacters {
                let cursor = MarkdownChunkCursor(markdown: markdown, chunkCharacters: chunkCharacters)
                return AsyncStream(unfolding: { await cursor.next() })
            }
            return wordStream(from: markdown)
        }, theme: exampleTheme, tagPrefixes: tagPrefixes)
            .id(inputID)
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
                onTagHover(tag.map { tag in
                    let displayTag = "\(tag.prefix)\(tag.identifier)"
                    return String(localized: "Tag: \(displayTag)")
                })
            }
            .onLinkHover { [onLinkHover] url, _ in
                onLinkHover(url.map { String(localized: "Link: \($0.absoluteString)") })
            }
            .onContentSize { [onContentSize] size in
                onContentSize(size)
            }
    }

    private var exampleTheme: MarkdownRenderTheme {
#if os(macOS)
        .default().withMermaidRendering(.bestEffortDebounced(milliseconds: 200))
#else
        .default()
#endif
    }
}

/// Pull-based delivery prevents a large gallery from filling an unbounded
/// AsyncStream queue while the renderer is still consuming earlier chunks.
private actor MarkdownChunkCursor {
    private let markdown: String
    private let chunkCharacters: Int
    private var index: String.Index

    init(markdown: String, chunkCharacters: Int) {
        self.markdown = markdown
        self.chunkCharacters = max(1, chunkCharacters)
        self.index = markdown.startIndex
    }

    func next() -> String? {
        guard !Task.isCancelled, index < markdown.endIndex else { return nil }
        let end = markdown.index(index, offsetBy: chunkCharacters, limitedBy: markdown.endIndex) ?? markdown.endIndex
        let chunk = String(markdown[index..<end])
        index = end
        return chunk
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
