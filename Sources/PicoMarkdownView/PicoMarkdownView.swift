import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct PicoMarkdownViewConfiguration {
    public var backgroundColor: Color
    public var contentInsets: EdgeInsets
    public var isSelectable: Bool
    public var isScrollEnabled: Bool

    public init(
        backgroundColor: Color = .clear,
        contentInsets: EdgeInsets = EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8),
        isSelectable: Bool = true,
        isScrollEnabled: Bool = true
    ) {
        self.backgroundColor = backgroundColor
        self.contentInsets = contentInsets
        self.isSelectable = isSelectable
        self.isScrollEnabled = isScrollEnabled
    }

    public static var `default`: PicoMarkdownViewConfiguration { .init() }
}

@MainActor
public final class PicoMarkdownStream: ObservableObject {
    private let renderer: StreamingMarkdownRenderer

    @Published public private(set) var renderedText: NSAttributedString

    public init(
        initialText: String = "",
        parsingOptions: AttributedString.MarkdownParsingOptions = .init(interpretedSyntax: .full)
    ) {
        _ = parsingOptions
        self.renderer = StreamingMarkdownRenderer()

        if initialText.isEmpty {
            self.renderedText = NSAttributedString()
        } else {
            let mutation = renderer.load(markdown: initialText)
            self.renderedText = mutation.replacement
        }
    }

    @MainActor
    public func append(markdown chunk: String) {
        renderer.appendMarkdown(chunk)
        renderedText = renderer.attributedText
    }

    @MainActor
    public func reset(markdown text: String = "") {
        let mutation = renderer.load(markdown: text)
        renderedText = mutation.replacement
    }
}

public struct PicoMarkdownView: View {
    @ObservedObject private var stream: PicoMarkdownStream
    private let configuration: PicoMarkdownViewConfiguration

    public init(
        stream: PicoMarkdownStream,
        configuration: PicoMarkdownViewConfiguration = .default
    ) {
        self.stream = stream
        self.configuration = configuration
    }

    public var body: some View {
        PlatformTextView(attributedText: stream.renderedText, configuration: configuration)
            .background(configuration.backgroundColor)
    }
}

#if canImport(UIKit)
private struct PlatformTextView: UIViewRepresentable {
    var attributedText: NSAttributedString
    let configuration: PicoMarkdownViewConfiguration

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = configuration.isSelectable
        textView.textContainerInset = UIEdgeInsets(
            top: configuration.contentInsets.top,
            left: configuration.contentInsets.leading,
            bottom: configuration.contentInsets.bottom,
            right: configuration.contentInsets.trailing
        )
        textView.adjustsFontForContentSizeCategory = true
        textView.dataDetectorTypes = [.link]
        textView.isScrollEnabled = configuration.isScrollEnabled
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.attributedText != attributedText {
            uiView.attributedText = attributedText
        }

        uiView.isSelectable = configuration.isSelectable
        uiView.isScrollEnabled = configuration.isScrollEnabled
        uiView.backgroundColor = UIColor(configuration.backgroundColor)
        uiView.textContainerInset = UIEdgeInsets(
            top: configuration.contentInsets.top,
            left: configuration.contentInsets.leading,
            bottom: configuration.contentInsets.bottom,
            right: configuration.contentInsets.trailing
        )
    }
}

#elseif canImport(AppKit)
private struct PlatformTextView: NSViewRepresentable {
    var attributedText: NSAttributedString
    let configuration: PicoMarkdownViewConfiguration

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = configuration.isScrollEnabled
        scrollView.hasHorizontalScroller = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = configuration.isSelectable
        textView.textContainerInset = CGSize(
            width: configuration.contentInsets.leading,
            height: configuration.contentInsets.top
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.drawsBackground = false
        textView.textStorage?.setAttributedString(attributedText)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        nsView.drawsBackground = false
        nsView.hasVerticalScroller = configuration.isScrollEnabled

        if let textView = context.coordinator.textView {
            if textView.attributedString() != attributedText {
                textView.textStorage?.setAttributedString(attributedText)
            }
            textView.isSelectable = configuration.isSelectable
            textView.textContainerInset = CGSize(
                width: configuration.contentInsets.leading,
                height: configuration.contentInsets.top
            )
        }
    }

    final class Coordinator {
        var textView: NSTextView?
    }
}
#endif
