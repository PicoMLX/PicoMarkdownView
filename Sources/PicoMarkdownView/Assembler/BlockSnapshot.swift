import Foundation

public struct BlockSnapshot: Sendable, Equatable {
    public var id: BlockID
    public var kind: BlockKind
    public var inlineRuns: [InlineRun]?
    public var codeText: String?
    public var table: TableSnapshot?
    public var isClosed: Bool
    public var parentID: BlockID?
    public var depth: Int
    public var childIDs: [BlockID]

    public init(id: BlockID,
                kind: BlockKind,
                inlineRuns: [InlineRun]? = nil,
                codeText: String? = nil,
                table: TableSnapshot? = nil,
                isClosed: Bool,
                parentID: BlockID? = nil,
                depth: Int = 0,
                childIDs: [BlockID] = []) {
        self.id = id
        self.kind = kind
        self.inlineRuns = inlineRuns
        self.codeText = codeText
        self.table = table
        self.isClosed = isClosed
        self.parentID = parentID
        self.depth = depth
        self.childIDs = childIDs
    }
}
