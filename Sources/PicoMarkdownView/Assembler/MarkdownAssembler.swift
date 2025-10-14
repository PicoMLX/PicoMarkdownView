import Foundation

public struct AssemblerDiff: Sendable, Equatable {
    public var documentVersion: UInt64
    public var changes: [Change]

    public init(documentVersion: UInt64, changes: [Change]) {
        self.documentVersion = documentVersion
        self.changes = changes
    }

    public enum Change: Sendable, Equatable {
        case blockStarted(id: BlockID, kind: BlockKind, position: Int)
        case runsAppended(id: BlockID, added: Int)
        case codeAppended(id: BlockID, addedBytes: Int)
        case tableHeaderConfirmed(id: BlockID)
        case tableRowAppended(id: BlockID, rowIndex: Int)
        case blockEnded(id: BlockID)
        case blocksDiscarded(range: Range<Int>)
    }
}

public actor MarkdownAssembler {
    private let config: AssemblerConfig
    private var blocks: [BlockEntry] = []
    private var indexByID: [BlockID: Int] = [:]
    private var documentVersion: UInt64 = 0
    private var closedBlockCount: Int = 0
    private var approximateBytes: Int = 0

    public init(config: AssemblerConfig = AssemblerConfig()) {
        self.config = config
    }

    public func apply(_ chunk: ChunkResult) -> AssemblerDiff {
        var changes: [AssemblerDiff.Change] = []
        let finalOpenIDs = chunk.openBlocks.map { $0.id }

        for event in chunk.events {
            switch event {
            case .blockStart(let id, let kind):
                let position = insertionPosition(for: id, finalOpenIDs: finalOpenIDs)
                let entry = BlockEntry(id: id, kind: kind)
                if position >= blocks.count {
                    blocks.append(entry)
                } else {
                    blocks.insert(entry, at: position)
                }
                for pos in position..<blocks.count {
                    indexByID[blocks[pos].id] = pos
                }
                changes.append(.blockStarted(id: id, kind: kind, position: position))

            case .blockAppendInline(let id, let runs):
                guard let index = indexByID[id] else { continue }
                var entry = blocks[index]
                if entry.isClosed { continue }
                let (addedRuns, addedBytes) = entry.appendInline(runs, allowCoalescing: config.coalescePlainRuns)
                blocks[index] = entry
                approximateBytes += addedBytes
                if addedRuns > 0 {
                    changes.append(.runsAppended(id: id, added: addedRuns))
                }

            case .blockAppendFencedCode(let id, let textChunk):
                guard let index = indexByID[id] else { continue }
                var entry = blocks[index]
                if entry.isClosed { continue }
                let addedBytes = entry.appendFencedCode(textChunk)
                blocks[index] = entry
                if addedBytes > 0 {
                    approximateBytes += addedBytes
                    changes.append(.codeAppended(id: id, addedBytes: addedBytes))
                }

            case .tableHeaderCandidate(let id, let cells):
                guard let index = indexByID[id] else { continue }
                var entry = blocks[index]
                if entry.isClosed { continue }
                let delta = entry.setTableHeaderCandidate(cells, allowCoalescing: config.coalescePlainRuns)
                blocks[index] = entry
                approximateBytes += delta
                if approximateBytes < 0 { approximateBytes = 0 }

            case .tableHeaderConfirmed(let id, let alignments):
                guard let index = indexByID[id] else { continue }
                var entry = blocks[index]
                if entry.isClosed { continue }
                entry.confirmTableHeader(alignments: alignments)
                blocks[index] = entry
                changes.append(.tableHeaderConfirmed(id: id))

            case .tableAppendRow(let id, let cells):
                guard let index = indexByID[id] else { continue }
                var entry = blocks[index]
                if entry.isClosed { continue }
                let (rowIndex, addedBytes) = entry.appendTableRow(cells, allowCoalescing: config.coalescePlainRuns)
                blocks[index] = entry
                if addedBytes > 0 {
                    approximateBytes += addedBytes
                }
                changes.append(.tableRowAppended(id: id, rowIndex: rowIndex))

            case .blockEnd(let id):
                guard let index = indexByID[id] else { continue }
                var entry = blocks[index]
                if entry.markClosed() {
                    closedBlockCount += 1
                }
                blocks[index] = entry
                changes.append(.blockEnded(id: id))
            }
        }

        if let truncation = enforceTruncationIfNeeded() {
            changes.append(.blocksDiscarded(range: truncation))
        }

        guard !changes.isEmpty else {
            return AssemblerDiff(documentVersion: documentVersion, changes: [])
        }

        documentVersion &+= 1
        return AssemblerDiff(documentVersion: documentVersion, changes: changes)
    }

    public func blockCount() -> Int {
        blocks.count
    }

    public func blockID(at position: Int) -> BlockID {
        precondition(position >= 0 && position < blocks.count, "Position out of bounds")
        return blocks[position].id
    }

    public func block(_ id: BlockID) -> BlockSnapshot {
        guard let index = indexByID[id] else {
            preconditionFailure("Block with id \(id) not found")
        }
        return blocks[index].makeSnapshot()
    }

    public func makeSnapshot() -> [BlockSnapshot] {
        blocks.map { $0.makeSnapshot() }
    }

    private func firstClosedBlockIndex() -> Int? {
        blocks.firstIndex(where: { $0.isClosed })
    }

    private func shouldTruncate() -> Bool {
        if let max = config.maxClosedBlocks, closedBlockCount > max {
            return true
        }
        if let maxBytes = config.maxBytesApprox, approximateBytes > maxBytes {
            return blocks.contains(where: { $0.isClosed })
        }
        return false
    }

    private func enforceTruncationIfNeeded() -> Range<Int>? {
        guard shouldTruncate() else { return nil }

        var removalStart: Int?
        var removalCount = 0

        var needsReindexFrom: Int?

        while shouldTruncate(), let index = firstClosedBlockIndex() {
            let removed = blocks.remove(at: index)
            indexByID[removed.id] = nil
            approximateBytes -= removed.approxBytes
            if approximateBytes < 0 { approximateBytes = 0 }
            if removed.isClosed {
                closedBlockCount -= 1
            }
            removalStart = removalStart ?? index
            removalCount += 1
            if needsReindexFrom == nil || index < needsReindexFrom! {
                needsReindexFrom = index
            }
        }

        if let start = needsReindexFrom {
            for position in start..<blocks.count {
                indexByID[blocks[position].id] = position
            }
        }

        if let start = removalStart, removalCount > 0 {
            return start..<(start + removalCount)
        }
        return nil
    }
}

