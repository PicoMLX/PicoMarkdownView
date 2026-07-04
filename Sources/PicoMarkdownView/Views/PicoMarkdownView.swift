import SwiftUI
import Observation

public struct PicoMarkdownView: View {
    private let input: MarkdownStreamingInput
    private let configuration: PicoTextKitConfiguration

    @State private var viewModel: MarkdownStreamingViewModel
    /// Stable per-view-identity token used as the `.task` id for `.stream`
    /// inputs. A stream input mints a unique id on every construction
    /// (closures have no comparable content), so keying the task off
    /// `input.id` would cancel consumption and re-invoke the factory on every
    /// parent body re-evaluation. Keying it off this token keeps the task
    /// alive across re-renders, restarts it when the view identity changes,
    /// and — because non-stream inputs keep their content-derived id — also
    /// restarts it when the input switches between stream and non-stream
    /// modes, always consuming the *current* input.
    @State private var streamTaskIdentity = UUID()
    @StateObject private var controller = TextKitStreamingController()
    @Environment(\.openURL) private var openURL
    @Environment(\.picoOnTagTap) private var onTagTap
    @Environment(\.picoOnTagHover) private var onTagHover
    @Environment(\.picoOnLinkHover) private var onLinkHover
    @Environment(\.picoOnContentSize) private var onContentSize

    private init(input: MarkdownStreamingInput,
                 theme: MarkdownRenderTheme,
                 imageProvider: MarkdownImageProvider?,
                 tagPrefixes: Set<TagPrefix>,
                 configuration: PicoTextKitConfiguration) {
        self.input = input
        self.configuration = configuration
        _viewModel = State(initialValue: MarkdownStreamingViewModel(theme: theme, imageProvider: imageProvider, tagPrefixes: tagPrefixes))
    }

    private var consumeTaskID: String {
        guard input.isStream else { return input.id }
        // A caller-provided stream identity is stable across re-renders and
        // changes exactly when the caller wants a restart (e.g. regenerating
        // a response in place), so it can key the task directly. Without one,
        // fall back to the per-view-identity token.
        return input.hasStableStreamID ? input.id : "stream-identity-\(streamTaskIdentity.uuidString)"
    }

    /// Creates a view that renders `text` as Markdown.
    ///
    /// - Important: `theme`, `imageProvider`, and `tagPrefixes` are
    ///   **construction-time configuration**: they are captured once when the
    ///   view's backing model is first created for a given view identity, and
    ///   are *not* re-read when you pass different values to an existing view.
    ///   To reconfigure them at runtime — e.g. toggling `$` ticker recognition
    ///   on or off — change the view's identity so SwiftUI rebuilds it, for
    ///   example with `.id(...)`:
    ///
    ///   ```swift
    ///   PicoMarkdownView(text, tagPrefixes: prefixes)
    ///       .id(prefixes)   // forces a fresh tokenizer when the set changes
    ///   ```
    ///
    ///   (`content` *does* update live; only this configuration is fixed per
    ///   identity.)
    public init(_ text: String,
                theme: MarkdownRenderTheme = .default(),
                imageProvider: MarkdownImageProvider? = nil,
                remoteImagesEnabled: Bool = true,
                tagPrefixes: Set<TagPrefix> = TagPrefix.defaults,
                configuration: PicoTextKitConfiguration = .default()) {
        self.init(input: .text(text),
                  theme: theme,
                  imageProvider: Self.resolveImageProvider(imageProvider, remoteImagesEnabled: remoteImagesEnabled),
                  tagPrefixes: tagPrefixes,
                  configuration: configuration)
    }

