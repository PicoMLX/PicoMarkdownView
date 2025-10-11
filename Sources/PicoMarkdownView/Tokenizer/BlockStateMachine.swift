import Foundation

struct StreamingParser {
    private struct BlockContext {
        var id: BlockID
        var kind: BlockKind
        var inlineParser: InlineParser?
        var tableState: TableState?
        var fenceInfo: FenceInfo?
        var literal: String
        var fenceJustOpened: Bool
    }

    private struct TableState {
        enum Stage { case header, separatorPending, rows }
        var stage: Stage = .header
        var alignments: [TableAlignment] = []
    }

    private struct FenceInfo {
        var marker: String
        var language: String?
    }

    private var nextID: BlockID = 1
    private var currentBlock: BlockContext?
    private var lineBuffer: String = ""
    private var emittedCount: Int = 0
    private var lineAnalyzed: Bool = false
    private var events: [BlockEvent] = []

    mutating func feed(_ chunk: String) -> ChunkResult {
        process(normalizeLineEndings(chunk), isFinal: false)
        let result = ChunkResult(events: events, openBlocks: snapshotOpenBlocks())
        events.removeAll(keepingCapacity: true)
        return result
    }

    mutating func finish() -> ChunkResult {
        process("", isFinal: true)
        let result = ChunkResult(events: events, openBlocks: snapshotOpenBlocks())
        events.removeAll(keepingCapacity: true)
        return result
    }

    private mutating func process(_ text: String, isFinal: Bool) {
        for character in text {
            if character == "\n" {
                analyzeLineIfNeeded()
                appendDeltaIfNeeded()
                finalizeLine(terminated: true, force: false)
            } else {
                lineBuffer.append(character)
                analyzeLineIfNeeded()
            }
        }

        appendDeltaIfNeeded()

        if isFinal {
            analyzeLineIfNeeded()
            appendDeltaIfNeeded()
            finalizeLine(terminated: true, force: true)
            closeCurrentBlock()
        }
    }

