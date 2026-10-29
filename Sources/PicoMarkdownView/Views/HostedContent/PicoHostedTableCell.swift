#if os(macOS)
import AppKit
import SwiftUI

/// Keep the existing attributed inline renderer, including bitmap math and
/// images. The cell owns no selection or scrolling; the outer document does.
@MainActor
struct PicoHostedTableCell: NSViewRepresentable {
    let content: AttributedString
    let width: CGFloat
    let alignment: TableAlignment
    let onOpenLink: @MainActor (PicoHostedTableLink) -> Void
    let onHoverLink: @MainActor (URL?, String, CGRect?) -> Void

    func makeNSView(context: Context) -> PicoHostedTableCellTextView {
        let view = PicoHostedTableCellTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = false
        view.isRichText = true
        view.importsGraphics = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        return view
    }

    func updateNSView(_ view: PicoHostedTableCellTextView, context: Context) {
        view.onOpenLink = onOpenLink
        view.onHoverLink = onHoverLink
        view.update(content: content, width: width, alignment: alignment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PicoHostedTableCellTextView, context: Context) -> CGSize? {
        nsView.update(content: content, width: width, alignment: alignment)
        return CGSize(width: width, height: nsView.contentHeight())
    }
}
#endif