private extension MarkdownAssembler {
    func insertionPosition(for id: BlockID, finalOpenIDs: [BlockID]) -> Int {
        guard !blocks.isEmpty else { return 0 }
        if let targetIndex = finalOpenIDs.firstIndex(of: id) {
            var searchIndex = targetIndex + 1
            while searchIndex < finalOpenIDs.count {
                let nextID = finalOpenIDs[searchIndex]
                if let nextPosition = indexByID[nextID] {
                    return nextPosition
                }
                searchIndex += 1
            }

            var reverseIndex = targetIndex
            while reverseIndex > 0 {
                reverseIndex -= 1
                let prevID = finalOpenIDs[reverseIndex]
                if let prevPosition = indexByID[prevID] {
                    return prevPosition + 1
                }
            }
        }

        return blocks.count
    }
}

private struct BlockEntry {
    var id: BlockID
    var kind: BlockKind
    var inlineRuns: [InlineRun]
    var codeText: String
    var table: TableState?
    var isClosed: Bool
    var approxBytes: Int

    init(id: BlockID, kind: BlockKind) {
        self.id = id
        self.kind = kind
        inlineRuns = []
        codeText = ""
        table = nil
        isClosed = false
        approxBytes = 0
    }

    mutating func appendInline(_ runs: [InlineRun], allowCoalescing: Bool) -> (addedRuns: Int, addedBytes: Int) {
        guard !runs.isEmpty else { return (0, 0) }
        var addedBytes = 0
        var addedRuns = 0
        for run in runs {
            addedBytes += BlockEntry.byteCount(for: run)
            if allowCoalescing, let lastIndex = inlineRuns.indices.last, BlockEntry.canCoalesce(inlineRuns[lastIndex], run) {
                inlineRuns[lastIndex].text += run.text
            } else {
                inlineRuns.append(run)
            }
            addedRuns += 1
        }
        approxBytes += addedBytes
        return (addedRuns, addedBytes)
    }

