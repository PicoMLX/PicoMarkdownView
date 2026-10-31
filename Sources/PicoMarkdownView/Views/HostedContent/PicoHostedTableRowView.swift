#if os(macOS)
import SwiftUI

@MainActor
struct PicoHostedTableRowView: View {
    let row: PicoHostedTableRow
    let model: PicoHostedTableModel
    let width: CGFloat
    let isHeader: Bool

    private var columnWidth: CGFloat { width / CGFloat(model.columnCount) }

    private var accessibilityDescription: String {
        if isHeader { return "Column headers: " + row.labels.joined(separator: ", ") }
        let values = (0..<model.columnCount).map { column in
            let header = model.header?.labels
            let label = header.flatMap { column < $0.count ? $0[column] : nil } ?? "Column \(column + 1)"
            let value = column < row.labels.count && !row.labels[column].isEmpty ? row.labels[column] : "Empty"
            return "\(label): \(value)"
        }
        return "Row \(row.id + 1). " + values.joined(separator: "; ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<model.columnCount, id: \.self) { column in
                PicoHostedTableCell(content: column < row.cells.count ? row.cells[column] : AttributedString(" "),
                                    width: max(1, columnWidth - 24),
                                    alignment: model.alignments.flatMap { column < $0.count ? $0[column] : nil } ?? .none,
                                    onOpenLink: { model.open($0) },
                                    onHoverLink: { model.onHoverLink?($0, $1, $2) },
                                    onLinkContextMenu: { model.onLinkContextMenu?($0, $1) },
                                    registerLinkMenuPresenter: { row.registerLinkMenuPresenter(in: column, $0) })
                    .frame(width: max(1, columnWidth - 24))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(width: columnWidth, alignment: .topLeading)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityActions {
            ForEach(row.links) { link in
                Button("Open \(link.label)") { model.open(link) }
                Button("Actions for \(link.label)") { row.showLinkMenu(for: link) }
            }
        }
    }
}
#endif
