import SwiftUI
import SwiftMath

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct MathBlockView: View {
    var math: RenderedMath

    var body: some View {
        MathLabelRepresentable(math: math)
            .fixedSize()
            .padding(.vertical, 8)
            .accessibilityLabel(Text(math.tex))
    }
}

#if canImport(UIKit)
private struct MathLabelRepresentable: UIViewRepresentable {
    var math: RenderedMath

    func makeUIView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        configure(label)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ uiView: MTMathUILabel, context: Context) {
        configure(uiView)
    }

    private func configure(_ label: MTMathUILabel) {
        label.labelMode = math.display ? .display : .text
        label.latex = math.tex
        label.fontSize = math.fontSize
        label.textColor = MTColor(Color.primary)
        label.contentInsets = MTEdgeInsets()
        label.displayErrorInline = true

        if let font = MTFontManager().latinModernFont(withSize: math.fontSize) {
            label.font = font
        }

        label.invalidateIntrinsicContentSize()
    }
}
#elseif canImport(AppKit)
private struct MathLabelRepresentable: NSViewRepresentable {
    var math: RenderedMath

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        configure(label)
        return label
    }

    func updateNSView(_ nsView: MTMathUILabel, context: Context) {
        configure(nsView)
    }

    private func configure(_ label: MTMathUILabel) {
        label.labelMode = math.display ? .display : .text
        label.latex = math.tex
        label.fontSize = math.fontSize
        label.textColor = MTColor(Color.primary)
        label.contentInsets = MTEdgeInsets()
        label.displayErrorInline = true

        if let font = MTFontManager().latinModernFont(withSize: math.fontSize) {
            label.font = font
        }

        label.invalidateIntrinsicContentSize()
    }
}
#endif
