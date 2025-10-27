import SwiftUI
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
struct MarkdownInlineTextView: View {
    var content: AttributedString
    var enablesSelection: Bool = true
    @State private var firstBaseline: CGFloat = 0

    private static let lineSpacingMultiplier: CGFloat = 1.24

    init(content: AttributedString, enablesSelection: Bool = true) {
        self.content = content
        self.enablesSelection = enablesSelection
        _firstBaseline = State(initialValue: Self.estimatedBaseline(for: content))
    }

    var body: some View {
        let baseline = firstBaseline
        let styledContent = NSAttributedString(content).applyingLineSpacingMultiplier(Self.lineSpacingMultiplier)
        if content.characters.isEmpty {
            EmptyView()
        } else {
            Representable(content: styledContent,
                          enablesSelection: enablesSelection,
                          baselineChanged: { newBaseline in
                              guard !newBaseline.isNaN, newBaseline.isFinite else { return }
                              Task { @MainActor in
                                  if abs(newBaseline - firstBaseline) > 0.5 {
                                      firstBaseline = newBaseline
                                  }
                              }
                          })
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.top] + baseline
                }
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var accessibilityLabel: Text {
        Text(String(content.characters))
    }

    private static func estimatedBaseline(for content: AttributedString) -> CGFloat {
        let ns = NSAttributedString(content)
        guard ns.length > 0 else { return 0 }
        var range = NSRange(location: 0, length: 0)
        let attributes = ns.attributes(at: 0, effectiveRange: &range)
#if canImport(UIKit)
        let font = attributes[.font] as? UIFont
#else
        let font = attributes[.font] as? NSFont
#endif
        return font?.ascender ?? 0
    }

#if canImport(UIKit)
    private struct Representable: UIViewRepresentable {
        var content: NSAttributedString
        var enablesSelection: Bool
        var baselineChanged: (CGFloat) -> Void

        func makeUIView(context: Context) -> SizingTextView {
            let view = SizingTextView()
            view.baselineChanged = baselineChanged
            configure(view)
            return view
        }

        func updateUIView(_ uiView: SizingTextView, context: Context) {
            uiView.baselineChanged = baselineChanged
            if !uiView.attributedText.isEqual(to: content) {
                uiView.attributedText = content
            }
            if uiView.isSelectable != enablesSelection {
                uiView.isSelectable = enablesSelection
            }
            uiView.invalidateIntrinsicContentSize()
            uiView.reportBaselineIfNeeded()
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
            view.reportBaselineIfNeeded()
        }
    }

    private final class SizingTextView: UITextView {
        var baselineChanged: ((CGFloat) -> Void)?

        override var intrinsicContentSize: CGSize {
            let fittingWidth = bounds.width > 0 ? bounds.width : UIView.noIntrinsicMetric
            let targetWidth: CGFloat
            if fittingWidth == UIView.noIntrinsicMetric {
                targetWidth = super.intrinsicContentSize.width > 0 ? super.intrinsicContentSize.width : UIScreen.main.bounds.width
            } else {
                targetWidth = fittingWidth
            }
            let size = sizeThatFits(CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude))
            return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            invalidateIntrinsicContentSize()
            reportBaselineIfNeeded()
        }

        func reportBaselineIfNeeded() {
            let baseline = computeFirstBaseline()
            baselineChanged?(baseline)
        }

        private func computeFirstBaseline() -> CGFloat {
            guard let textStorage else {
                return textContainerInset.top + (font?.ascender ?? 0)
            }
            if textStorage.length == 0 {
                return textContainerInset.top + (font?.ascender ?? 0)
            }
            var effectiveRange = NSRange(location: 0, length: 0)
            let attributes = textStorage.attributes(at: 0, effectiveRange: &effectiveRange)
            let font = (attributes[.font] as? UIFont) ?? self.font ?? UIFont.preferredFont(forTextStyle: .body)
            return textContainerInset.top + font.ascender
        }
    }
#else
    private struct Representable: NSViewRepresentable {
        var content: NSAttributedString
        var enablesSelection: Bool
        var baselineChanged: (CGFloat) -> Void

        func makeNSView(context: Context) -> SizingTextView {
            let view = SizingTextView()
            view.baselineChanged = baselineChanged
            configure(view)
            return view
        }

        func updateNSView(_ nsView: SizingTextView, context: Context) {
            nsView.baselineChanged = baselineChanged
            if nsView.attributedString() != content {
                nsView.textStorage?.setAttributedString(content)
            }
            if nsView.isSelectable != enablesSelection {
                nsView.isSelectable = enablesSelection
            }
            nsView.invalidateIntrinsicContentSize()
            nsView.reportBaselineIfNeeded()
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
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.reportBaselineIfNeeded()
        }
    }

    private final class SizingTextView: NSTextView {
        var baselineChanged: ((CGFloat) -> Void)?

        override var intrinsicContentSize: NSSize {
            let width = bounds.width > 0 ? bounds.width : NSView.noIntrinsicMetric
            let targetWidth = width == NSView.noIntrinsicMetric ? 0 : width
            let size = sizeThatFits(in: NSSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude))
            return NSSize(width: NSView.noIntrinsicMetric, height: size.height)
        }

        override func layout() {
            super.layout()
            invalidateIntrinsicContentSize()
            reportBaselineIfNeeded()
        }

        private func sizeThatFits(in target: NSSize) -> NSSize {
            guard let textContainer = textContainer, let layoutManager = layoutManager else {
                return super.intrinsicContentSize
            }
            let width = target.width > 0 ? target.width : CGFloat.greatestFiniteMagnitude
            textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            return NSSize(width: used.width, height: used.height)
        }

        func reportBaselineIfNeeded() {
            baselineChanged?(computeFirstBaseline())
        }

        private func computeFirstBaseline() -> CGFloat {
            guard let textStorage = textStorage else {
                return textContainerInset.height + (font?.ascender ?? 0)
            }
            if textStorage.length == 0 {
                return textContainerInset.height + (font?.ascender ?? 0)
            }
            var effectiveRange = NSRange(location: 0, length: 0)
            let attributes = textStorage.attributes(at: 0, effectiveRange: &effectiveRange)
            let font = (attributes[.font] as? NSFont) ?? self.font ?? NSFont.preferredFont(forTextStyle: .body)
            return textContainerInset.height + font.ascender
        }
    }
#endif
}

private extension NSAttributedString {
    func applyingLineSpacingMultiplier(_ multiplier: CGFloat) -> NSAttributedString {
        guard length > 0, multiplier > 0 else { return self }
        let extraFactor = max(multiplier - 1, 0)
        guard extraFactor > 0 else { return self }

        let mutable = NSMutableAttributedString(attributedString: self)
        let fullRange = NSRange(location: 0, length: length)
        mutable.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            let paragraph: NSMutableParagraphStyle
            if let existing = attributes[.paragraphStyle] as? NSParagraphStyle {
                paragraph = (existing.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            } else {
                paragraph = NSMutableParagraphStyle()
            }

#if canImport(UIKit)
            let baseFont = (attributes[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
            let baseLineHeight = baseFont.lineHeight
#else
            let baseFont = (attributes[.font] as? NSFont) ?? NSFont.preferredFont(forTextStyle: .body)
            let baseLineHeight = baseFont.ascender - baseFont.descender + baseFont.leading
#endif
            let desiredSpacing = baseLineHeight * extraFactor
            if paragraph.lineSpacing < desiredSpacing - 0.25 {
                paragraph.lineSpacing = desiredSpacing
            }

            mutable.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        return mutable
    }
}
