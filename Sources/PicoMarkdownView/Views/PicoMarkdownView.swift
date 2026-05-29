import SwiftUI
import Observation

public struct PicoMarkdownView: View {
    private let input: MarkdownStreamingInput
    private let configuration: PicoTextKitConfiguration

    @State private var viewModel: MarkdownStreamingViewModel
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

    public init(stream: @escaping @Sendable () async -> AsyncStream<String>,
                theme: MarkdownRenderTheme = .default(),
                imageProvider: MarkdownImageProvider? = nil,
                remoteImagesEnabled: Bool = true,
                tagPrefixes: Set<TagPrefix> = TagPrefix.defaults,
                configuration: PicoTextKitConfiguration = .default()) {
        self.init(input: .stream(stream),
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
            .task(id: input.id) {
                await viewModel.consume(input)
            }
    }

    /// Builds the hover closure for the text views (macOS). It receives the
    /// hovered link's URL (if any), its visible text, and bounding rect, then
    /// dispatches to ``onTagHover`` for `pico-tag://` links and ``onLinkHover``
    /// for everything else. Exit (`nil` URL) is forwarded to whichever handlers
    /// are installed so hosts can dismiss popovers. Returns `nil` when neither
    /// hover handler is set, so no tracking work happens.
    private func makeHoverHandler() -> ((URL?, String, CGRect?) -> Void)? {
        guard onTagHover != nil || onLinkHover != nil else { return nil }
        let onTagHover = self.onTagHover
        let onLinkHover = self.onLinkHover
        return { url, displayText, rect in
            guard let url else {
                onTagHover?(nil, nil)
                onLinkHover?(nil, nil)
                return
            }
            if let tag = PicoTagURL.makeTag(from: url, displayText: displayText) {
                onTagHover?(tag, rect)
                onLinkHover?(nil, nil)
            } else {
                onLinkHover?(url, rect)
                onTagHover?(nil, nil)
            }
        }
    }

    /// Builds the closure the text views invoke on link tap/click. Tag links
    /// (`pico-tag://…`) are decoded into a ``Tag`` and sent to ``onTagTap`` when
    /// present; everything else (and tags, when no `onTagTap` is set) goes to
    /// the SwiftUI `openURL` action so `onOpenLink` continues to work.
    private func makeLinkHandler() -> (URL, String) -> Void {
        let onTagTap = self.onTagTap
        let openURL = self.openURL
        return { url, displayText in
            if let onTagTap, let tag = PicoTagURL.makeTag(from: url, displayText: displayText) {
                onTagTap(tag)
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
        if let onContentSize {
            controller.installContentSizeObserver(on: view, onContentSize)
        }
        controller.installLinkHandler(on: view, linkHandler)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        controller.update(textView: uiView, blocks: blocks, diffs: diffs, replaceToken: replaceToken, configuration: configuration)
        onMeasuredContentWidth(controller.mermaidContentWidth(for: uiView))
        if let onContentSize {
            controller.installContentSizeObserver(on: uiView, onContentSize)
        }
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
        if let onContentSize {
            controller.installContentSizeObserver(on: view, onContentSize)
        }
        controller.installLinkHandler(on: view, linkHandler)
        controller.installHoverHandler(on: view, hoverHandler)
        return view
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        controller.update(textView: nsView, blocks: blocks, diffs: diffs, replaceToken: replaceToken, configuration: configuration)
        onMeasuredContentWidth(controller.mermaidContentWidth(for: nsView))
        if let onContentSize {
            controller.installContentSizeObserver(on: nsView, onContentSize)
        }
        controller.installLinkHandler(on: nsView, linkHandler)
        controller.installHoverHandler(on: nsView, hoverHandler)
    }
}
#endif
