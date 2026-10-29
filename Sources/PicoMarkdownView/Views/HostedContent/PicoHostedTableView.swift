#if os(macOS)
import AppKit
import SwiftUI

@MainActor
struct PicoHostedTableView: View {
    let model: PicoHostedTableModel
    let context: PicoHostedAttachmentContext

    var body: some View {
        VStack(spacing: 0) {
            if let header = model.header {
                PicoHostedTableRowView(row: header, model: model, width: context.availableWidth, isHeader: true)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .accessibilityAddTraits(.isHeader)
                Divider()
            }
            ForEach(model.rows) { row in
                PicoHostedTableRowView(row: row, model: model, width: context.availableWidth, isHeader: false)
                    .background(row.id.isMultiple(of: 2) ? Color.primary.opacity(0.025) : Color.clear)
                if row.id != model.rows.last?.id { Divider() }
            }
        }
        .frame(width: context.availableWidth, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if context.isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.16))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(context.isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                              style: StrokeStyle(lineWidth: context.isSelected ? 2 : 1,
                                                 dash: context.isSelected ? [6, 3] : []))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table, \(model.columnCount) columns, \(model.rows.count) data rows")
        .accessibilityAddTraits(context.isSelected ? .isSelected : [])
    }
}
#endif
