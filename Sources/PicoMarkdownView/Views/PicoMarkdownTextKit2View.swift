import SwiftUI
import Observation

public struct PicoMarkdownTextKit2View: View {
    private let input: MarkdownStreamingInput

    @State private var viewModel: MarkdownStreamingViewModel

    private init(input: MarkdownStreamingInput, theme: MarkdownRenderTheme) {
        self.input = input
        _viewModel = State(initialValue: MarkdownStreamingViewModel(theme: theme))
    }

    public init(text: String) {
        self.init(input: .text(text), theme: .default())
    }

    public init(chunks: [String]) {
        self.init(input: .chunks(chunks), theme: .default())
    }

    public init(stream: @escaping @Sendable () async -> AsyncStream<String>) {
        self.init(input: .stream(stream), theme: .default())
    }

    public var body: some View {
        let bindable = Bindable(viewModel)
        let snapshot = bindable.attributedText.wrappedValue
        TextKit2Representable(attributedText: NSAttributedString(snapshot))
            .task(id: input.id) {
                await viewModel.consume(input)
            }
    }
}

#if canImport(UIKit)
import UIKit

private struct TextKit2Representable: UIViewRepresentable {
    var attributedText: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        if #available(iOS 16.0, *) {
            let view = UITextView(usingTextLayoutManager: true)
            configure(view)
            return view
        } else {
            let view = UITextView()
            configure(view)
            return view
        }
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.attributedText != attributedText {
            uiView.attributedText = attributedText
        }
    }

    private func configure(_ view: UITextView) {
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
}
#elseif canImport(AppKit)
import AppKit

@available(macOS 13.0, *)
private struct TextKit2Representable: NSViewRepresentable {
    var attributedText: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = CGSize(width: 0, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        if nsView.attributedString() != attributedText {
            nsView.textStorage?.setAttributedString(attributedText)
        }
    }
}
#endif
