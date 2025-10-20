import Foundation

struct StreamingParser {
    static let defaultMaxLookBehind = 1024

    private let maxLineLookBehind: Int
    private let lookBehindSlack: Int

    init(maxLookBehind: Int = StreamingParser.defaultMaxLookBehind) {
        let capped = max(0, maxLookBehind)
        self.maxLineLookBehind = capped
        if capped == 0 {
            self.lookBehindSlack = 0
        } else {
            self.lookBehindSlack = max(32, capped / 2)
        }
    }

    private struct BlockContext {
        var id: BlockID
        var kind: BlockKind
        var inlineParser: InlineParser?
        var tableState: TableState?
        var fenceInfo: FenceInfo?
        var literal: String
        var fenceJustOpened: Bool
        var linePrefixToStrip: Int
        var headingPendingSuffix: String
        var eventStartIndex: Int
        var listIndent: Int
        var pendingSoftBreak: Bool = false
    }

    private struct TableState {
        enum Stage { case header, separatorPending, rows }
        var stage: Stage = .header
        var alignments: [TableAlignment] = []
        var bufferedLines: [String] = []
    }

    private struct FenceInfo {
        var marker: String
        var language: String?
        var closingMarker: String?

        init(marker: String, language: String?, closingMarker: String? = nil) {
            self.marker = marker
            self.language = language
            self.closingMarker = closingMarker
        }
    }

    private struct DisplayMathOpening {
        var marker: String
        var closing: String
        var content: String
        var closesOnSameLine: Bool
        var leadingIndent: Int
    }

    private struct HeadingInfo {
        var level: Int
        var prefixLength: Int
    }

    private struct ListInfo {
        var ordered: Bool
        var index: Int?
        var indent: Int
        var markerLength: Int
        var indentText: String
        var task: TaskListState?
        var taskMarkerLength: Int

        var prefixLength: Int { indent + markerLength + taskMarkerLength }
    }

    private struct BlockquoteInfo {
        var prefixLength: Int
    }

    private var nextID: BlockID = 1
    private var contextStack: [BlockContext] = []

    private var currentBlock: BlockContext? {
        contextStack.last
    }

    private mutating func pushBlock(_ context: BlockContext) {
        contextStack.append(context)
    }

    private mutating func setCurrentBlock(_ context: BlockContext) {
        guard !contextStack.isEmpty else {
            contextStack.append(context)
            return
        }
        contextStack[contextStack.count - 1] = context
    }