    private mutating func analyzeLineIfNeeded() {
        if lineAnalyzed { return }

        let trimmed = lineBuffer.trimmingCharacters(in: .whitespaces)

        if let ctx = currentBlock {
            if ctx.kind == .paragraph {
                if let fence = detectFenceOpening(lineBuffer) {
                    closeCurrentBlock()
                    openFencedCode(fence)
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
                if let (level, content) = detectHeading(lineBuffer) {
                    closeCurrentBlock()
                    openInlineBlock(kind: .heading(level: level))
                    appendToCurrent(content)
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
                if let list = detectList(lineBuffer) {
                    closeCurrentBlock()
                    openInlineBlock(kind: .listItem(ordered: list.ordered, index: list.index))
                    appendToCurrent(list.content)
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
                if let quote = detectBlockquote(lineBuffer) {
                    closeCurrentBlock()
                    openInlineBlock(kind: .blockquote)
                    appendToCurrent(quote)
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
                if detectTableCandidate(lineBuffer) {
                    closeCurrentBlock()
                    openTable(lineBuffer)
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
                if lineBuffer.hasPrefix(":::") {
                    closeCurrentBlock()
                    openUnknown()
                    appendToCurrent(lineBuffer)
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
            }
            lineAnalyzed = true
            return
        }

        if trimmed.isEmpty {
            lineAnalyzed = true
            return
        }

        if let fence = detectFenceOpening(lineBuffer) {
            openFencedCode(fence)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return
        }

        if let (level, content) = detectHeading(lineBuffer) {
            openInlineBlock(kind: .heading(level: level))
            appendToCurrent(content)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return
        }

        if let list = detectList(lineBuffer) {
            openInlineBlock(kind: .listItem(ordered: list.ordered, index: list.index))
            appendToCurrent(list.content)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return
        }

        if let quote = detectBlockquote(lineBuffer) {
            openInlineBlock(kind: .blockquote)
            appendToCurrent(quote)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return
        }

        if detectTableCandidate(lineBuffer) {
            openTable(lineBuffer)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return
        }

        if lineBuffer.hasPrefix(":::") {
            openUnknown()
            appendToCurrent(lineBuffer)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return
        }

        openInlineBlock(kind: .paragraph)
        lineAnalyzed = true
    }

    private mutating func appendDeltaIfNeeded() {
        guard let ctx = currentBlock else { return }
        if ctx.kind == .table {
            emittedCount = lineBuffer.count
            return
        }
        var context = ctx
        guard emittedCount < lineBuffer.count else { return }
        let start = lineBuffer.index(lineBuffer.startIndex, offsetBy: emittedCount)
        let delta = String(lineBuffer[start...])
        append(delta, context: &context)
        currentBlock = context
        emittedCount = lineBuffer.count
    }

    private mutating func finalizeLine(terminated: Bool, force: Bool) {
        if !terminated && !force { return }
        let rawLine = lineBuffer
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        let isBlank = trimmed.isEmpty

        if var ctx = currentBlock {
            switch ctx.kind {
            case .paragraph:
                if isBlank {
                    closeCurrentBlock()
                } else if force {
                    closeCurrentBlock()
                }
            case .heading, .listItem:
                closeCurrentBlock()
            case .blockquote:
                if isBlank || force {
                    closeCurrentBlock()
                } else {
                    appendToCurrent("\n")
                }
            case .unknown:
                if !isBlank {
                    append("\n", context: &ctx)
                }
                if isBlank || force {
                    closeCurrentBlock()
                }
            case .fencedCode:
                if isClosingFence(trimmed, fence: ctx.fenceInfo) || force {
                    closeCurrentBlock()
                } else if !ctx.fenceJustOpened {
                    append("\n", context: &ctx)
                }
            case .table:
                handleTableLine(rawLine: rawLine, trimmed: trimmed, force: force)
            }
            if currentBlock != nil {
                ctx.fenceJustOpened = false
                currentBlock = ctx
            }
        }

        resetLineState()
    }

    private mutating func resetLineState() {
        lineBuffer.removeAll(keepingCapacity: true)
        emittedCount = 0
        lineAnalyzed = false
    }

    private mutating func appendToCurrent(_ text: String) {
        guard var ctx = currentBlock else { return }
        append(text, context: &ctx)
        currentBlock = ctx
    }

    private mutating func append(_ text: String, context ctx: inout BlockContext) {
        guard !text.isEmpty else { return }
        switch ctx.kind {
        case .paragraph, .heading, .listItem, .blockquote:
            if var parser = ctx.inlineParser {
                let runs = parser.append(text)
                if !runs.isEmpty {
                    events.append(.blockAppendInline(id: ctx.id, runs: runs))
                }
                ctx.inlineParser = parser
            }
        case .unknown:
            ctx.literal.append(text)
        case .fencedCode:
            events.append(.blockAppendFencedCode(id: ctx.id, textChunk: text))
            ctx.fenceJustOpened = false
        case .table:
            // table text handled at line boundaries
            break
        }
    }

    private mutating func handleTableLine(rawLine: String, trimmed: String, force: Bool) {
        guard var ctx = currentBlock, var table = ctx.tableState else {
            if force { closeCurrentBlock() }
            return
        }

        switch table.stage {
        case .header:
            table.stage = .separatorPending
        case .separatorPending:
            if let alignments = parseAlignment(trimmed) {
                table.alignments = alignments
                events.append(.tableHeaderConfirmed(id: ctx.id, alignments: alignments))
                table.stage = .rows
            } else if force {
                closeCurrentBlock()
                return
            }
        case .rows:
            if trimmed.isEmpty {
                closeCurrentBlock()
                return
            }
            let row = parseRow(rawLine)
            events.append(.tableAppendRow(id: ctx.id, cells: row))
        }

        ctx.tableState = table
        currentBlock = ctx

        if force {
            closeCurrentBlock()
        }
    }

    private mutating func closeCurrentBlock() {
        guard var ctx = currentBlock else { return }
        if var parser = ctx.inlineParser {
            let runs = parser.finish()
            if !runs.isEmpty {
                events.append(.blockAppendInline(id: ctx.id, runs: runs))
            }
        }
        if !ctx.literal.isEmpty {
            events.append(.blockAppendInline(id: ctx.id, runs: [InlineRun(text: ctx.literal)]))
        }
        events.append(.blockEnd(id: ctx.id))
        currentBlock = nil
    }

    private mutating func openInlineBlock(kind: BlockKind) {
        let context = BlockContext(
            id: nextID,
            kind: kind,
            inlineParser: InlineParser(),
            tableState: nil,
            fenceInfo: nil,
            literal: "",
            fenceJustOpened: false
        )
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: kind))
        currentBlock = context
    }

    private mutating func openUnknown() {
        let context = BlockContext(
            id: nextID,
            kind: .unknown,
            inlineParser: nil,
            tableState: nil,
            fenceInfo: nil,
            literal: "",
            fenceJustOpened: false
        )
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: .unknown))
        currentBlock = context
    }

    private mutating func openFencedCode(_ fence: FenceInfo) {
        let context = BlockContext(
            id: nextID,
            kind: .fencedCode(language: fence.language),
            inlineParser: nil,
            tableState: nil,
            fenceInfo: fence,
            literal: "",
            fenceJustOpened: true
        )
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: .fencedCode(language: fence.language)))
        currentBlock = context
    }