    /// Creates a view that renders a complete document delivered as an array
    /// of chunks.
    ///
    /// - Important: This is a **one-shot** convenience — for example,
    ///   replaying the collected chunks of a finished LLM response. Each
    ///   delivery is parsed as a complete document, so passing a *growing*
    ///   array re-parses the whole document on every append. For live
    ///   streaming, use the `stream:` initializer, which feeds the pipeline
    ///   incrementally with O(chunk) work per chunk.
    public init(chunks: [String],
                theme: MarkdownRenderTheme = .default(),
                imageProvider: MarkdownImageProvider? = nil,
                remoteImagesEnabled: Bool = true,
                tagPrefixes: Set<TagPrefix> = TagPrefix.defaults,
                configuration: PicoTextKitConfiguration = .default()) {
        self.init(input: .chunks(chunks),
                  theme: theme,
                  imageProvider: Self.resolveImageProvider(imageProvider, remoteImagesEnabled: remoteImagesEnabled),
                  tagPrefixes: tagPrefixes,
                  configuration: configuration)
    }

    /// Creates a view that renders an async stream of Markdown chunks.
    ///
    /// - Important: The factory may be invoked more than once for the same
    ///   view. The consuming task is cancelled when the view leaves the
    ///   hierarchy (e.g. scrolls out of a lazy container) and, because a
    ///   cancelled stream cannot be resumed, the factory is called again when
    ///   the view reappears. Return the full stream from the beginning on
    ///   every invocation (for a finished LLM response, replay the collected
    ///   text) so reappearing views render complete content.
    ///
    /// - Parameter streamID: Optional identity for the stream. Without it,
    ///   the stream is consumed once per view identity, so swapping in a
    ///   *different* factory during a re-render is ignored (closures cannot
    ///   be compared). Pass a value that changes when the stream's content
    ///   changes — e.g. a regeneration counter — to restart consumption with
    ///   the new factory while equal values continue to survive re-renders:
    ///
    ///   ```swift
    ///   PicoMarkdownView(stream: makeStream, streamID: message.generationID)
    ///   ```
    public init(stream: @escaping @Sendable () async -> AsyncStream<String>,
                streamID: AnyHashable? = nil,
                theme: MarkdownRenderTheme = .default(),
                imageProvider: MarkdownImageProvider? = nil,
                remoteImagesEnabled: Bool = true,
                tagPrefixes: Set<TagPrefix> = TagPrefix.defaults,
                configuration: PicoTextKitConfiguration = .default()) {
        self.init(input: .stream(stream, id: streamID),
                  theme: theme,
                  imageProvider: Self.resolveImageProvider(imageProvider, remoteImagesEnabled: remoteImagesEnabled),
                  tagPrefixes: tagPrefixes,
                  configuration: configuration)
    }

    public var body: some View {
        TextKit2Container(controller: controller,
                          blocks: viewModel.blocks,
                          diffs: viewModel.diffQueue,
                          replaceToken: viewModel.replaceToken,
                          configuration: configuration,
                          onMeasuredContentWidth: { width in
                              Task {
                                  await viewModel.updateMermaidContentWidth(width)
                              }
                          },
                          onContentSize: onContentSize,
                          linkHandler: makeLinkHandler(),
                          hoverHandler: makeHoverHandler())
            .task(id: consumeTaskID) {
                await viewModel.consume(input)
            }
    }

    /// Builds the hover closure for the text views (macOS). It receives the
    /// hovered link's URL (if any) and bounding rect, then dispatches to
    /// ``onTagHover`` for `pico-tag://` links (decoded to a ``TagReference``)
    /// and ``onLinkHover`` for everything else. Exit (`nil` URL) is forwarded to
    /// whichever handlers are installed so hosts can dismiss popovers. Returns
    /// `nil` when neither hover handler is set, so no tracking work happens.
    private func makeHoverHandler() -> ((URL?, String, CGRect?) -> Void)? {
        guard onTagHover != nil || onLinkHover != nil else { return nil }
        let onTagHover = self.onTagHover
        let onLinkHover = self.onLinkHover
        return { url, _, rect in
            guard let url else {
                onTagHover?(nil, nil)
                onLinkHover?(nil, nil)
                return
            }
            if let reference = PicoTagURL.reference(from: url) {
                onTagHover?(reference, rect)
                onLinkHover?(nil, nil)
            } else {
                onLinkHover?(url, rect)
                onTagHover?(nil, nil)
            }
        }
    }

