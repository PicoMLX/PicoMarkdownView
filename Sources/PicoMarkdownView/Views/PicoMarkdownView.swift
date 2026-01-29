import SwiftUI
import Observation

public struct PicoMarkdownView: View {
    private let input: MarkdownStreamingInput
    private let configuration: PicoTextKitConfiguration

    @State private var viewModel: MarkdownStreamingViewModel
    @StateObject private var controller = TextKitStreamingController()

    private init(input: MarkdownStreamingInput,
                 theme: MarkdownRenderTheme,
                 configuration: PicoTextKitConfiguration) {
        self.input = input
        self.configuration = configuration
        _viewModel = State(initialValue: MarkdownStreamingViewModel(theme: theme))
    }

    public init(_ text: String,
                theme: MarkdownRenderTheme = .default(),
                configuration: PicoTextKitConfiguration = .default()) {
        self.init(input: .text(text), theme: theme, configuration: configuration)
    }

    public init(chunks: [String],
                theme: MarkdownRenderTheme = .default(),
                configuration: PicoTextKitConfiguration = .default()) {
        self.init(input: .chunks(chunks), theme: theme, configuration: configuration)
    }

    public init(stream: @escaping @Sendable () async -> AsyncStream<String>,
                theme: MarkdownRenderTheme = .default(),
                configuration: PicoTextKitConfiguration = .default()) {
        self.init(input: .stream(stream), theme: theme, configuration: configuration)
    }

    public var body: some View {
        let bindable = Bindable(viewModel)
        let blocks = bindable.blocks.wrappedValue
        let diffs = bindable.diffQueue.wrappedValue
        let replaceToken = bindable.replaceToken.wrappedValue
        TextKit2Container(controller: controller,
                          blocks: blocks,
                          diffs: diffs,
                          replaceToken: replaceToken,
                          configuration: configuration)
            .task(id: input.id) {
                await viewModel.consume(input)
            }
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

    func makeUIView(context: Context) -> UITextView {
        if #available(iOS 16.0, *) {
            return controller.makeTextKit2View(configuration: configuration)
        } else {
            return controller.makeTextKit1View(configuration: configuration)
        }
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        controller.update(textView: uiView, blocks: blocks, diffs: diffs, replaceToken: replaceToken, configuration: configuration)
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

    func makeNSView(context: Context) -> NSTextView {
        if #available(macOS 13.0, *) {
            return controller.makeTextKit2View(configuration: configuration)
        } else {
            return controller.makeTextKit1View(configuration: configuration)
        }
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        controller.update(textView: nsView, blocks: blocks, diffs: diffs, replaceToken: replaceToken, configuration: configuration)
    }
}
#endif