    private mutating func openTable(_ line: String) {
        var context = BlockContext(
            id: nextID,
            kind: .table,
            inlineParser: nil,
            tableState: TableState(),
            fenceInfo: nil,
            literal: "",
            fenceJustOpened: false
        )
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: .table))
        let headerCells = splitCells(line).map { InlineRun(text: $0) }
        events.append(.tableHeaderCandidate(id: context.id, cells: headerCells))
        context.tableState = TableState(stage: .header)
        currentBlock = context
    }

    private func detectFenceOpening(_ line: String) -> FenceInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var index = trimmed.startIndex
        var marker = ""
        while index < trimmed.endIndex, trimmed[index] == first {
            marker.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        guard marker.count >= 3 else { return nil }
        let info = trimmed[index...].trimmingCharacters(in: .whitespaces)
        return FenceInfo(marker: marker, language: info.isEmpty ? nil : info)
    }

    private func isClosingFence(_ line: String, fence: FenceInfo?) -> Bool {
        guard let fence = fence else { return false }
        guard line.hasPrefix(fence.marker) else { return false }
        let remainder = line.dropFirst(fence.marker.count)
        return remainder.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func detectHeading(_ line: String) -> (Int, String)? {
        var index = line.startIndex
        var level = 0
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
        let contentStart = line.index(after: index)
        return (level, String(line[contentStart...]))
    }

    private func detectList(_ line: String) -> (ordered: Bool, index: Int?, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") { return (false, nil, String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("* ") { return (false, nil, String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("+ ") { return (false, nil, String(trimmed.dropFirst(2))) }
        if let dot = trimmed.firstIndex(of: "."), dot != trimmed.startIndex {
            let numberPart = trimmed[..<dot]
            if let number = Int(numberPart) {
                let afterDot = trimmed.index(after: dot)
                if afterDot < trimmed.endIndex, trimmed[afterDot] == " " {
                    let contentStart = trimmed.index(after: afterDot)
                    return (true, number, String(trimmed[contentStart...]))
                }
            }
        }
        return nil
    }

    private func detectBlockquote(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("> ") else { return nil }
        return String(trimmed.dropFirst(2))
    }

    private func detectTableCandidate(_ line: String) -> Bool {
        line.contains("|")
    }

    private func splitCells(_ line: String) -> [String] {
        var parts = line.split(separator: "|", omittingEmptySubsequences: false)
        if let first = parts.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.removeFirst()
        }
        if let last = parts.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.removeLast()
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func parseAlignment(_ line: String) -> [TableAlignment]? {
        let cells = splitCells(line)
        guard !cells.isEmpty else { return nil }
        var result: [TableAlignment] = []
        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let hyphenCount = trimmed.filter { $0 == "-" }.count
            guard hyphenCount >= 1 else { return nil }
            if trimmed.hasPrefix(":") && trimmed.hasSuffix(":") {
                result.append(.center)
            } else if trimmed.hasPrefix(":") {
                result.append(.left)
            } else if trimmed.hasSuffix(":") {
                result.append(.right)
            } else {
                result.append(.none)
            }
        }
        return result
    }

    private func parseRow(_ line: String) -> [[InlineRun]] {
        splitCells(line).map { InlineParser.parseAll($0) }
    }

    private func snapshotOpenBlocks() -> [OpenBlockState] {
        guard let ctx = currentBlock else { return [] }
        return [OpenBlockState(id: ctx.id, kind: ctx.kind)]
    }

    private func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