    mutating func appendFencedCode(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        codeText.append(text)
        let bytes = text.utf8.count
        approxBytes += bytes
        return bytes
    }

    mutating func setTableHeaderCandidate(_ cells: [InlineRun], allowCoalescing: Bool) -> Int {
        ensureTableState()
        let normalized = cells.map { cell -> [InlineRun] in
            allowCoalescing ? BlockEntry.coalescedRuns([cell]) : [cell]
        }
        let newBytes = BlockEntry.byteCount(forCells: normalized)
        let delta = newBytes - (table?.headerByteCount ?? 0)
        table?.header = normalized
        table?.headerByteCount = newBytes
        table?.isHeaderConfirmed = false
        approxBytes += delta
        return delta
    }

    mutating func confirmTableHeader(alignments: [TableAlignment]) {
        ensureTableState()
        table?.alignments = alignments
        table?.isHeaderConfirmed = true
    }

    mutating func appendTableRow(_ cells: [[InlineRun]], allowCoalescing: Bool) -> (rowIndex: Int, addedBytes: Int) {
        ensureTableState()
        var normalized: [[InlineRun]] = []
        normalized.reserveCapacity(cells.count)
        var bytes = 0
        for cell in cells {
            let runs = allowCoalescing ? BlockEntry.coalescedRuns(cell) : cell
            bytes += BlockEntry.byteCount(forRuns: runs)
            normalized.append(runs)
        }
        table?.rows.append(normalized)
        table?.rowsByteCount += bytes
        approxBytes += bytes
        let index = (table?.rows.count ?? 1) - 1
        return (index, bytes)
    }

    mutating func markClosed() -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        return true
    }

    func makeSnapshot() -> BlockSnapshot {
        let tableSnapshot = table.map { state in
            TableSnapshot(
                headerCells: state.header,
                alignments: state.alignments,
                rows: state.rows,
                isHeaderConfirmed: state.isHeaderConfirmed
            )
        }

        return BlockSnapshot(
            id: id,
            kind: kind,
            inlineRuns: inlineRuns.isEmpty ? nil : inlineRuns,
            codeText: codeText.isEmpty ? nil : codeText,
            table: tableSnapshot,
            isClosed: isClosed
        )
    }

    private mutating func ensureTableState() {
        if table == nil {
            table = TableState()
        }
    }

    private static func canCoalesce(_ lhs: InlineRun, _ rhs: InlineRun) -> Bool {
        lhs.style == rhs.style && lhs.linkURL == rhs.linkURL && lhs.image == rhs.image
    }

    private static func coalescedRuns(_ runs: [InlineRun]) -> [InlineRun] {
        guard var current = runs.first else { return [] }
        var result: [InlineRun] = []
        for run in runs.dropFirst() {
            if canCoalesce(current, run) {
                current.text += run.text
            } else {
                result.append(current)
                current = run
            }
        }
        result.append(current)
        return result
    }

    private static func byteCount(for run: InlineRun) -> Int {
        run.text.utf8.count
    }

    private static func byteCount(forRuns runs: [InlineRun]) -> Int {
        runs.reduce(into: 0) { total, run in
            total += byteCount(for: run)
        }
    }

    private static func byteCount(forCells cells: [[InlineRun]]) -> Int {
        cells.reduce(into: 0) { total, cell in
            total += byteCount(forRuns: cell)
        }
    }
}

private struct TableState {
    var header: [[InlineRun]]?
    var headerByteCount: Int
    var alignments: [TableAlignment]?
    var rows: [[[InlineRun]]]
    var rowsByteCount: Int
    var isHeaderConfirmed: Bool

    init() {
        header = nil
        headerByteCount = 0
        alignments = nil
        rows = []
        rowsByteCount = 0
        isHeaderConfirmed = false
    }
}
