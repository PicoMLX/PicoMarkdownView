#if os(macOS)
import AppKit
import Observation

@MainActor
@Observable
final class PicoHostedTableModel {
    private(set) var header: PicoHostedTableRow?
    private(set) var rows: [PicoHostedTableRow] = []
    private(set) var alignments: [TableAlignment]?
    private(set) var columnCount = 1
    private(set) var appendOperations = 0
    @ObservationIgnored var onOpenLink: (@MainActor (URL, String) -> Void)?
    @ObservationIgnored var onHoverLink: (@MainActor (URL?, String, CGRect?) -> Void)?
    @ObservationIgnored private var snapshot = TableSnapshot()

    var headers: [AttributedString]? { header?.cells }

    init(table: RenderedTable, snapshot: TableSnapshot) {
        update(table: table, snapshot: snapshot, refreshExisting: true)
    }

    /// Parser rows are append-only. Presentation refreshes can replace cells
    /// without replacing the stable row objects observed by SwiftUI.
    func update(table: RenderedTable, snapshot: TableSnapshot, refreshExisting: Bool = false) {
        let appendingOnly = !refreshExisting && table.rows.count > rows.count &&
            self.snapshot.headerCells == snapshot.headerCells
        self.snapshot = snapshot
        if let headers = table.headers {
            if let header {
                if !appendingOnly {
                    header.update(cells: headers, source: snapshot.headerCells ?? [])
                }
            } else {
                header = PicoHostedTableRow(id: -1, cells: headers, source: snapshot.headerCells ?? [])
            }
        } else {
            header = nil
        }
        if alignments != table.alignments { alignments = table.alignments }

        if table.rows.count < rows.count {
            rows.removeLast(rows.count - table.rows.count)
            columnCount = max(1, table.headers?.count ?? 0, table.rows.map(\.count).max() ?? 0)
        }
        if refreshExisting || table.rows.count == rows.count {
            for index in rows.indices {
                rows[index].update(cells: table.rows[index],
                                   source: index < snapshot.rows.count ? snapshot.rows[index] : [])
            }
        }
        if table.rows.count > rows.count {
            for index in rows.count..<table.rows.count {
                rows.append(PicoHostedTableRow(id: index, cells: table.rows[index],
                                              source: index < snapshot.rows.count ? snapshot.rows[index] : []))
                columnCount = max(columnCount, table.rows[index].count)
                appendOperations += 1
            }
        }
        columnCount = max(columnCount, table.headers?.count ?? 0)
    }

    func markdownRepresentation() -> String { PicoHostedTableMarkdown.render(snapshot) }

    func open(_ link: PicoHostedTableLink) {
        if let onOpenLink { onOpenLink(link.url, link.label) }
        else { NSWorkspace.shared.open(link.url) }
    }
}
#endif