    @discardableResult
    private mutating func popBlock() -> BlockContext? {
        contextStack.popLast()
    }
    private mutating func closeListContexts(deeperThan indent: Int) {
        while let ctx = currentBlock {
            guard case .listItem = ctx.kind, ctx.listIndent > indent else { break }
            closeCurrentBlock()
        }
    }
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
        case .math:
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
            if var ctx = currentBlock, case .listItem = ctx.kind {
                ctx.linePrefixToStrip = 0
                setCurrentBlock(ctx)
            }
            lineAnalyzed = true
            return
        }

        if contextStack.isEmpty {
            if let mathOpen = detectDisplayMathOpening(lineBuffer) {
                if mathOpen.closesOnSameLine {
                    emitSingleLineDisplayMath(content: mathOpen.content)
                } else {
                    openDisplayMathBlock(marker: mathOpen.marker, closing: mathOpen.closing, initialContent: mathOpen.content, indent: mathOpen.leadingIndent)
                }
                emittedCount = lineBuffer.count
                lineAnalyzed = true
                return
            }
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
                openListItem(list)
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
                if let mathOpen = detectDisplayMathOpening(lineBuffer) {
                    closeCurrentBlock()
                    if mathOpen.closesOnSameLine {
                        emitSingleLineDisplayMath(content: mathOpen.content)
                    } else {
                        openDisplayMathBlock(marker: mathOpen.marker, closing: mathOpen.closing, initialContent: mathOpen.content, indent: mathOpen.leadingIndent)
                    }
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
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
                    openListItem(list)
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
            if isLineComplete, detectHorizontalRule(lineBuffer, indent: 0) {
                let rule = lineBuffer.trimmingCharacters(in: .whitespaces)
                appendToCurrent(rule)
                closeCurrentBlock()
                let divider = BlockContext(
                    id: nextID,
                    kind: .paragraph,
                    inlineParser: InlineParser(),
                    tableState: nil,
                    fenceInfo: nil,
                    literal: "",
                    fenceJustOpened: false,
                    linePrefixToStrip: 0,
                    headingPendingSuffix: "",
                    eventStartIndex: events.count,
                    listIndent: 0
                )
                nextID &+= 1
                events.append(.blockStart(id: divider.id, kind: .paragraph))
                appendToCurrent(rule)
                closeCurrentBlock()
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
                if let mathOpen = detectDisplayMathOpening(lineBuffer) {
                    closeCurrentBlock()
                    if mathOpen.closesOnSameLine {
                        emitSingleLineDisplayMath(content: mathOpen.content)
                    } else {
                        openDisplayMathBlock(marker: mathOpen.marker, closing: mathOpen.closing, initialContent: mathOpen.content, indent: mathOpen.leadingIndent)
                    }
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
                if let list = detectList(lineBuffer) {
                    closeListContexts(deeperThan: list.indent)

                    if let current = currentBlock, case .listItem = current.kind {
                        if list.indent > current.listIndent {
                            openListItem(list)
                            emittedCount = min(lineBuffer.count, list.prefixLength)
                        } else if list.indent == current.listIndent {
                            if shouldStartNewListItem(currentContext: current, list: list, emittedCount: emittedCount) {
                                closeCurrentBlock()
                                openListItem(list)
                                emittedCount = min(lineBuffer.count, list.prefixLength)
                            } else {
                                var updated = current
                                updated.linePrefixToStrip = list.prefixLength
                                setCurrentBlock(updated)
                                if emittedCount < list.prefixLength {
                                    emittedCount = min(lineBuffer.count, list.prefixLength)
                                }
                            }
                        } else {
                            closeCurrentBlock()
                            openListItem(list)
                            emittedCount = min(lineBuffer.count, list.prefixLength)
                        }
                    } else {
                        openListItem(list)
                        emittedCount = min(lineBuffer.count, list.prefixLength)
                    }

                    lineAnalyzed = true
                    return
                }

                if var current = currentBlock, case .listItem = current.kind {
                    let continuation = listContinuationPrefixLength(lineBuffer, currentIndent: current.listIndent)
                    if isLineComplete, detectTableCandidate(lineBuffer) {
                        closeCurrentBlock()
                        openTable(lineBuffer)
                        emittedCount = lineBuffer.count
                        lineAnalyzed = true
                        return
                    }
                    if isLineComplete, detectHorizontalRule(lineBuffer, indent: current.listIndent) {
                        closeCurrentBlock()
                        closeListContexts(deeperThan: current.listIndent - 1)
                        openInlineBlock(kind: .paragraph)
                        emittedCount = 0
                        appendToCurrent(lineBuffer)
                        closeCurrentBlock()
                        lineAnalyzed = true
                        return
                    }
                    if continuation > 0 {
                        current.linePrefixToStrip = continuation
                        setCurrentBlock(current)
                        if emittedCount < continuation {
                            emittedCount = min(lineBuffer.count, continuation)
                        }
                        lineAnalyzed = true
                        return
                    }
                    setCurrentBlock(current)
                }
            case .blockquote:
                if let mathOpen = detectDisplayMathOpening(lineBuffer) {
                    closeCurrentBlock()
                    if mathOpen.closesOnSameLine {
                        emitSingleLineDisplayMath(content: mathOpen.content)
                    } else {
                        openDisplayMathBlock(marker: mathOpen.marker, closing: mathOpen.closing, initialContent: mathOpen.content, indent: mathOpen.leadingIndent)
                    }
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
                if let quote = detectBlockquote(lineBuffer) {
                    ctx.linePrefixToStrip = quote.prefixLength
                    setCurrentBlock(ctx)
                    if emittedCount < quote.prefixLength {
                        emittedCount = min(lineBuffer.count, quote.prefixLength)
                    }
                } else {
                    ctx.linePrefixToStrip = 0
                    setCurrentBlock(ctx)
                }
            case .math:
                break
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
        let trimmedLine = lineBuffer.trimmingCharacters(in: .whitespaces)
        if case .fencedCode = context.kind,
           !context.fenceJustOpened,
           isClosingFence(trimmedLine, fence: context.fenceInfo) {
            emittedCount = lineBuffer.count
            setCurrentBlock(context)
            return
        }
        if case .math = context.kind,
           !context.fenceJustOpened,
           isClosingFence(trimmedLine, fence: context.fenceInfo) {
            emittedCount = lineBuffer.count
            setCurrentBlock(context)
            return
        }
        append(delta, context: &context)
        setCurrentBlock(context)
        emittedCount = lineBuffer.count
        enforceLineBufferBudget()
    }

    private mutating func finalizeLine(terminated: Bool, force: Bool) {
        if !terminated && !force { return }
        let rawLine = lineBuffer
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        let isBlank = trimmed.isEmpty

        if var ctx = currentBlock {
            switch ctx.kind {
            case .paragraph:
                if terminated && !isBlank && rawLine.hasSuffix(" ") && !rawLine.hasSuffix("  ") {
                    trimTrailingSpace(for: &ctx)
                    setCurrentBlock(ctx)
                }
                if isBlank {
                    closeCurrentBlock()
                } else if force {
                    closeCurrentBlock()
                } else if terminated {
                    if !rawLine.hasSuffix("  ") {
                        ctx.pendingSoftBreak = true
                        setCurrentBlock(ctx)
                    }
                }
            case .heading:
                closeCurrentBlock()
            case .listItem:
                if terminated && !isBlank && rawLine.hasSuffix(" ") && !rawLine.hasSuffix("  ") {
                    trimTrailingSpace(for: &ctx)
                    setCurrentBlock(ctx)
                }
                if isBlank || force {
                    closeCurrentBlock()
                } else {
                    appendToCurrent("\n")
                }
            case .blockquote:
                if terminated && !isBlank && rawLine.hasSuffix(" ") && !rawLine.hasSuffix("  ") {
                    trimTrailingSpace(for: &ctx)
                    setCurrentBlock(ctx)
                }
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
            case .math:
                if (!ctx.fenceJustOpened && isClosingFence(trimmed, fence: ctx.fenceInfo)) || force {
                    closeCurrentBlock()
                }
            case .table:
                handleTableLine(rawLine: rawLine, trimmed: trimmed, terminated: terminated, force: force)
            }
            if var updated = currentBlock {
                updated.fenceJustOpened = false
                setCurrentBlock(updated)
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
        setCurrentBlock(ctx)
    }

    private mutating func append(_ text: String, context ctx: inout BlockContext) {
        guard !text.isEmpty else { return }
        var content = text
        if ctx.linePrefixToStrip > 0 {
            let dropCount = min(ctx.linePrefixToStrip, content.count)
            let dropIndex = content.index(content.startIndex, offsetBy: dropCount)
            content = String(content[dropIndex...])
            ctx.linePrefixToStrip -= dropCount
        }
        guard !content.isEmpty else { return }
        switch ctx.kind {
        case .paragraph, .listItem, .blockquote:
            if var parser = ctx.inlineParser {
                var input = content
                if ctx.kind == .paragraph, ctx.pendingSoftBreak {
                    input = " " + input
                    ctx.pendingSoftBreak = false
                }
                var runs = parser.append(input)
                coalesceInlineRuns(&runs)
                if !runs.isEmpty {
                    if let lastIndex = events.indices.last,
                       case .blockAppendInline(let existingID, var existingRuns) = events[lastIndex],
                       existingID == ctx.id {
                        existingRuns.append(contentsOf: runs)
                        coalesceInlineRuns(&existingRuns)
                        events[lastIndex] = .blockAppendInline(id: ctx.id, runs: existingRuns)
                    } else {
                        events.append(.blockAppendInline(id: ctx.id, runs: runs))
                    }
                }
                ctx.inlineParser = parser
            }
        case .heading:
            if var parser = ctx.inlineParser {
                var emitted = ""
                var pending = ctx.headingPendingSuffix
                for character in content {
                    if character == " " || character == "#" {
                        pending.append(character)
                    } else {
                        if !pending.isEmpty {
                            emitted.append(contentsOf: pending)
                            pending.removeAll(keepingCapacity: true)
                        }
                        emitted.append(character)
                    }
                }
                ctx.headingPendingSuffix = pending
                if !emitted.isEmpty {
                    var runs = parser.append(emitted)
                    coalesceInlineRuns(&runs)
                    if !runs.isEmpty {
                        if let lastIndex = events.indices.last,
                           case .blockAppendInline(let existingID, var existingRuns) = events[lastIndex],
                           existingID == ctx.id {
                            existingRuns.append(contentsOf: runs)
                            coalesceInlineRuns(&existingRuns)
                            events[lastIndex] = .blockAppendInline(id: ctx.id, runs: existingRuns)
                        } else {
                            events.append(.blockAppendInline(id: ctx.id, runs: runs))
                        }
                    }
                }
                ctx.inlineParser = parser
            }
        case .unknown:
            ctx.literal.append(content)
        case .fencedCode:
            if let lastIndex = events.indices.last {
                if case .blockAppendFencedCode(let existingID, let existingText) = events[lastIndex], existingID == ctx.id {
                    events[lastIndex] = .blockAppendFencedCode(id: ctx.id, textChunk: existingText + content)
                } else {
                    events.append(.blockAppendFencedCode(id: ctx.id, textChunk: content))
                }
            } else {
                events.append(.blockAppendFencedCode(id: ctx.id, textChunk: content))
            }
            ctx.fenceJustOpened = false
        case .math:
            if let lastIndex = events.indices.last {
                if case .blockAppendMath(let existingID, let existingText) = events[lastIndex], existingID == ctx.id {
                    events[lastIndex] = .blockAppendMath(id: ctx.id, textChunk: existingText + content)
                } else {
                    events.append(.blockAppendMath(id: ctx.id, textChunk: content))
                }
            } else {
                events.append(.blockAppendMath(id: ctx.id, textChunk: content))
            }
            ctx.fenceJustOpened = false
        case .table:
            // table text handled at line boundaries
            break
        }
        ctx.linePrefixToStrip = 0
    }

    private func canCoalesce(_ lhs: InlineRun, _ rhs: InlineRun) -> Bool {
        lhs.style == rhs.style && lhs.linkURL == rhs.linkURL && lhs.image == rhs.image && lhs.math == rhs.math
    }

    private func coalesceInlineRuns(_ runs: inout [InlineRun]) {
        guard runs.count >= 2 else { return }
        var result: [InlineRun] = []
        result.reserveCapacity(runs.count)
        for run in runs {
            if let last = result.last, canCoalesce(last, run) {
                var merged = last
                merged.text += run.text
                result[result.count - 1] = merged
            } else {
                result.append(run)
            }
        }
        runs = result
    }

    private mutating func appendUnknownLiteral(_ text: String) {
        guard !text.isEmpty, var ctx = currentBlock, ctx.kind == .unknown else { return }
        ctx.literal.append(text)
        setCurrentBlock(ctx)
    }

    private mutating func enforceLineBufferBudget() {
        guard lineAnalyzed else { return }
        guard maxLineLookBehind > 0 else { return }
        guard lineBuffer.count > maxLineLookBehind + lookBehindSlack else { return }
        guard let ctx = currentBlock, ctx.kind != .table else { return }

        let overflow = lineBuffer.count - maxLineLookBehind
        let trimCount = min(overflow, emittedCount)
        guard trimCount > 0 else { return }

        lineBuffer.removeFirst(trimCount)
        emittedCount = max(0, emittedCount - trimCount)
    }

    private mutating func trimTrailingSpace(for context: inout BlockContext) {
        var eventIndex = events.count
        while eventIndex > 0 {
            eventIndex -= 1
            switch events[eventIndex] {
            case .blockAppendInline(let eventID, var runs) where eventID == context.id:
                var modified = false
                var runIndex = runs.count
                while runIndex > 0 {
                    runIndex -= 1
                    var run = runs[runIndex]
                    if run.text.isEmpty {
                        runs.remove(at: runIndex)
                        continue
                    }
                    if run.style.isEmpty && run.linkURL == nil && run.image == nil && run.text.hasSuffix(" ") {
                        run.text.removeLast()
                        if run.text.isEmpty {
                            runs.remove(at: runIndex)
                        } else {
                            runs[runIndex] = run
                        }
                        modified = true
                    }
                    break
                }
                if modified {
                    if runs.isEmpty {
                        events.remove(at: eventIndex)
                    } else {
                        events[eventIndex] = .blockAppendInline(id: eventID, runs: runs)
                    }
                }
                return
            default:
                continue
            }
        }
    }

    private mutating func handleTableLine(rawLine: String, trimmed: String, terminated: Bool, force: Bool) {
        guard var ctx = currentBlock, var table = ctx.tableState else {
            if force { closeCurrentBlock() }
            return
        }

        switch table.stage {
        case .header:
            table.bufferedLines.append(rawLine)
            table.stage = .separatorPending
        case .separatorPending:
            table.bufferedLines.append(rawLine)
            if let alignments = parseAlignment(trimmed) {
                table.alignments = alignments
                events.append(.tableHeaderConfirmed(id: ctx.id, alignments: alignments))
                table.stage = .rows
                table.bufferedLines.removeAll(keepingCapacity: true)
            } else {
                degradeTableCandidate(context: &ctx, table: table, terminated: terminated || force)
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
        setCurrentBlock(ctx)

        if force, table.stage != .rows {
            degradeTableCandidate(context: &ctx, table: table, terminated: true)
        } else if force {
            closeCurrentBlock()
        }
    }

    private mutating func degradeTableCandidate(context ctx: inout BlockContext, table: TableState, terminated: Bool) {
        let startIndex = min(ctx.eventStartIndex, events.count)
        if startIndex < events.count {
            events.removeSubrange(startIndex..<events.count)
        }

        let text: String = {
            guard !table.bufferedLines.isEmpty else { return "" }
            var joined = table.bufferedLines.joined(separator: "\n")
            if terminated {
                joined.append("\n")
            }
            return joined
        }()

        let fallbackContext = BlockContext(
            id: ctx.id,
            kind: .unknown,
            inlineParser: nil,
            tableState: nil,
            fenceInfo: nil,
            literal: "",
            fenceJustOpened: false,
            linePrefixToStrip: 0,
            headingPendingSuffix: "",
            eventStartIndex: ctx.eventStartIndex,
            listIndent: 0
        )

        setCurrentBlock(fallbackContext)
        events.append(.blockStart(id: fallbackContext.id, kind: .unknown))
        appendUnknownLiteral(text)
        closeCurrentBlock()
    }

    private mutating func closeCurrentBlock() {
        guard let ctx = currentBlock else { return }
        if var parser = ctx.inlineParser {
            var runs = parser.finish()
            coalesceInlineRuns(&runs)
            if !runs.isEmpty {
                if let lastIndex = events.indices.last,
                   case .blockAppendInline(let existingID, var existingRuns) = events[lastIndex],
                   existingID == ctx.id {
                    existingRuns.append(contentsOf: runs)
                    coalesceInlineRuns(&existingRuns)
                    events[lastIndex] = .blockAppendInline(id: existingID, runs: existingRuns)
                } else {
                    events.append(.blockAppendInline(id: ctx.id, runs: runs))
                }
            }
        }
        if !ctx.literal.isEmpty {
            var literalRuns = [InlineRun(text: ctx.literal)]
            coalesceInlineRuns(&literalRuns)
            events.append(.blockAppendInline(id: ctx.id, runs: literalRuns))
        }
        events.append(.blockEnd(id: ctx.id))
        _ = popBlock()
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
            linePrefixToStrip: prefixToStrip,
            headingPendingSuffix: "",
            eventStartIndex: events.count,
            listIndent: 0
        )
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: kind))
        pushBlock(context)
    }

    private mutating func openListItem(_ info: ListInfo) {
        let context = BlockContext(
            id: nextID,
            kind: .listItem(ordered: info.ordered, index: info.index, task: info.task),
            inlineParser: InlineParser(),
            tableState: nil,
            fenceInfo: nil,
            literal: "",
            fenceJustOpened: false,
            linePrefixToStrip: info.prefixLength,
            headingPendingSuffix: "",
            eventStartIndex: events.count,
            listIndent: info.indent
        )
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: .listItem(ordered: info.ordered, index: info.index, task: info.task)))
        pushBlock(context)
        if !info.indentText.isEmpty {
            appendToCurrent(info.indentText)
            if var updated = currentBlock {
                updated.linePrefixToStrip = info.prefixLength
                setCurrentBlock(updated)
            }
        }
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
            linePrefixToStrip: 0,
            headingPendingSuffix: "",
            eventStartIndex: events.count,
            listIndent: 0
        )
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: .unknown))
        pushBlock(context)
    }

    private mutating func openFencedCode(_ fence: FenceInfo) {
        let isMath = MarkdownMath.isMathLanguage(fence.language)
        let kind: BlockKind = isMath ? .math(display: true) : .fencedCode(language: fence.language)
        var context = BlockContext(
            id: nextID,
            kind: kind,
            inlineParser: nil,
            tableState: nil,
            fenceInfo: fence,
            literal: "",
            fenceJustOpened: true,
            linePrefixToStrip: 0,
            headingPendingSuffix: "",
            eventStartIndex: events.count,
            listIndent: 0
        )
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: kind))
        pushBlock(context)
        if isMath {
            context = currentBlock ?? context
            context.fenceJustOpened = true
            setCurrentBlock(context)
        }
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
            linePrefixToStrip: 0,
            headingPendingSuffix: "",
            eventStartIndex: events.count,
            listIndent: 0
        )
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: .table))
        let headerCells = splitCells(line).map { InlineRun(text: $0) }
        events.append(.tableHeaderCandidate(id: context.id, cells: headerCells))
        context.tableState = TableState(stage: .header, alignments: [], bufferedLines: [])
        pushBlock(context)
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
        return FenceInfo(marker: marker, language: info.isEmpty ? nil : info, closingMarker: marker)
    }

    /// Detect a display-math opener at the start of the (optionally indented) line.
    /// Supported markers:
    ///   - $$ ... $$
    ///   - \[ ... \]
    /// NOTE: Inline math with \( ... \) is intentionally NOT handled here; that belongs to the inline parser.
    private func detectDisplayMathOpening(_ line: String) -> DisplayMathOpening? {
        guard !line.isEmpty else { return nil }

        var index = line.startIndex
        var indent = 0
        // Allow up to 3 leading spaces before the marker, per commonmark/KaTeX conventions
        while index < line.endIndex && indent < 4 {
            let ch = line[index]
            if ch == " " { indent += 1; index = line.index(after: index) } else { break }
        }
        guard indent <= 3, index < line.endIndex else { return nil }

        // Helper to build a DisplayMathOpening given an opening/closing marker pair
        func makeOpening(open: String, close: String) -> DisplayMathOpening? {
            guard line[index...].hasPrefix(open) else { return nil }
            let contentStart = line.index(index, offsetBy: open.count)
            guard contentStart <= line.endIndex else { return nil }
            let remainder = line[contentStart...]
            if remainder.isEmpty {
                return DisplayMathOpening(marker: open, closing: close, content: "", closesOnSameLine: false, leadingIndent: indent)
            }
            if let closingRange = remainder.range(of: close) {
                // Only allow trailing whitespace after the closing marker
                let afterClose = remainder[closingRange.upperBound...].trimmingCharacters(in: .whitespaces)
                guard afterClose.isEmpty else { return nil }
                let inner = remainder[..<closingRange.lowerBound]
                return DisplayMathOpening(marker: open, closing: close, content: String(inner), closesOnSameLine: true, leadingIndent: indent)
            } else {
                return DisplayMathOpening(marker: open, closing: close, content: String(remainder), closesOnSameLine: false, leadingIndent: indent)
            }
        }

        // Try $$...$$ first, then \[...\]
        if let open = makeOpening(open: "$$", close: "$$") { return open }
        if let open = makeOpening(open: "\\[", close: "\\]") { return open }

        return nil
    }

    private mutating func emitSingleLineDisplayMath(content: String) {
        let blockID = nextID
        nextID &+= 1
        let kind: BlockKind = .math(display: true)
        events.append(.blockStart(id: blockID, kind: kind))
        if !content.isEmpty {
            events.append(.blockAppendMath(id: blockID, textChunk: content))
        }
        events.append(.blockEnd(id: blockID))
    }

    private mutating func openDisplayMathBlock(marker: String, closing: String, initialContent: String, indent: Int) {
        let context = BlockContext(
            id: nextID,
            kind: .math(display: true),
            inlineParser: nil,
            tableState: nil,
            fenceInfo: FenceInfo(marker: marker, language: "math", closingMarker: closing),
            literal: "",
            fenceJustOpened: true,
            linePrefixToStrip: indent,
            headingPendingSuffix: "",
            eventStartIndex: events.count,
            listIndent: 0
        )
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: .math(display: true)))
        pushBlock(context)
        if !initialContent.isEmpty {
            appendToCurrent(initialContent)
        }
    }

    private func isClosingFence(_ line: String, fence: FenceInfo?) -> Bool {
        guard let fence = fence else { return false }
        let marker = fence.closingMarker ?? fence.marker
        guard line.hasPrefix(marker) else { return false }
        let remainder = line.dropFirst(marker.count)
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
        var index = line.startIndex
        var indent = 0
        while index < line.endIndex {
            let character = line[index]
            if character == " " {
                indent += 1
            } else if character == "\t" {
                indent += 4
            } else {
                break
            }
            index = line.index(after: index)
        }

        guard index < line.endIndex else { return nil }
        let indentText = String(line[line.startIndex..<index])

        var markerLength = 0
        var ordered = false
        var listIndex: Int? = nil

        if line[index...].hasPrefix("- ") || line[index...].hasPrefix("* ") || line[index...].hasPrefix("+ ") {
            markerLength = 2
        } else {
            var numberEnd = index
            var digits = 0
            while numberEnd < line.endIndex,
                  let scalar = line[numberEnd].unicodeScalars.first,
                  CharacterSet.decimalDigits.contains(scalar) {
                digits += 1
                numberEnd = line.index(after: numberEnd)
            }
            if digits > 0, numberEnd < line.endIndex, line[numberEnd] == "." {
                let afterDot = line.index(after: numberEnd)
                if afterDot < line.endIndex, line[afterDot] == " " {
                    let numberPart = line[index..<numberEnd]
                    if let number = Int(numberPart) {
                        ordered = true
                        listIndex = number
                        markerLength = digits + 2 // digits + ". "
                    }
                }
            }
        }

        guard markerLength > 0 else { return nil }

        let markerEnd = line.index(index, offsetBy: markerLength)
        var task: TaskListState? = nil
        var taskMarkerLength = 0
        if markerEnd < line.endIndex, line[markerEnd] == "[" {
            let statusIndex = line.index(after: markerEnd)
            if statusIndex < line.endIndex {
                let closingIndex = line.index(after: statusIndex)
                if closingIndex < line.endIndex, line[closingIndex] == "]" {
                    let postClosing = line.index(after: closingIndex)
                    if postClosing < line.endIndex, line[postClosing] == " " {
                        let statusChar = line[statusIndex]
                        if statusChar == " " || statusChar == "x" || statusChar == "X" {
                            task = TaskListState(checked: statusChar == "x" || statusChar == "X")
                            taskMarkerLength = line.distance(from: markerEnd, to: line.index(after: postClosing))
                        }
                    }
                }
            }
        }

        return ListInfo(
            ordered: ordered,
            index: listIndex,
            indent: indent,
            markerLength: markerLength,
            indentText: indentText,
            task: task,
            taskMarkerLength: taskMarkerLength
        )
    }

    private func detectBlockquote(_ line: String) -> BlockquoteInfo? {
        var prefixLength = 0
        var index = line.startIndex
        var sawMarker = false
        var consumedTrailingSpace = false

        while index < line.endIndex {
            let character = line[index]
            if character == " " || character == "\t" {
                if sawMarker {
                    if consumedTrailingSpace {
                        break
                    }
                    consumedTrailingSpace = true
                    prefixLength += 1
                    index = line.index(after: index)
                } else {
                    prefixLength += 1
                    index = line.index(after: index)
                }
            } else if character == ">" {
                sawMarker = true
                consumedTrailingSpace = false
                prefixLength += 1
                index = line.index(after: index)
            } else {
                break
            }
        }

        guard sawMarker else { return nil }
        return BlockquoteInfo(prefixLength: prefixLength)
    }

    private func listContinuationPrefixLength(_ line: String, currentIndent: Int) -> Int {
        var count = 0
        for character in line {
            if character == " " {
                count += 1
            } else if character == "\t" {
                count += 4
            } else {
                break
            }
        }
        let relative = count - currentIndent
        return relative >= 2 ? count : 0
    }

    private func shouldStartNewListItem(currentContext: BlockContext, list: ListInfo, emittedCount: Int) -> Bool {
        guard case .listItem(let currentOrdered, let currentIndex, let currentTask) = currentContext.kind else { return true }
        if emittedCount > list.prefixLength {
            if list.ordered == currentOrdered,
               list.index == currentIndex,
               list.task == currentTask {
                return false
            }
        }
        if list.ordered != currentOrdered {
            return true
        }
        if list.ordered {
            return list.index != currentIndex || list.task != currentTask
        }
        // Unordered list items reuse the same marker; treat as new item when we hit the marker again unless
        // the marker is a continuation line and task metadata matches the current item.
        if list.task != currentTask {
            return true
        }
        return emittedCount <= list.prefixLength
    }

    private func detectTableCandidate(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        guard trimmed.first == "|" else { return false }
        let pipeCount = trimmed.filter { $0 == "|" }.count
        return pipeCount >= 2
    }

    private func detectHorizontalRule(_ line: String, indent: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard let first = stripped.first, ["-", "*", "_"].contains(first) else { return false }
        guard stripped.allSatisfy({ $0 == first }) else { return false }
        let leadingSpaces = line.prefix { $0 == " " }.count
        if indent > 0 {
            return leadingSpaces >= indent
        }
        return true
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
        for raw in cells {
            var s = raw.trimmingCharacters(in: .whitespaces)

            // Only colons and hyphens are allowed
            guard s.allSatisfy({ $0 == ":" || $0 == "-" }) else { return nil }

            let leftColon  = s.first == ":"
            let rightColon = s.last  == ":"

            if leftColon { s.removeFirst() }
            if rightColon, !s.isEmpty { s.removeLast() }

            // Must be a run of ≥ 3 hyphens (no other chars)
            guard !s.isEmpty, s.allSatisfy({ $0 == "-" }), s.count >= 3 else { return nil }

            // Map to alignment
            if leftColon && rightColon { result.append(.center) }
            else if leftColon         { result.append(.left) }
            else if rightColon        { result.append(.right) }
            else                      { result.append(.left) } // default
        }
        return result
    }

    private func parseRow(_ line: String) -> [[InlineRun]] {
        splitCells(line).map { InlineParser.parseAll($0) }
    }

    private func snapshotOpenBlocks() -> [OpenBlockState] {
        var states: [OpenBlockState] = []
        states.reserveCapacity(contextStack.count)
        for (index, context) in contextStack.enumerated() {
            let parentID = index > 0 ? contextStack[index - 1].id : nil
            states.append(OpenBlockState(id: context.id, kind: context.kind, parentID: parentID, depth: index))
        }
        return states
    }

    private func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
