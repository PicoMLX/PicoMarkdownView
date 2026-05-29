import SwiftUI
import Observation

public struct PicoMarkdownView: View {
    private let input: MarkdownStreamingInput
    private let configuration: PicoTextKitConfiguration

    @State private var viewModel: MarkdownStreamingViewModel
    @StateObject private var controller = TextKitStreamingController()
    @Environment(\.openURL) private var openURL

    private var onContentSize: ((CGSize) -> Void)?
    private var onTagTap: ((Tag) -> Void)?

    private init(input: MarkdownStreamingInput,
                 theme: MarkdownRenderTheme,
                 imageProvider: MarkdownImageProvider?,
                 tagPrefixes: Set<TagPrefix>,
                 configuration: PicoTextKitConfiguration) {
        self.input = input
        self.configuration = configuration
        _viewModel = State(initialValue: MarkdownStreamingViewModel(theme: theme, imageProvider: imageProvider, tagPrefixes: tagPrefixes))
    }

    /// Reports the rendered content size whenever it changes — e.g. when
    /// streaming adds a newline and the content grows taller. Fires on the main
    /// actor during layout, de-duplicated so it only calls when the size
    /// actually changes (> 0.5pt). Width reflects the current view width;
    /// height reflects the laid-out content height including vertical insets.
    public func onContentSize(_ handler: @escaping (CGSize) -> Void) -> PicoMarkdownView {
        var copy = self
        copy.onContentSize = handler
        return copy
    }

    /// Routes taps on inline tags (`@mentions`, `#hashtags`, `[[wiki-links]]`,
    /// etc.) to a typed handler that receives the decoded ``Tag`` — prefix,
    /// identifier, display text, and raw text. When set, tag taps go here
    /// instead of the ``onOpenLink``/`openURL` path; ordinary `[text](url)`
    /// links still route through `openURL`. When *not* set, tag taps fall back
    /// to `openURL` carrying the `pico-tag://` URL, so existing `onOpenLink`
    /// handlers keep working unchanged.
    public func onTagTap(_ handler: @escaping (Tag) -> Void) -> PicoMarkdownView {
        var copy = self
        copy.onTagTap = handler
        return copy
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
                          linkHandler: makeLinkHandler())
            .task(id: input.id) {
                await viewModel.consume(input)
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
        return view
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        controller.update(textView: nsView, blocks: blocks, diffs: diffs, replaceToken: replaceToken, configuration: configuration)
        onMeasuredContentWidth(controller.mermaidContentWidth(for: nsView))
        if let onContentSize {
            controller.installContentSizeObserver(on: nsView, onContentSize)
        }
        controller.installLinkHandler(on: nsView, linkHandler)
    }
}
#endif
