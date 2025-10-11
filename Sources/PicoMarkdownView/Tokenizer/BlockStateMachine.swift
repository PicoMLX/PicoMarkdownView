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
        var linePrefixToStrip: Int
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

    private struct HeadingInfo {
        var level: Int
        var prefixLength: Int
    }

    private struct ListInfo {
        var ordered: Bool
        var index: Int?
        var prefixLength: Int
    }

    private struct BlockquoteInfo {
        var prefixLength: Int
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
                analyzeLineIfNeeded(isLineComplete: true)
                let includeNewline = shouldIncludeTerminatingNewline()
                appendDeltaIfNeeded(includeTerminatingNewline: includeNewline)
                finalizeLine(terminated: true, force: false)
            } else {
                lineBuffer.append(character)
                lineAnalyzed = false
            }
        }

        analyzeLineIfNeeded(isLineComplete: false)
        appendDeltaIfNeeded()

        if isFinal {
            analyzeLineIfNeeded(isLineComplete: true)
            appendDeltaIfNeeded()
            finalizeLine(terminated: true, force: true)
            closeCurrentBlock()
        }
    }

    private func shouldIncludeTerminatingNewline() -> Bool {
        guard let ctx = currentBlock else { return false }
        switch ctx.kind {
        case .paragraph, .heading, .listItem, .blockquote:
            return lineBuffer.hasSuffix("  ")
        case .fencedCode:
            return !ctx.fenceJustOpened
        case .unknown:
            return !lineBuffer.isEmpty
        case .table:
            return false
        }
    }

    private mutating func analyzeLineIfNeeded(isLineComplete: Bool) {
        if lineAnalyzed { return }

        let trimmed = lineBuffer.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            lineAnalyzed = true
            return
        }

        if currentBlock == nil {
            if let fence = detectFenceOpening(lineBuffer) {
                openFencedCode(fence)
                emittedCount = lineBuffer.count
                lineAnalyzed = true
                return
            }

            if let heading = detectHeading(lineBuffer) {
                openInlineBlock(kind: .heading(level: heading.level), prefixToStrip: heading.prefixLength)
                emittedCount = min(lineBuffer.count, heading.prefixLength)
                lineAnalyzed = true
                return
            }

            if let list = detectList(lineBuffer) {
                openInlineBlock(kind: .listItem(ordered: list.ordered, index: list.index), prefixToStrip: list.prefixLength)
                emittedCount = min(lineBuffer.count, list.prefixLength)
                lineAnalyzed = true
                return
            }

            if let quote = detectBlockquote(lineBuffer) {
                openInlineBlock(kind: .blockquote, prefixToStrip: quote.prefixLength)
                emittedCount = min(lineBuffer.count, quote.prefixLength)
                lineAnalyzed = true
                return
            }

            if isLineComplete, detectTableCandidate(lineBuffer) {
                openTable(lineBuffer)
                emittedCount = lineBuffer.count
                lineAnalyzed = true
                return
            }

            if isLineComplete, lineBuffer.hasPrefix(":::") {
                openUnknown()
                appendUnknownLiteral(lineBuffer)
                emittedCount = lineBuffer.count
                lineAnalyzed = true
                return
            }

            openInlineBlock(kind: .paragraph)
            emittedCount = 0
            lineAnalyzed = true
            return
        }

        if var ctx = currentBlock {
            switch ctx.kind {
            case .paragraph:
                if let fence = detectFenceOpening(lineBuffer) {
                    closeCurrentBlock()
                    openFencedCode(fence)
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
                if let heading = detectHeading(lineBuffer) {
                    closeCurrentBlock()
                    openInlineBlock(kind: .heading(level: heading.level), prefixToStrip: heading.prefixLength)
                    emittedCount = min(lineBuffer.count, heading.prefixLength)
                    lineAnalyzed = true
                    return
                }
                if let list = detectList(lineBuffer) {
                    closeCurrentBlock()
                    openInlineBlock(kind: .listItem(ordered: list.ordered, index: list.index), prefixToStrip: list.prefixLength)
                    emittedCount = min(lineBuffer.count, list.prefixLength)
                    lineAnalyzed = true
                    return
                }
                if let quote = detectBlockquote(lineBuffer) {
                    closeCurrentBlock()
                    openInlineBlock(kind: .blockquote, prefixToStrip: quote.prefixLength)
                    emittedCount = min(lineBuffer.count, quote.prefixLength)
                    lineAnalyzed = true
                    return
                }
                if isLineComplete, detectTableCandidate(lineBuffer) {
                    closeCurrentBlock()
                    openTable(lineBuffer)
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
                if isLineComplete, lineBuffer.hasPrefix(":::") {
                    closeCurrentBlock()
                    openUnknown()
                    appendUnknownLiteral(lineBuffer)
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
            case .heading:
                // heading handled on first line only
                break
            case .listItem:
                if let list = detectList(lineBuffer) {
                    if shouldStartNewListItem(currentKind: ctx.kind, list: list, emittedCount: emittedCount) {
                        closeCurrentBlock()
                        openInlineBlock(kind: .listItem(ordered: list.ordered, index: list.index), prefixToStrip: list.prefixLength)
                        emittedCount = min(lineBuffer.count, list.prefixLength)
                    } else {
                        ctx.linePrefixToStrip = list.prefixLength
                        currentBlock = ctx
                        if emittedCount < list.prefixLength {
                            emittedCount = min(lineBuffer.count, list.prefixLength)
                        }
                    }
                    lineAnalyzed = true
                    return
                }
                let continuation = listContinuationPrefixLength(lineBuffer)
                if continuation > 0 {
                    ctx.linePrefixToStrip = continuation
                    currentBlock = ctx
                    if emittedCount < continuation {
                        emittedCount = min(lineBuffer.count, continuation)
                    }
                    lineAnalyzed = true
                    return
                }
            case .blockquote:
                if let quote = detectBlockquote(lineBuffer) {
                    ctx.linePrefixToStrip = quote.prefixLength
                    currentBlock = ctx
                    if emittedCount < quote.prefixLength {
                        emittedCount = min(lineBuffer.count, quote.prefixLength)
                    }
                } else {
                    ctx.linePrefixToStrip = 0
                    currentBlock = ctx
                }
            case .fencedCode:
                break
            case .table:
                break
            case .unknown:
                break
            }
        }

        lineAnalyzed = true
    }

    private mutating func appendDeltaIfNeeded(includeTerminatingNewline: Bool = false) {
        guard let ctx = currentBlock else { return }
        if ctx.kind == .table {
            emittedCount = lineBuffer.count
            return
        }
        var context = ctx
        let sourceLine: String = includeTerminatingNewline ? lineBuffer + "\n" : lineBuffer
        guard emittedCount < sourceLine.count else { return }
        let start = sourceLine.index(sourceLine.startIndex, offsetBy: emittedCount)
        let delta = String(sourceLine[start...])
        if case .fencedCode = context.kind,
           !context.fenceJustOpened,
           isClosingFence(lineBuffer.trimmingCharacters(in: .whitespaces), fence: context.fenceInfo) {
            emittedCount = lineBuffer.count
            currentBlock = context
            return
        }
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
            case .heading:
                closeCurrentBlock()
            case .listItem:
                if isBlank || force {
                    closeCurrentBlock()
                } else {
                    appendToCurrent("\n")
                }
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
                if (!ctx.fenceJustOpened && isClosingFence(trimmed, fence: ctx.fenceInfo)) || force {
                    closeCurrentBlock()
                }
            case .table:
                handleTableLine(rawLine: rawLine, trimmed: trimmed, force: force)
            }
            if var updated = currentBlock {
                updated.fenceJustOpened = false
                currentBlock = updated
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
                    if let lastIndex = events.indices.last,
                       case .blockAppendInline(let existingID, var existingRuns) = events[lastIndex],
                       existingID == ctx.id {
                        existingRuns.append(contentsOf: runs)
                        events[lastIndex] = .blockAppendInline(id: ctx.id, runs: existingRuns)
                    } else {
                        events.append(.blockAppendInline(id: ctx.id, runs: runs))
                    }
                }
                ctx.inlineParser = parser
            }
        case .unknown:
            ctx.literal.append(text)
        case .fencedCode:
            if let lastIndex = events.indices.last {
                if case .blockAppendFencedCode(let existingID, let existingText) = events[lastIndex], existingID == ctx.id {
                    events[lastIndex] = .blockAppendFencedCode(id: ctx.id, textChunk: existingText + text)
                } else {
                    events.append(.blockAppendFencedCode(id: ctx.id, textChunk: text))
                }
            } else {
                events.append(.blockAppendFencedCode(id: ctx.id, textChunk: text))
            }
            ctx.fenceJustOpened = false
        case .table:
            // table text handled at line boundaries
            break
        }
        ctx.linePrefixToStrip = 0
    }

    private mutating func appendUnknownLiteral(_ text: String) {
        guard !text.isEmpty, var ctx = currentBlock, ctx.kind == .unknown else { return }
        ctx.literal.append(text)
        currentBlock = ctx
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
        guard let ctx = currentBlock else { return }
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

    private mutating func openInlineBlock(kind: BlockKind, prefixToStrip: Int = 0) {
        let context = BlockContext(
            id: nextID,
            kind: kind,
            inlineParser: InlineParser(),
            tableState: nil,
            fenceInfo: nil,
            literal: "",
            fenceJustOpened: false,
            linePrefixToStrip: prefixToStrip
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
            fenceJustOpened: false,
            linePrefixToStrip: 0
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
            fenceJustOpened: true,
            linePrefixToStrip: 0
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
            fenceJustOpened: false,
            linePrefixToStrip: 0
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

    private func detectHeading(_ line: String) -> HeadingInfo? {
        var index = line.startIndex
        var level = 0
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
        let prefixLength = level + 1 // heading markers + following space
        guard line.count > prefixLength else { return nil }
        return HeadingInfo(level: level, prefixLength: prefixLength)
    }

    private func detectList(_ line: String) -> ListInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") {
            return ListInfo(ordered: false, index: nil, prefixLength: 2)
        }
        if trimmed.hasPrefix("* ") {
            return ListInfo(ordered: false, index: nil, prefixLength: 2)
        }
        if trimmed.hasPrefix("+ ") {
            return ListInfo(ordered: false, index: nil, prefixLength: 2)
        }
        if let dot = trimmed.firstIndex(of: "."), dot != trimmed.startIndex {
            let numberPart = trimmed[..<dot]
            if let number = Int(numberPart) {
                let afterDot = trimmed.index(after: dot)
                if afterDot < trimmed.endIndex, trimmed[afterDot] == " " {
                    let digitCount = numberPart.count
                    let prefixLength = digitCount + 2 // digits + ". "
                    return ListInfo(ordered: true, index: number, prefixLength: prefixLength)
                }
            }
        }
        return nil
    }

    private func detectBlockquote(_ line: String) -> BlockquoteInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("> ") else { return nil }
        return BlockquoteInfo(prefixLength: 2)
    }

    private func listContinuationPrefixLength(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " || character == "\t" {
                count += 1
            } else {
                break
            }
        }
        return count >= 2 ? count : 0
    }

    private func shouldStartNewListItem(currentKind: BlockKind, list: ListInfo, emittedCount: Int) -> Bool {
        guard case .listItem(let currentOrdered, let currentIndex) = currentKind else { return true }
        if emittedCount > list.prefixLength {
            if list.ordered == currentOrdered,
               list.index == currentIndex {
                return false
            }
        }
        if list.ordered != currentOrdered {
            return true
        }
        if list.ordered {
            return list.index != currentIndex
        }
        // Unordered list items reuse the same marker; treat as new item when we hit the marker again.
        return emittedCount <= list.prefixLength
    }

    private func detectTableCandidate(_ line: String) -> Bool {
        guard line.first == "|" else { return false }
        let pipeCount = line.filter { $0 == "|" }.count
        return pipeCount >= 2
    }

    private func splitCells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaping = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if escaping {
                current.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "|" {
                cells.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        if escaping {
            current.append("\\")
        }
        cells.append(current)

        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        var result = cells
        if trimmedLine.hasPrefix("|") && !result.isEmpty {
            result.removeFirst()
        }
        if trimmedLine.hasSuffix("|") && !result.isEmpty {
            result.removeLast()
        }
        return result.map { $0.trimmingCharacters(in: .whitespaces) }
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
                result.append(.left)
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
