import SwiftUI
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct MarkdownInlineTextView: View {
    var content: AttributedString
    var enablesSelection: Bool = true

    var body: some View {
        if content.characters.isEmpty {
            EmptyView()
        } else {
            Representable(content: NSAttributedString(content), enablesSelection: enablesSelection)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var accessibilityLabel: Text {
        Text(String(content.characters))
    }

#if canImport(UIKit)
    private struct Representable: UIViewRepresentable {
        var content: NSAttributedString
        var enablesSelection: Bool

        func makeUIView(context: Context) -> SizingTextView {
            let view = SizingTextView()
            configure(view)
            return view
        }

        func updateUIView(_ uiView: SizingTextView, context: Context) {
            if !uiView.attributedText.isEqual(to: content) {
                uiView.attributedText = content
            }
            if uiView.isSelectable != enablesSelection {
                uiView.isSelectable = enablesSelection
            }
            uiView.invalidateIntrinsicContentSize()
        }

        private func configure(_ view: SizingTextView) {
            view.backgroundColor = .clear
            view.isEditable = false
            view.isSelectable = enablesSelection
            view.isScrollEnabled = false
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.adjustsFontForContentSizeCategory = true
            view.attributedText = content
            view.dataDetectorTypes = []
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
    }

    private final class SizingTextView: UITextView {
        override var intrinsicContentSize: CGSize {
            let fittingWidth = bounds.width > 0 ? bounds.width : UIView.noIntrinsicMetric
            let targetWidth: CGFloat
            if fittingWidth == UIView.noIntrinsicMetric {
                targetWidth = super.intrinsicContentSize.width > 0 ? super.intrinsicContentSize.width : UIScreen.main.bounds.width
            } else {
                targetWidth = fittingWidth
            }
            let size = sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
            return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            invalidateIntrinsicContentSize()
        }
    }
#else
    private struct Representable: NSViewRepresentable {
        var content: NSAttributedString
        var enablesSelection: Bool

        func makeNSView(context: Context) -> SizingTextView {
            let view = SizingTextView()
            configure(view)
            return view
        }

        func updateNSView(_ nsView: SizingTextView, context: Context) {
            if nsView.attributedString() != content {
                nsView.textStorage?.setAttributedString(content)
            }
            if nsView.isSelectable != enablesSelection {
                nsView.isSelectable = enablesSelection
            }
            nsView.invalidateIntrinsicContentSize()
        }

        private func configure(_ view: SizingTextView) {
            view.isEditable = false
            view.isSelectable = enablesSelection
            view.drawsBackground = false
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
            view.isRichText = true
            view.allowsUndo = false
            view.usesAdaptiveColorMappingForDarkAppearance = true
            view.textStorage?.setAttributedString(content)
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = true
            view.frame.size = CGSize(width: 10_000, height: 10_000)
//            view.maxSize = NSSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
    }

    private final class SizingTextView: NSTextView {
        override var intrinsicContentSize: NSSize {
            let width = bounds.width > 0 ? bounds.width : NSView.noIntrinsicMetric
            let targetWidth = width == NSView.noIntrinsicMetric ? 0 : width
            let size = sizeThatFits(in: NSSize(width: targetWidth, height: .greatestFiniteMagnitude))
            return NSSize(width: NSView.noIntrinsicMetric, height: size.height)
        }

        override func layout() {
            super.layout()
            invalidateIntrinsicContentSize()
        }

        private func sizeThatFits(in target: NSSize) -> NSSize {
            guard let textContainer = textContainer, let layoutManager = layoutManager else {
                return super.intrinsicContentSize
            }
            let width = target.width > 0 ? target.width : .greatestFiniteMagnitude
            textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            return NSSize(width: used.width, height: used.height)
        }
    }
#endif
}
