import SwiftUI
import Observation

public struct PicoMarkdownView: View {
    private let input: MarkdownStreamingInput
    private let configuration: PicoTextKitConfiguration

    @State private var viewModel: MarkdownStreamingViewModel
    @StateObject private var controller = TextKitStreamingController()

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
                          })
            .task(id: input.id) {
                await viewModel.consume(input)
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

    func makeUIView(context: Context) -> UITextView {
        let view: UITextView
        if #available(iOS 16.0, *) {
            view = controller.makeTextKit2View(configuration: configuration)
        } else {
            view = controller.makeTextKit1View(configuration: configuration)
        }
        controller.installMermaidWidthObserver(on: view, onMeasuredContentWidth)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        controller.update(textView: uiView, blocks: blocks, diffs: diffs, replaceToken: replaceToken, configuration: configuration)
        onMeasuredContentWidth(controller.mermaidContentWidth(for: uiView))
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

    func makeNSView(context: Context) -> NSTextView {
        let view: NSTextView
        if #available(macOS 13.0, *) {
            view = controller.makeTextKit2View(configuration: configuration)
        } else {
            view = controller.makeTextKit1View(configuration: configuration)
        }
        controller.installMermaidWidthObserver(on: view, onMeasuredContentWidth)
        return view
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        controller.update(textView: nsView, blocks: blocks, diffs: diffs, replaceToken: replaceToken, configuration: configuration)
        onMeasuredContentWidth(controller.mermaidContentWidth(for: nsView))
    }
}
#endif
