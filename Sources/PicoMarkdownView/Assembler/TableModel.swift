import Foundation

public struct TableSnapshot: Sendable, Equatable {
    public var headerCells: [[InlineRun]]?
    public var alignments: [TableAlignment]?
    public var rows: [[[InlineRun]]]
    public var isHeaderConfirmed: Bool

    public init(headerCells: [[InlineRun]]? = nil, alignments: [TableAlignment]? = nil, rows: [[[InlineRun]]] = [], isHeaderConfirmed: Bool = false) {
        self.headerCells = headerCells
        self.alignments = alignments
        self.rows = rows
        self.isHeaderConfirmed = isHeaderConfirmed
    }
}