    /// Builds the closure the text views invoke on link tap/click. Tag links
    /// (`pico-tag://…`) are decoded to a ``TagReference`` and sent to
    /// ``onTagTap`` when set; everything else (and tags, when no `onTagTap` is
    /// set) goes to the SwiftUI `openURL` action so `onOpenLink` continues to
    /// work.
    private func makeLinkHandler() -> (URL, String) -> Void {
        let onTagTap = self.onTagTap
        let openURL = self.openURL
        return { url, _ in
            if let onTagTap, let reference = PicoTagURL.reference(from: url) {
                onTagTap(reference)
            } else {
                openURL(url)
            }
        }
    }

    private static func resolveImageProvider(_ provider: MarkdownImageProvider?,
                                             remoteImagesEnabled: Bool) -> MarkdownImageProvider? {
        if let provider {
            return provider
        }
        return remoteImagesEnabled ? URLSessionMarkdownImageProvider.shared : nil
    }
}

#if canImport(UIKit)
import UIKit

private struct TextKit2Container: UIViewRepresentable {
    var controller: TextKitStreamingController
    var blocks: [RenderedBlock]
    var diffs: [AssemblerDiff]
    var replaceToken: UInt64
    var configuration: PicoTextKitConfiguration
    var onMeasuredContentWidth: (CGFloat?) -> Void
    var onContentSize: ((CGSize) -> Void)?
    var linkHandler: (URL, String) -> Void
    // Accepted for a uniform call site across platforms; iOS has no hover so it
    // is intentionally unused here.
    var hoverHandler: ((URL?, String, CGRect?) -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let view: UITextView
        if #available(iOS 16.0, *) {
            view = controller.makeTextKit2View(configuration: configuration)
        } else {
            view = controller.makeTextKit1View(configuration: configuration)
        }
        controller.installMermaidWidthObserver(on: view, onMeasuredContentWidth)
        controller.installContentSizeObserver(on: view, onContentSize)
        controller.installLinkHandler(on: view, linkHandler)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        controller.update(textView: uiView, blocks: blocks, diffs: diffs, replaceToken: replaceToken, configuration: configuration)
        onMeasuredContentWidth(controller.mermaidContentWidth(for: uiView))
        controller.installContentSizeObserver(on: uiView, onContentSize)
        controller.installLinkHandler(on: uiView, linkHandler)
    }
}
#elseif canImport(AppKit)
import AppKit

private struct TextKit2Container: NSViewRepresentable {
    var controller: TextKitStreamingController
    var blocks: [RenderedBlock]
    var diffs: [AssemblerDiff]
    var replaceToken: UInt64
    var configuration: PicoTextKitConfiguration
    var onMeasuredContentWidth: (CGFloat?) -> Void
    var onContentSize: ((CGSize) -> Void)?
    var linkHandler: (URL, String) -> Void
    var hoverHandler: ((URL?, String, CGRect?) -> Void)?

    func makeNSView(context: Context) -> NSTextView {
        let view: NSTextView
        if #available(macOS 13.0, *) {
            view = controller.makeTextKit2View(configuration: configuration)
        } else {
            view = controller.makeTextKit1View(configuration: configuration)
        }
        controller.installMermaidWidthObserver(on: view, onMeasuredContentWidth)
        controller.installContentSizeObserver(on: view, onContentSize)
        controller.installLinkHandler(on: view, linkHandler)
        controller.installHoverHandler(on: view, hoverHandler)
        return view
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        controller.update(textView: nsView, blocks: blocks, diffs: diffs, replaceToken: replaceToken, configuration: configuration)
        onMeasuredContentWidth(controller.mermaidContentWidth(for: nsView))
        controller.installContentSizeObserver(on: nsView, onContentSize)
        controller.installLinkHandler(on: nsView, linkHandler)
        controller.installHoverHandler(on: nsView, hoverHandler)
    }
}
#endif
