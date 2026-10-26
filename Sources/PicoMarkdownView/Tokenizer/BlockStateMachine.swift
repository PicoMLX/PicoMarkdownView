import Foundation

struct StreamingParser {
    static let defaultMaxLookBehind = 1024

    private let maxLineLookBehind: Int
    private let lookBehindSlack: Int
    private let tagPrefixes: Set<TagPrefix>

    init(maxLookBehind: Int = StreamingParser.defaultMaxLookBehind,
         tagPrefixes: Set<TagPrefix> = TagPrefix.defaults) {
        let capped = max(0, maxLookBehind)
        self.maxLineLookBehind = capped
        if capped == 0 {
            self.lookBehindSlack = 0
        } else {
            self.lookBehindSlack = max(32, capped / 2)
        }
        self.tagPrefixes = tagPrefixes
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
        /// The line ended with an odd run of backslashes: a hard break if
        /// another line follows, a literal backslash if the block ends.
        var pendingHardBreak: Bool = false
        var pendingSameLineClose: Bool = false
        var preventNextCoalesce: Bool = false
        var sawBlankInSubContext: Bool = false
        /// 1-based nesting level for `.blockquote` contexts (`>` = 1,
        /// `>>` = 2, …); 0 for every other kind. The blockquote analogue of
        /// `listIndent`.
        var blockquoteLevel: Int = 0
        /// A blockquote that has opened a child block (heading, fence, …).
        /// Later plain text goes into a paragraph child so source order is
        /// kept, instead of being appended to the quote's own inline runs.
        var hasBlockChildren: Bool = false
        /// Non-whitespace inline text has been appended: for a blockquote
        /// this means its own text acts as an open paragraph.
        var hasInlineContent: Bool = false
        /// A heading has received content other than a possible closing
        /// sequence; decides whether trailing `#`s alone close an empty heading.
        var headingHasContent: Bool = false
        /// Escape state of a heading's text at a chunk boundary: the last
        /// emitted character was a backslash, or a `#` run that a backslash
        /// started as content is still running.
        var headingAfterBackslash: Bool = false
        var headingEscapedRun: Bool = false
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
        var isIndented: Bool
        /// Spaces before the opening fence; up to that many are removed from
        /// each content line (CommonMark).
        var leadingIndent: Int

        init(marker: String, language: String?, closingMarker: String? = nil, isIndented: Bool = false, leadingIndent: Int = 0) {
            self.marker = marker
            self.language = language
            self.closingMarker = closingMarker
            self.isIndented = isIndented
            self.leadingIndent = leadingIndent
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
        /// Leading spaces before the `#` run (at most three).
        var indent: Int
    }

    private struct ListInfo {
        var ordered: Bool
        var index: Int?
        var indent: Int
        var markerLength: Int
        var indentText: String
        var task: TaskListState?
        var taskMarkerLength: Int

        /// Source characters to strip before the item's text. `indent` counts
        /// columns (a tab is four) and is only for nesting comparisons.
        var prefixLength: Int { indentText.count + markerLength + taskMarkerLength }
    }

    private struct BlockquoteInfo {
        var prefixLength: Int
        /// Number of `>` markers in the prefix — the requested quote depth.
        var markerCount: Int
    }

    private var nextID: BlockID = 1
    private var contextStack: [BlockContext] = []
    private let linkReferenceStore = LinkReferenceStore()
    private let footnoteRegistry = FootnoteRegistry()
    private var lineIsLinkDefinition: Bool = false

    private var currentBlock: BlockContext? {
        contextStack.last
    }

    private mutating func pushBlock(_ context: BlockContext) {
        // Whatever path opens a block inside a quote, the quote now has
        // children, so later plain text becomes a paragraph child.
        if let parent = contextStack.indices.last, contextStack[parent].kind == .blockquote {
            contextStack[parent].hasBlockChildren = true
        }
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
    /// Where the last delta for `emittedLineBlockID` ended, in UTF-8 bytes.
    /// `emittedCount` is in Characters, and a scalar that arrives in a later
    /// chunk can extend the last emitted grapheme without adding one, so the
    /// byte boundary is what decides where the next delta starts.
    private var emittedLineUTF8Offset: Int?
    private var emittedLineBlockID: BlockID?
    private var lineAnalyzed: Bool = false
    /// Characters the look-behind budget has removed from the front of the
    /// current line; nonzero means the line's structure is settled.
    private var lineBufferTrimmed: Int = 0
    /// Set when the current line can only be classified once it is complete
    /// (`$$`, `\[`, `|`, `:::` prefixes): until the newline arrives, further
    /// characters are buffered without re-analysis, so a long streamed line
    /// costs O(chunk) per feed rather than O(line).
    private var lineDeferredUntilComplete = false
    /// Blank lines inside an indented code block are held until a code line
    /// follows them, since trailing blank lines are not part of the block
    /// (CommonMark); dropped when the block closes. Kept here, not in the
    /// block context, so appending never copies the accumulated text.
    private var pendingCodeBlankLines = ""
    private var pendingCodeBlankLinesBlock: BlockID?
    /// A child block opener ran on the current line (`openQuotedChild`).
    private var lineOpenedChild = false
    /// Some of the current line's content reached a block. Consuming a list
    /// item's indentation alone does not count, so a later opener on the
    /// same line is still allowed.
    private var lineEmittedContent = false
    /// Characters at the start of `lineBuffer` that are the enclosing
    /// blockquote's `>` markers (with their optional space). Resolved once
    /// per line by `analyzeQuotedLine`; everything after it is the line as
    /// the quote's children see it.
    private var lineQuotePrefix: Int = 0
    /// Set when the line became a horizontal rule, which pushes no context:
    /// the enclosing block must not treat the line as its own text.
    private var lineConsumedByRule = false
    private var events: [BlockEvent] = []

    /// The current line without its blockquote prefix.
    private var lineContent: Substring {
        lineQuotePrefix > 0 ? lineBuffer.dropFirst(lineQuotePrefix) : lineBuffer[...]
    }

    mutating func feed(_ chunk: String) -> ChunkResult {
        closePendingSameLineBlocks()
        process(normalizeLineEndings(chunk), isFinal: false)
        flushPendingInlineTailForOpenBlocks()
        let result = ChunkResult(events: events, openBlocks: snapshotOpenBlocks())
        events.removeAll(keepingCapacity: true)
        return result
    }

    mutating func finish() -> ChunkResult {
        closePendingSameLineBlocks()
        process("", isFinal: true)
        flushPendingInlineTailForOpenBlocks()
        let result = ChunkResult(events: events, openBlocks: snapshotOpenBlocks())
        events.removeAll(keepingCapacity: true)
        return result
    }

    private mutating func process(_ text: String, isFinal: Bool) {
        for character in text {
            if character == "\n" {
                lineDeferredUntilComplete = false
                lineAnalyzed = false   // force re-analysis now that line is complete
                analyzeLineIfNeeded(isLineComplete: true)
                let includeNewline = shouldIncludeTerminatingNewline()
                appendDeltaIfNeeded(includeTerminatingNewline: includeNewline, isLineComplete: true)
                finalizeLine(terminated: true, force: false)
            } else {
                lineBuffer.append(character)
                if !lineDeferredUntilComplete { lineAnalyzed = false }
            }
        }

        analyzeLineIfNeeded(isLineComplete: false)
        appendDeltaIfNeeded()

        if isFinal {
            lineDeferredUntilComplete = false
            lineAnalyzed = false
            analyzeLineIfNeeded(isLineComplete: true)
            appendDeltaIfNeeded(isLineComplete: true)
            finalizeLine(terminated: true, force: true)
            // Children of nested quotes add contexts, so the end of input
            // drains the whole stack rather than one block.
            while currentBlock != nil {
                closeCurrentBlock()
            }
        }
    }

    private func shouldIncludeTerminatingNewline() -> Bool {
        guard let ctx = currentBlock else { return false }
        switch ctx.kind {
        case .paragraph, .heading, .listItem, .blockquote, .footnoteDefinition:
            return lineBuffer.hasSuffix("  ")
        case .fencedCode, .math:
            // An unmarked blank line inside a quote ends the quote and its
            // code; it is not a blank code line.
            if lineQuotePrefix == 0, contextStack.contains(where: { $0.kind == .blockquote }),
               lineBuffer.allSatisfy({ $0 == " " || $0 == "\t" }) {
                return false
            }
            return !ctx.fenceJustOpened
        case .horizontalRule:
            return false
        case .unknown:
            return !lineBuffer.isEmpty
        case .table:
            return false
        }
    }

    private mutating func analyzeLineIfNeeded(isLineComplete: Bool) {
        if lineAnalyzed { return }

        let trimmed = lineBuffer.trimmingCharacters(in: .whitespaces)

        lineIsLinkDefinition = false
        // An unmarked line inside a quote is the quote's business first: it
        // ends quoted code (and is then a definition at the outer level) or
        // continues a quoted paragraph, which a definition cannot interrupt.
        let unmarkedInsideQuote = contextStack.contains(where: { $0.kind == .blockquote }) && detectBlockquote(lineBuffer) == nil
        if isLineComplete, !unmarkedInsideQuote, let linkDefinition = detectLinkDefinition(lineBuffer) {
            linkReferenceStore.define(label: linkDefinition.label, url: linkDefinition.url, title: linkDefinition.title)
            lineIsLinkDefinition = true
            if let ctx = currentBlock, case .paragraph = ctx.kind {
                closeCurrentBlock()
            }
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return
        }

        if trimmed.isEmpty {
            if var ctx = currentBlock, case .listItem = ctx.kind {
                ctx.linePrefixToStrip = 0
                setCurrentBlock(ctx)
            }
            // A blank line inside indented code loses up to four columns of
            // indentation like any code line; the rest is content.
            if let ctx = currentBlock, isIndentedCodeBlock(ctx) {
                let blankPrefix = min(4, lineBuffer.hasPrefix("\t") ? 1 : lineBuffer.prefix { $0 == " " }.count)
                if emittedCount < blankPrefix {
                    emittedCount = min(lineBuffer.count, blankPrefix)
                }
            }
            lineAnalyzed = true
            return
        }

        if contextStack.contains(where: { $0.kind == .blockquote }),
           analyzeQuotedLine(isLineComplete: isLineComplete) {
            return
        }

        if contextStack.isEmpty {
            // `[^a]:` with nothing after it yet may still gain its space; the
            // prefix is published with the block, so wait one character.
            if let footnote = detectFootnoteDefinition(lineBuffer), isLineComplete || !lineBuffer.hasSuffix(":") {
                let index = footnoteRegistry.index(for: footnote.id)
                openInlineBlock(kind: .footnoteDefinition(id: footnote.id, index: index),
                                prefixToStrip: footnote.prefixLength)
                emittedCount = min(lineBuffer.count, footnote.prefixLength)
                lineAnalyzed = true
                return
            }
            // `$$x$$` on one line is display math, but `$$x$$y` is a
            // paragraph with inline math: the opener waits for the line to
            // complete (its text is deferred, never emitted provisionally).
            if isLineComplete, let mathOpen = detectDisplayMathOpening(lineBuffer) {
                let closeAfterLine = mathOpen.closesOnSameLine
                openDisplayMathBlock(marker: mathOpen.marker,
                                     closing: mathOpen.closing,
                                     initialContent: mathOpen.content,
                                     indent: mathOpen.leadingIndent,
                                     closeAfterCurrentLine: closeAfterLine)
                emittedCount = lineBuffer.count
                lineAnalyzed = true
                return
            }
            if isLineComplete, let fence = detectFenceOpening(lineBuffer) {
                openFencedCode(fence)
                emittedCount = lineBuffer.count
                lineAnalyzed = true
                return
            }
            if let prefixLength = detectIndentedCodePrefix(lineBuffer) {
                openIndentedCode(prefixLength: prefixLength)
                emittedCount = min(lineBuffer.count, prefixLength)
                lineAnalyzed = true
                return
            }

            if let heading = detectHeading(lineBuffer, isLineComplete: isLineComplete) {
                openInlineBlock(kind: .heading(level: heading.level), prefixToStrip: heading.prefixLength)
                emittedCount = min(lineBuffer.count, heading.prefixLength)
                lineAnalyzed = true
                return
            }

            // `* * *` is a rule, not a list item (CommonMark); only a
            // complete line can tell, so a partial `* ` or `* *` waits.
            if isLineComplete, detectHorizontalRule(lineBuffer, indent: 0) {
                emitHorizontalRuleBlock()
                return
            }
            if !isLineComplete, isPotentialHorizontalRule(lineBuffer) {
                lineAnalyzed = true
                return
            }

            if let list = detectList(lineBuffer, isLineComplete: isLineComplete) {
                openListItem(list)
                emittedCount = min(lineBuffer.count, list.prefixLength)
                lineAnalyzed = true
                return
            }

            if let quote = detectBlockquote(lineBuffer) {
                openBlockquotes(from: 0, to: quote.markerCount, prefixLength: quote.prefixLength)
                // The quote is open; its first line is analyzed like any other
                // quoted line so a heading or fence after the marker becomes
                // a child block.
                lineAnalyzed = false
                analyzeLineIfNeeded(isLineComplete: isLineComplete)
                return
            }

            if isLineComplete, detectTableCandidate(lineBuffer) {
                openTable(lineBuffer)
                emittedCount = lineBuffer.count
                lineAnalyzed = true
                return
            }

            if isLineComplete, detectHorizontalRule(lineBuffer, indent: 0) {
                emitHorizontalRuleBlock()
                return
            }

            if isLineComplete, lineBuffer.hasPrefix(":::") {
                openUnknown()
                appendUnknownLiteral(lineBuffer)
                emittedCount = lineBuffer.count
                lineAnalyzed = true
                return
            }

            if !isLineComplete, shouldDeferParagraphFallback(for: lineBuffer) {
                lineDeferredUntilComplete = isDeferredUntilLineEnd(lineBuffer)
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
        case .paragraph, .footnoteDefinition:
                if isLineComplete, let mathOpen = detectDisplayMathOpening(lineBuffer) {
                    closeCurrentBlock()
                    let closeAfterLine = mathOpen.closesOnSameLine
                    openDisplayMathBlock(marker: mathOpen.marker,
                                         closing: mathOpen.closing,
                                         initialContent: mathOpen.content,
                                         indent: mathOpen.leadingIndent,
                                         closeAfterCurrentLine: closeAfterLine)
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
                if isLineComplete, let fence = detectFenceOpening(lineBuffer) {
                    closeCurrentBlock()
                    openFencedCode(fence)
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
                if let heading = detectHeading(lineBuffer, isLineComplete: isLineComplete) {
                    closeCurrentBlock()
                    openInlineBlock(kind: .heading(level: heading.level), prefixToStrip: heading.prefixLength)
                    emittedCount = min(lineBuffer.count, heading.prefixLength)
                    lineAnalyzed = true
                    return
                }
                if isLineComplete, detectHorizontalRule(lineBuffer, indent: 0) {
                    closeCurrentBlock()
                    emitHorizontalRuleBlock()
                    return
                }
                if !isLineComplete, isPotentialHorizontalRule(lineBuffer) {
                    lineAnalyzed = true
                    return
                }
                if let list = detectList(lineBuffer, isLineComplete: isLineComplete),
                   listCanInterruptParagraph(list, line: lineBuffer) {
                    closeCurrentBlock()
                    openListItem(list)
                    emittedCount = min(lineBuffer.count, list.prefixLength)
                    lineAnalyzed = true
                    return
                }
                if let quote = detectBlockquote(lineBuffer) {
                    closeCurrentBlock()
                    openBlockquotes(from: 0, to: quote.markerCount, prefixLength: quote.prefixLength)
                    lineAnalyzed = false
                    analyzeLineIfNeeded(isLineComplete: isLineComplete)
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
                    closeCurrentBlock()
                    emitHorizontalRuleBlock()
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
                analyzeListItemLine(isLineComplete: isLineComplete)
                return
            case .blockquote:
                // Every line inside a quote is handled by `analyzeQuotedLine`.
                break
            case .math:
                break
            case .fencedCode:
                if isIndentedCodeBlock(ctx) {
                    if let prefixLength = detectIndentedCodePrefix(lineBuffer) {
                        ctx.linePrefixToStrip = prefixLength
                        setCurrentBlock(ctx)
                        if emittedCount < prefixLength {
                            emittedCount = min(lineBuffer.count, prefixLength)
                        }
                        lineAnalyzed = true
                        return
                    }
                    if !trimmed.isEmpty {
                        closeCurrentBlock()
                        analyzeLineIfNeeded(isLineComplete: isLineComplete)
                        return
                    }
                }
                break
            case .horizontalRule:
                break
            case .table:
                // GFM: a table ends at a blank line or the start of another
                // block. Only the line in hand is reconsidered; emitted rows
                // stay as they are.
                if isLineComplete, ctx.tableState?.stage == .rows,
                   startsBlock(lineContent, isLineComplete: true, interruptingParagraph: false) || detectBlockquote(String(lineContent)) != nil,
                   !detectTableCandidate(String(lineContent)) {
                    closeCurrentBlock()
                    // Table lines are consumed whole as they stream; the
                    // line is now someone else's and is analyzed afresh.
                    emittedCount = 0
                    lineAnalyzed = false
                    analyzeLineIfNeeded(isLineComplete: true)
                    return
                }
            case .unknown:
                break
            }
        }

        lineAnalyzed = true
    }

    /// The list-item branch of `analyzeLineIfNeeded`, on the line's content
    /// after any blockquote prefix, so lists inside quotes behave like lists
    /// at the top level. Emitted counts stay in `lineBuffer` coordinates.
    private mutating func analyzeListItemLine(isLineComplete: Bool) {
        let line = String(lineContent)
        let base = lineQuotePrefix
        func consumed(_ count: Int) -> Int { min(lineBuffer.count, base + count) }

        if base > 0, !isLineComplete, listMarkerIsPending(line) {
            lineAnalyzed = true
            return
        }
        if isLineComplete, let mathOpen = detectDisplayMathOpening(line) {
            closeCurrentBlock()
            openDisplayMathBlock(marker: mathOpen.marker,
                                 closing: mathOpen.closing,
                                 initialContent: mathOpen.content,
                                 indent: mathOpen.leadingIndent,
                                 closeAfterCurrentLine: mathOpen.closesOnSameLine)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return
        }
        // A heading at or before the item's marker column breaks out of all
        // open list contexts; at top level one indented past the marker is
        // the item's own content. Inside a quote, an indented heading ends
        // the quoted list and joins the quote (see `quotedListChildren`).
        if let heading = detectHeading(line, isLineComplete: isLineComplete), base > 0 || heading.indent <= (currentBlock?.listIndent ?? 0) {
            closeCurrentBlock()
            closeListContexts(deeperThan: -1)
            openInlineBlock(kind: .heading(level: heading.level), prefixToStrip: base + heading.prefixLength)
            emittedCount = consumed(heading.prefixLength)
            lineAnalyzed = true
            return
        }
        // A fenced code block at column 0 breaks out of all open list contexts.
        if isLineComplete, let fence = detectFenceOpening(line) {
            closeCurrentBlock()
            closeListContexts(deeperThan: -1)
            openFencedCode(fence)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return
        }
        // A thematic break outranks a list item (CommonMark): `* * *` after
        // `- a` is a rule, not another item, and a partial `* ` waits.
        if isLineComplete, detectHorizontalRule(line, indent: 0) {
            // The rule ends the items at or past its own indentation; an
            // enclosing item whose marker sits further left stays open, so
            // `- parent\n  - child\n  _ _ _` keeps the parent.
            let indent = line.prefix(while: { $0 == " " }).count
            closeCurrentBlock()
            closeListContexts(deeperThan: indent - 1)
            emitHorizontalRuleBlock()
            return
        }
        if !isLineComplete, isPotentialHorizontalRule(line) {
            lineAnalyzed = true
            return
        }
        if let list = detectList(line, isLineComplete: isLineComplete) {
            closeListContexts(deeperThan: list.indent)

            if let current = currentBlock, case .listItem = current.kind {
                if list.indent > current.listIndent {
                    openListItem(list)
                    emittedCount = consumed(list.prefixLength)
                } else if list.indent == current.listIndent {
                    if shouldStartNewListItem(currentContext: current, list: list, emittedCount: max(0, emittedCount - base)) {
                        closeCurrentBlock()
                        openListItem(list)
                        emittedCount = consumed(list.prefixLength)
                    } else {
                        var updated = current
                        updated.linePrefixToStrip = list.prefixLength
                        setCurrentBlock(updated)
                        if emittedCount < base + list.prefixLength {
                            emittedCount = consumed(list.prefixLength)
                        }
                    }
                } else {
                    closeCurrentBlock()
                    openListItem(list)
                    emittedCount = consumed(list.prefixLength)
                }
            } else {
                openListItem(list)
                emittedCount = consumed(list.prefixLength)
            }

            lineAnalyzed = true
            return
        }

        if var current = currentBlock, case .listItem = current.kind {
            let continuation = listContinuationPrefixLength(line, currentIndent: current.listIndent)
            if isLineComplete, detectTableCandidate(line) {
                closeCurrentBlock()
                openTable(line)
                emittedCount = lineBuffer.count
                lineAnalyzed = true
                return
            }
            if isLineComplete, detectHorizontalRule(line, indent: current.listIndent) {
                closeCurrentBlock()
                closeListContexts(deeperThan: current.listIndent - 1)
                emitHorizontalRuleBlock()
                return
            }
            if continuation > 0 {
                current.linePrefixToStrip = continuation
                current.sawBlankInSubContext = false
                setCurrentBlock(current)
                if emittedCount < base + continuation {
                    emittedCount = consumed(continuation)
                }
                lineAnalyzed = true
                return
            }
            // Non-indented text that is not a list marker, heading,
            // fence, etc.  If a blank line previously closed a child
            // context, this text starts a new paragraph outside the
            // list.  Without a prior blank line, it is a lazy
            // continuation of the current list item.
            if current.sawBlankInSubContext {
                closeCurrentBlock()
                closeListContexts(deeperThan: -1)
                openInlineBlock(kind: .paragraph)
                emittedCount = min(lineBuffer.count, base)
                lineAnalyzed = true
                return
            }
            setCurrentBlock(current)
        }
        lineAnalyzed = true
    }

    // MARK: Blockquote containers

    /// Handles a line while a blockquote is open: the `>` prefix is resolved
    /// once, and the remainder is treated like a line of a normal document
    /// whose blocks become children of the quote (CommonMark container
    /// prefixes). Returns `false` when the per-kind handling below should
    /// still run on the stripped line (verbatim, math and table children).
    private mutating func analyzeQuotedLine(isLineComplete: Bool) -> Bool {
        guard let quoteIndex = contextStack.lastIndex(where: { $0.kind == .blockquote }),
              let top = currentBlock else { return false }
        // Once the look-behind budget has trimmed the front of this line,
        // its container prefix was resolved and emitted; what remains is
        // content of the block that is open, not a new line to classify.
        if lineBufferTrimmed > 0 {
            lineAnalyzed = true
            return true
        }
        let activeLevel = contextStack[quoteIndex].blockquoteLevel
        let topIsQuote = contextStack.count - 1 == quoteIndex
        let topIsVerbatim = top.kind.isVerbatim || top.kind == .table || top.kind == .unknown

        // Inside quoted code or math, further `>` markers are content, so
        // only the enclosing quote's own markers are stripped.
        guard let quote = detectBlockquote(lineBuffer, maxMarkers: topIsVerbatim ? activeLevel : nil) else {
            // A partial line of only whitespace may still grow a marker.
            if !isLineComplete, lineBuffer.allSatisfy({ $0 == " " || $0 == "\t" }) {
                lineAnalyzed = true
                return true
            }
            lineQuotePrefix = 0
            // Quoted code, math and tables cannot continue without the
            // marker: the quote ends as soon as the line is known not to
            // carry one, before any of the line could reach the verbatim
            // block.
            if topIsVerbatim {
                closeBlockquoteContexts()
                lineAnalyzed = false
                analyzeLineIfNeeded(isLineComplete: isLineComplete)
                return true
            }
            // An unmarked line continues a quoted paragraph lazily
            // (CommonMark); anything else — a heading, code or rule that
            // already closed, or a line that starts a new block — ends the
            // quote.
            if !isLineComplete, shouldDeferParagraphFallback(for: lineBuffer) {
                lineDeferredUntilComplete = isDeferredUntilLineEnd(lineBuffer)
                lineAnalyzed = true
                return true
            }
            if top.kind.isHeading || (top.kind == .blockquote && top.hasBlockChildren)
                || startsBlock(lineBuffer[...], isLineComplete: isLineComplete) {
                closeBlockquoteContexts()
                lineAnalyzed = false
                analyzeLineIfNeeded(isLineComplete: isLineComplete)
                return true
            }
            lineAnalyzed = true
            return true
        }

        // A partial line of only markers may still grow deeper (`>` then
        // `> `): keep the markers seen so far out of the content and wait.
        if !isLineComplete, lineBuffer.allSatisfy({ $0 == ">" || $0 == " " || $0 == "\t" }),
           quote.markerCount <= activeLevel {
            lineQuotePrefix = quote.prefixLength
            if emittedCount < quote.prefixLength {
                emittedCount = min(lineBuffer.count, quote.prefixLength)
            }
            lineAnalyzed = true
            return true
        }

        if quote.markerCount > activeLevel {
            // Deeper markers open nested quotes. They are children of the
            // enclosing quote, so an open child block of it ends first.
            if !topIsQuote { closeContexts(above: quoteIndex) }
            openBlockquotes(from: activeLevel, to: quote.markerCount, prefixLength: quote.prefixLength)
        } else if quote.markerCount < activeLevel {
            // Fewer markers: a paragraph continues lazily at the deeper
            // level; blank content or a new block closes the inner quotes.
            let content = lineBuffer.dropFirst(quote.prefixLength)
            let blank = content.allSatisfy { $0 == " " || $0 == "\t" }
            if topIsVerbatim || top.kind.isHeading || (top.kind == .blockquote && top.hasBlockChildren)
                || (blank && isLineComplete) || startsBlock(content, isLineComplete: isLineComplete) {
                while let current = currentBlock,
                      current.kind != .blockquote || current.blockquoteLevel > quote.markerCount {
                    closeCurrentBlock()
                }
            } else if blank {
                lineAnalyzed = true
                return true
            }
        }

        lineQuotePrefix = quote.prefixLength
        if emittedCount < quote.prefixLength {
            emittedCount = min(lineBuffer.count, quote.prefixLength)
        }
        guard let current = currentBlock else { return false }
        let content = lineContent

        switch current.kind {
        case .blockquote, .paragraph, .footnoteDefinition:
            if !isLineComplete, shouldDeferParagraphFallback(for: String(content)) || listMarkerIsPending(String(content)) {
                lineDeferredUntilComplete = isDeferredUntilLineEnd(String(content))
                lineAnalyzed = true
                return true
            }
            // Openers are decided once per line: after one ran, or after any
            // of the line's content has been emitted, a re-analysis (the line
            // grew) must not open the same block again. Indentation consumed
            // for a list item is not content, so an opener may still follow.
            if !lineOpenedChild, !lineEmittedContent, openQuotedChild(from: content, isLineComplete: isLineComplete) {
                return true
            }
            if current.kind == .blockquote, current.hasBlockChildren,
               !content.allSatisfy({ $0 == " " || $0 == "\t" }) {
                openInlineBlock(kind: .paragraph, prefixToStrip: quote.prefixLength)
            }
            lineAnalyzed = true
            return true
        case .listItem:
            // Lists nest, continue and end by their content's indentation.
            analyzeListItemLine(isLineComplete: isLineComplete)
            return true
        case .heading, .horizontalRule:
            // Single-line blocks close at the end of their line.
            lineAnalyzed = true
            return true
        default:
            return false
        }
    }

    /// Opens a child block of the enclosing quote when `content` starts
    /// one. A paragraph child in progress ends first; the quote itself
    /// stays open.
    private mutating func openQuotedChild(from content: Substring, isLineComplete: Bool) -> Bool {
        let line = String(content)
        let prefix = lineQuotePrefix

        func beginChild() {
            lineOpenedChild = true
            if let current = currentBlock {
                switch current.kind {
                case .paragraph, .footnoteDefinition: closeCurrentBlock()
                default: break
                }
            }
            if let quoteIndex = contextStack.lastIndex(where: { $0.kind == .blockquote }) {
                contextStack[quoteIndex].hasBlockChildren = true
            }
        }

        if isLineComplete, let mathOpen = detectDisplayMathOpening(line) {
            beginChild()
            openDisplayMathBlock(marker: mathOpen.marker,
                                 closing: mathOpen.closing,
                                 initialContent: mathOpen.content,
                                 indent: mathOpen.leadingIndent,
                                 closeAfterCurrentLine: mathOpen.closesOnSameLine)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return true
        }
        if isLineComplete, let fence = detectFenceOpening(line) {
            beginChild()
            openFencedCode(fence)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return true
        }
        if let heading = detectHeading(line, isLineComplete: isLineComplete) {
            beginChild()
            openInlineBlock(kind: .heading(level: heading.level), prefixToStrip: prefix + heading.prefixLength)
            emittedCount = min(lineBuffer.count, prefix + heading.prefixLength)
            lineAnalyzed = true
            return true
        }
        if isLineComplete, detectHorizontalRule(line, indent: 0) {
            beginChild()
            emitHorizontalRuleBlock()
            return true
        }
        if let footnote = detectFootnoteDefinition(line) {
            beginChild()
            let index = footnoteRegistry.index(for: footnote.id)
            openInlineBlock(kind: .footnoteDefinition(id: footnote.id, index: index),
                            prefixToStrip: prefix + footnote.prefixLength)
            emittedCount = min(lineBuffer.count, prefix + footnote.prefixLength)
            lineAnalyzed = true
            return true
        }
        if isLineComplete, detectTableCandidate(line) {
            beginChild()
            openTable(line)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return true
        }
        if let list = detectList(line, isLineComplete: isLineComplete) {
            // A quoted paragraph (a paragraph child, or the quote's own text)
            // is only interrupted by a list that may interrupt a paragraph.
            if let current = currentBlock,
               current.kind == .paragraph || (current.kind == .blockquote && current.hasInlineContent && !current.hasBlockChildren),
               !listCanInterruptParagraph(list, line: line) {
                return false
            }
            beginChild()
            openListItem(list)
            emittedCount = min(lineBuffer.count, prefix + list.prefixLength)
            lineAnalyzed = true
            return true
        }
        if isLineComplete, line.hasPrefix(":::") {
            beginChild()
            openUnknown()
            appendUnknownLiteral(line)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return true
        }
        return false
    }

    /// Whether a line (already stripped of any quote prefix) opens a block
    /// that interrupts a paragraph. Mirrors the openers `openQuotedChild`
    /// knows plus the ones a top-level paragraph yields to.
    private func startsBlock(_ content: Substring, isLineComplete: Bool, interruptingParagraph: Bool = true) -> Bool {
        let line = String(content)
        if detectHeading(line, isLineComplete: isLineComplete) != nil { return true }
        if let list = detectList(line, isLineComplete: isLineComplete) {
            // Ending a table (or another non-paragraph) has no interruption
            // rule; only a paragraph is picky about which lists may follow.
            return !interruptingParagraph || listCanInterruptParagraph(list, line: line)
        }
        // `$$x$$` is display math only if nothing follows on the line
        // (`$$x$$y` is a paragraph), so math waits for the complete line
        // like fences, rules and tables.
        guard isLineComplete else { return false }
        return detectDisplayMathOpening(line) != nil || detectFenceOpening(line) != nil
            || detectHorizontalRule(line, indent: 0) || detectTableCandidate(line) || line.hasPrefix(":::")
    }

    /// Inside a quote, a list marker with nothing after it yet (`- `) waits
    /// for one more character: the item's task state is published with the
    /// item and cannot change later.
    private func listMarkerIsPending(_ line: String) -> Bool {
        guard let list = detectList(line, isLineComplete: true) else { return false }
        let suffix = line.dropFirst(list.indentText.count + list.markerLength)
        if suffix.isEmpty { return true }
        // A complete but empty `[x] ` waits too: an empty item cannot
        // interrupt a paragraph, so where it belongs (which quote, or text)
        // is only known once content or the newline arrives.
        return suffix.hasPrefix("[") && ["[ ] ", "[x] ", "[X] "].contains { $0.hasPrefix(suffix) }
    }

    private mutating func closeContexts(above index: Int) {
        while contextStack.count > index + 1 {
            closeCurrentBlock()
        }
    }

    private mutating func appendDeltaIfNeeded(includeTerminatingNewline: Bool = false, isLineComplete: Bool = false) {
        guard let ctx = currentBlock else { return }
        if lineDeferredUntilComplete, !isLineComplete { return }
        if ctx.kind == .table {
            emittedCount = lineBuffer.count
            return
        }
        var context = ctx
        if case .fencedCode = ctx.kind {
            let strip = lineQuotePrefix + fenceIndentToStrip(lineContent, fence: ctx.fenceInfo)
            if emittedCount < strip { emittedCount = min(lineBuffer.count, strip) }
        }
        let sourceLine: String = includeTerminatingNewline ? lineBuffer + "\n" : lineBuffer
        let start: String.Index
        if emittedLineBlockID == ctx.id, let byteOffset = emittedLineUTF8Offset,
           let resumed = sourceLine.utf8.index(sourceLine.utf8.startIndex, offsetBy: byteOffset, limitedBy: sourceLine.utf8.endIndex) {
            start = resumed
        } else {
            start = sourceLine.index(sourceLine.startIndex, offsetBy: min(emittedCount, sourceLine.count))
        }
        guard start < sourceLine.endIndex else { return }
        // Marker-only quote lines (`>`, `>  `) are paragraph separators, not
        // content: never emit their leftover whitespace (or a hard-break
        // newline from trailing spaces). While the line may still grow this
        // only defers — if text follows, the full delta is emitted then.
        if case .blockquote = context.kind,
           isQuoteMarkerOnlyLine(lineBuffer.trimmingCharacters(in: .whitespaces)) {
            return
        }
        let trimmedLine = lineContent.trimmingCharacters(in: .whitespaces)
        if !isLineComplete {
            // When the line buffer still looks like an incomplete block-level
            // construct (list marker, heading, fence, etc.), defer emission so
            // marker characters don't leak into the current block's content.
            // Once enough characters arrive to resolve the ambiguity, the full
            // content is emitted (or a block transition consumes the prefix).
            switch context.kind {
            case .paragraph, .listItem, .blockquote, .footnoteDefinition, .heading:
                if trimmedLine.isEmpty { return }   // leading whitespace of a continuation line
                if shouldDeferParagraphFallback(for: String(lineContent)) { return }
            case .fencedCode, .math:
                // Inside a quote, a partial line of only whitespace is never
                // code yet: after a marker it may still be part of the prefix
                // (`> ` of `> >`), and without one it either grows a marker
                // or ends the quote. Wait for text.
                if trimmedLine.isEmpty, contextStack.contains(where: { $0.kind == .blockquote }) { return }
                // A blank line of indented code is held until the line ends
                // (it may still gain text, which would make it a code line).
                if trimmedLine.isEmpty, isIndentedCodeBlock(context) { return }
                // A partial line made only of the fence's marker may still
                // become the closing fence; emitting it now would put stray
                // backticks in the code. Likewise a partial math closer.
                if !context.fenceJustOpened, let fence = context.fenceInfo, !fence.isIndented, !trimmedLine.isEmpty {
                    let closing = fence.closingMarker ?? fence.marker
                    if let marker = closing.first, trimmedLine.allSatisfy({ $0 == marker }) { return }
                    if case .math = context.kind, closing.hasPrefix(trimmedLine) { return }
                }
            case .unknown:
                // Same as code: inside a quote, whitespace after a partial
                // marker may still be part of the prefix, or the line may
                // end the quote. Nothing of it is the block's text yet.
                if trimmedLine.isEmpty, contextStack.contains(where: { $0.kind == .blockquote }) { return }
            default:
                break
            }
        }
        let delta = String(sourceLine[start...])
        if case .math = context.kind, context.pendingSameLineClose {
            emittedCount = lineBuffer.count
            setCurrentBlock(context)
            enforceLineBufferBudget()
            return
        }
        if case .math = context.kind,
           !context.fenceJustOpened,
           let closingMarker = context.fenceInfo?.closingMarker,
           let closingRange = delta.range(of: closingMarker) {
            let beforeClosing = String(delta[..<closingRange.lowerBound])
            if !beforeClosing.isEmpty {
                append(beforeClosing, context: &context)
            } else {
                context.fenceJustOpened = false
            }
            context.pendingSameLineClose = true
            emittedCount = lineBuffer.count
            setCurrentBlock(context)
            enforceLineBufferBudget()
            return
        }
        // A closing fence is only known once the line is complete: a partial
        // `~~~` may still grow into `~~~not a close`.
        if isLineComplete, case .fencedCode = context.kind,
           !context.fenceJustOpened,
           isClosingFence(String(lineContent), fence: context.fenceInfo) {
            emittedCount = lineBuffer.count
            setCurrentBlock(context)
            return
        }
        if isLineComplete, case .math = context.kind,
           !context.fenceJustOpened,
           isClosingFence(String(lineContent), fence: context.fenceInfo) {
            emittedCount = lineBuffer.count
            setCurrentBlock(context)
            return
        }
        if isIndentedCodeBlock(context), lineContent.allSatisfy({ $0 == " " || $0 == "\t" }) {
            // Blank lines inside indented code wait for the next code line;
            // trailing ones are not part of the block.
            if pendingCodeBlankLinesBlock != context.id {
                pendingCodeBlankLines.removeAll(keepingCapacity: true)
                pendingCodeBlankLinesBlock = context.id
            }
            pendingCodeBlankLines.append(delta)
            setCurrentBlock(context)
            emittedLineUTF8Offset = lineBuffer.utf8.count
            emittedLineBlockID = context.id
            emittedCount = lineBuffer.count
            return
        }
        append(delta, context: &context)
        lineEmittedContent = true
        setCurrentBlock(context)
        emittedLineUTF8Offset = lineBuffer.utf8.count
        emittedLineBlockID = context.id
        emittedCount = lineBuffer.count
        enforceLineBufferBudget()
    }

    private mutating func finalizeLine(terminated: Bool, force: Bool) {
        if !terminated && !force { return }
        if lineIsLinkDefinition {
            resetLineState()
            return
        }
        let rawLine = lineBuffer
        // Inside a quote, the children judge the line by its content after
        // the `>` prefix: a marker-only line is blank to them.
        let trimmed = lineContent.trimmingCharacters(in: .whitespaces)
        let isBlank = trimmed.isEmpty

        if isBlank, !force, let top = currentBlock,
           contextStack.contains(where: { $0.kind == .blockquote }) {
            // A blank or marker-only line ends the quote and everything in
            // it — except inside quoted code, where `>` alone is a blank
            // code line (its newline was already appended).
            let blankCodeLine = lineQuotePrefix > 0 && top.kind.isVerbatim
            if !blankCodeLine {
                closeBlockquoteContexts()
                resetLineState()
                return
            }
        }

        if var ctx = currentBlock {
            switch ctx.kind {
            case .paragraph, .footnoteDefinition:
                if terminated && !isBlank && rawLine.hasSuffix(" ") && !rawLine.hasSuffix("  ") {
                    trimTrailingSpace(for: &ctx)
                    setCurrentBlock(ctx)
                }
                if isBlank {
                    closeCurrentBlock()
                } else if force {
                    closeCurrentBlock()
                } else if terminated {
                    // Two trailing spaces carry the newline itself as a hard
                    // break. An odd run of trailing backslashes is a hard break
                    // only if another line follows (a backslash that ends the
                    // paragraph is literal), so it is resolved when the next
                    // line's text arrives. Anything else is a soft break.
                    let trailingBackslashes = rawLine.reversed().prefix(while: { $0 == "\\" }).count
                    if trailingBackslashes % 2 == 1 {
                        ctx.pendingHardBreak = true
                        setCurrentBlock(ctx)
                    } else if !rawLine.hasSuffix("  ") {
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
                    // When a blank line closes a list item, mark the parent
                    // list item (if any) so that non-continuation text on the
                    // next line ends the list instead of being lazily appended.
                    if isBlank, var parent = currentBlock, case .listItem = parent.kind {
                        parent.sawBlankInSubContext = true
                        setCurrentBlock(parent)
                    }
                } else if !lineConsumedByRule {
                    // An indented rule inside the item is its own block, not
                    // a line of the item's text.
                    appendToCurrent("\n")
                }
            case .blockquote:
                if terminated && !isBlank && rawLine.hasSuffix(" ") && !rawLine.hasSuffix("  ") {
                    trimTrailingSpace(for: &ctx)
                    setCurrentBlock(ctx)
                }
                if isBlank || force || isQuoteMarkerOnlyLine(trimmed) {
                    // A `>` line with no content is a blank line inside the
                    // quote: it ends the paragraph, so close the quote stack
                    // now. The next quote line reopens at its own marker
                    // depth (that is how `> back to level one` exits a nested
                    // quote and how `>` separators split quote paragraphs);
                    // an unquoted line starts a normal paragraph instead of
                    // lazily continuing the old quote.
                    closeBlockquoteContexts()
                } else if !lineConsumedByRule {
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
                if (!ctx.fenceJustOpened && isClosingFence(String(lineContent), fence: ctx.fenceInfo)) || force {
                    closeCurrentBlock()
                }
            case .math:
                // A closer on the opening line ends the block with the line.
                if ctx.pendingSameLineClose || (!ctx.fenceJustOpened && isClosingFence(String(lineContent), fence: ctx.fenceInfo)) || force {
                    closeCurrentBlock()
                }
            case .horizontalRule:
                break
            case .table:
                handleTableLine(rawLine: String(lineContent), trimmed: trimmed, terminated: terminated, force: force)
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
        emittedLineUTF8Offset = nil
        emittedLineBlockID = nil
        lineAnalyzed = false
        lineQuotePrefix = 0
        lineConsumedByRule = false
        lineBufferTrimmed = 0
        lineDeferredUntilComplete = false
        lineOpenedChild = false
        lineEmittedContent = false
    }

    private mutating func closePendingSameLineBlocks() {
        while let ctx = currentBlock, ctx.pendingSameLineClose {
            closeCurrentBlock()
        }
    }

    private func makeInlineParser() -> InlineParser {
        var parser = InlineParser(tagPrefixes: tagPrefixes)
        parser.linkReferences = linkReferenceStore
        parser.footnoteRegistry = footnoteRegistry
        return parser
    }

    private mutating func flushPendingInlineTailForOpenBlocks() {
        guard !contextStack.isEmpty else { return }
        for index in contextStack.indices {
            var ctx = contextStack[index]
            guard var parser = ctx.inlineParser else { continue }
            let flushedRuns = parser.flushPendingTail()
            guard !flushedRuns.isEmpty else {
                ctx.inlineParser = parser
                contextStack[index] = ctx
                continue
            }
            appendFlushedRuns(flushedRuns, to: &ctx)
            ctx.inlineParser = parser
            contextStack[index] = ctx
        }
    }

    private mutating func appendToCurrent(_ text: String) {
        guard var ctx = currentBlock else { return }
        let preserveLiteralRuns = text == "\n"
        append(text, context: &ctx, preserveLiteralRuns: preserveLiteralRuns)
        if preserveLiteralRuns {
            ctx.preventNextCoalesce = true
        }
        setCurrentBlock(ctx)
    }

    private mutating func append(_ text: String, context ctx: inout BlockContext, preserveLiteralRuns: Bool = false) {
        guard !text.isEmpty else { return }
        if text.contains(where: { !$0.isWhitespace }) { ctx.hasInlineContent = true }
        switch ctx.kind {
        case .paragraph, .listItem, .blockquote, .footnoteDefinition:
            if var parser = ctx.inlineParser {
                var input = text
                // A footnote definition continues over lines like a
                // paragraph; without the soft break `first` + `second`
                // would run together.
                if ctx.kind == .paragraph || ctx.kind.isFootnoteDefinition, ctx.pendingHardBreak {
                    // The newline reaches the inline parser right after the
                    // trailing backslash it kept pending: a hard break. Inside
                    // an open code span the backslash is literal and the line
                    // ending is a space, as any soft break.
                    input = (parser.hasOpenCodeSpan ? " " : "\n") + input
                    ctx.pendingHardBreak = false
                } else if ctx.kind == .paragraph || ctx.kind.isFootnoteDefinition, ctx.pendingSoftBreak {
                    input = " " + input
                    ctx.pendingSoftBreak = false
                }
                var runs = parser.append(input)
                let shouldCoalesceNewRuns = !preserveLiteralRuns
                if shouldCoalesceNewRuns {
                    coalesceInlineRuns(&runs)
                }
                if !runs.isEmpty {
                    if let lastIndex = events.indices.last,
                       case .blockAppendInline(let existingID, var existingRuns) = events[lastIndex],
                       existingID == ctx.id {
                        existingRuns.append(contentsOf: runs)
                        let shouldCoalesceExisting = shouldCoalesceNewRuns && !ctx.preventNextCoalesce
                        if shouldCoalesceExisting {
                            coalesceInlineRuns(&existingRuns)
                        }
                        events[lastIndex] = .blockAppendInline(id: ctx.id, runs: existingRuns)
                    } else {
                        events.append(.blockAppendInline(id: ctx.id, runs: runs))
                    }
                }
                ctx.inlineParser = parser
                if ctx.preventNextCoalesce {
                    ctx.preventNextCoalesce = false
                }
            }
        case .heading:
            if var parser = ctx.inlineParser {
                // Spaces and `#`s are held back: at the end of the line they are
                // a closing sequence (dropped) or trailing content. A `#` run
                // right after a backslash is escaped content.
                var emitted = ""
                var pending = ctx.headingPendingSuffix
                // Escape state survives chunk boundaries: the backslash may
                // have arrived in the previous chunk.
                var escapedRun = ctx.headingEscapedRun
                var afterBackslash = ctx.headingAfterBackslash
                for character in text {
                    if character == "\n" {
                        emitted.append(contentsOf: resolvedHeadingSuffix(pending, hasContent: ctx.headingHasContent || !emitted.isEmpty))
                        pending.removeAll(keepingCapacity: true)
                        escapedRun = false
                        afterBackslash = false
                    } else if character == "#", escapedRun || (pending.isEmpty && afterBackslash) {
                        escapedRun = true
                        afterBackslash = false
                        emitted.append(character)
                    } else if character == " " || character == "\t" || character == "#" {
                        escapedRun = false
                        afterBackslash = false
                        pending.append(character)
                    } else {
                        escapedRun = false
                        if !pending.isEmpty {
                            emitted.append(contentsOf: pending)
                            pending.removeAll(keepingCapacity: true)
                        }
                        emitted.append(character)
                        afterBackslash = character == "\\"
                    }
                }
                ctx.headingPendingSuffix = pending
                ctx.headingEscapedRun = escapedRun
                ctx.headingAfterBackslash = afterBackslash
                if !emitted.isEmpty { ctx.headingHasContent = true }
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
            ctx.literal.append(text)
        case .fencedCode:
            // Blank lines held inside indented code precede the code that
            // follows them.
            var chunk = text
            if pendingCodeBlankLinesBlock == ctx.id, !pendingCodeBlankLines.isEmpty {
                chunk = pendingCodeBlankLines + text
                pendingCodeBlankLines.removeAll(keepingCapacity: true)
            }
            if let lastIndex = events.indices.last {
                if case .blockAppendFencedCode(let existingID, let existingText) = events[lastIndex], existingID == ctx.id {
                    events[lastIndex] = .blockAppendFencedCode(id: ctx.id, textChunk: existingText + chunk)
                } else {
                    events.append(.blockAppendFencedCode(id: ctx.id, textChunk: chunk))
                }
            } else {
                events.append(.blockAppendFencedCode(id: ctx.id, textChunk: chunk))
            }
            ctx.fenceJustOpened = false
        case .math:
            if let lastIndex = events.indices.last {
                if case .blockAppendMath(let existingID, let existingText) = events[lastIndex], existingID == ctx.id {
                    events[lastIndex] = .blockAppendMath(id: ctx.id, textChunk: existingText + text)
                } else {
                    events.append(.blockAppendMath(id: ctx.id, textChunk: text))
                }
            } else {
                events.append(.blockAppendMath(id: ctx.id, textChunk: text))
            }
            ctx.fenceJustOpened = false
        case .horizontalRule:
            break
        case .table:
            // table text handled at line boundaries
            break
        }
        ctx.linePrefixToStrip = 0
    }

    private mutating func appendFlushedRuns(_ runs: [InlineRun], to ctx: inout BlockContext) {
        var normalized = runs
        coalesceInlineRuns(&normalized)
        guard !normalized.isEmpty else { return }
        if let lastIndex = events.indices.last,
           case .blockAppendInline(let existingID, var existingRuns) = events[lastIndex],
           existingID == ctx.id {
            existingRuns.append(contentsOf: normalized)
            coalesceInlineRuns(&existingRuns)
            events[lastIndex] = .blockAppendInline(id: ctx.id, runs: existingRuns)
        } else {
            events.append(.blockAppendInline(id: ctx.id, runs: normalized))
        }
    }

    private func canCoalesce(_ lhs: InlineRun, _ rhs: InlineRun) -> Bool {
        lhs.canCoalesce(with: rhs)
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

        let trimEnd = lineBuffer.index(lineBuffer.startIndex, offsetBy: trimCount)
        let trimmedBytes = lineBuffer.utf8.distance(from: lineBuffer.utf8.startIndex, to: trimEnd)
        lineBuffer.removeFirst(trimCount)
        if let byteOffset = emittedLineUTF8Offset {
            emittedLineUTF8Offset = max(0, byteOffset - trimmedBytes)
        }
        lineBufferTrimmed += trimCount
        emittedCount = max(0, emittedCount - trimCount)
        lineQuotePrefix = max(0, lineQuotePrefix - trimCount)
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
            if parseAlignment(trimmed) == nil, !detectTableCandidate(rawLine),
               startsBlock(rawLine[...], isLineComplete: true) || detectBlockquote(rawLine) != nil {
                // The second line opens another block, so only the header
                // line was a failed candidate: degrade that one and let the
                // opener be analyzed, filled and finalized as itself.
                degradeTableCandidate(context: &ctx, table: table, terminated: true)
                emittedCount = 0
                lineAnalyzed = false
                analyzeLineIfNeeded(isLineComplete: true)
                appendDeltaIfNeeded(includeTerminatingNewline: shouldIncludeTerminatingNewline(), isLineComplete: true)
                finalizeLine(terminated: terminated, force: force)
                return
            }
            table.bufferedLines.append(rawLine)
            if let alignments = parseAlignment(trimmed) {
                table.alignments = alignments
                // The candidate is now a confirmed table: announce the block
                // and the header in one batch. Header cells get the same
                // inline parsing as row cells so `| **bold** |` renders
                // identically in headers and body rows.
                let headerLine = table.bufferedLines.first ?? ""
                let headerCells = splitCells(headerLine).map { InlineParser.parseAll($0, tagPrefixes: tagPrefixes) }
                events.append(.blockStart(id: ctx.id, kind: .table))
                events.append(.tableHeaderCandidate(id: ctx.id, cells: headerCells))
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

    /// Replays a failed table candidate's buffered lines as an unknown block.
    ///
    /// Degradation only happens from the `.header`/`.separatorPending` stages,
    /// and `openTable` emits nothing for those stages, so there are no
    /// already-delivered table events to retract here — the block ID is fresh
    /// from the assembler's point of view and can be reused for the fallback.
    private mutating func degradeTableCandidate(context ctx: inout BlockContext, table: TableState, terminated: Bool) {
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

    /// What a heading's held-back tail contributes once the line ends: a
    /// closing sequence (optional spaces, `#`s, optional spaces, preceded by
    /// a space or standing alone on an empty heading) contributes nothing;
    /// anything else is content, minus trailing whitespace.
    private func resolvedHeadingSuffix(_ pending: String, hasContent: Bool) -> String {
        let trimmed = pending.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        let isClosingSequence = trimmed.allSatisfy { $0 == "#" }
            && (pending.first == " " || pending.first == "\t" || !hasContent)
        if isClosingSequence { return "" }
        var content = pending
        while let last = content.last, last == " " || last == "\t" { content.removeLast() }
        return content
    }

    private mutating func closeCurrentBlock() {
        guard let ctx = currentBlock else { return }
        if pendingCodeBlankLinesBlock == ctx.id {
            // Trailing blank lines of indented code are not part of it.
            pendingCodeBlankLines.removeAll(keepingCapacity: true)
            pendingCodeBlankLinesBlock = nil
        }
        if let table = ctx.tableState, table.stage != .rows {
            // A candidate that never got its separator was never announced;
            // replay its lines as an unknown block instead of ending it.
            var candidate = ctx
            degradeTableCandidate(context: &candidate, table: table, terminated: true)
            return
        }
        if var parser = ctx.inlineParser {
            var runs: [InlineRun] = []
            if case .heading = ctx.kind {
                // The input may end without a newline: settle the tail now.
                let tail = resolvedHeadingSuffix(ctx.headingPendingSuffix, hasContent: ctx.headingHasContent)
                if !tail.isEmpty { runs += parser.append(tail) }
            }
            runs += parser.finish()
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

    /// Opens nested blockquote contexts from `currentLevel` (exclusive)
    /// through `targetLevel` (inclusive), so `>>` / `> > >` markers produce
    /// child blocks — mirroring how deeper list items push nested contexts.
    /// The assembler derives `parentID`/`depth` from the open-block stack.
    private mutating func openBlockquotes(from currentLevel: Int, to targetLevel: Int, prefixLength: Int) {
        var level = currentLevel
        while level < targetLevel {
            level += 1
            openInlineBlock(kind: .blockquote, prefixToStrip: prefixLength)
            if var opened = currentBlock {
                opened.blockquoteLevel = level
                setCurrentBlock(opened)
            }
        }
    }

    /// Closes the current context and any enclosing blockquote contexts.
    /// Blank lines (and interrupting blocks) end the entire quote stack.
    private mutating func closeBlockquoteContexts() {
        guard let outermost = contextStack.firstIndex(where: { $0.kind == .blockquote }) else {
            closeCurrentBlock()
            return
        }
        while contextStack.count > outermost {
            closeCurrentBlock()
        }
    }

    /// True for lines that consist only of `>` markers and whitespace —
    /// a blank line *inside* a blockquote (paragraph separator).
    private func isQuoteMarkerOnlyLine(_ trimmed: String) -> Bool {
        guard trimmed.contains(">") else { return false }
        return trimmed.allSatisfy { $0 == ">" || $0 == " " || $0 == "\t" }
    }

    private mutating func openInlineBlock(kind: BlockKind, prefixToStrip: Int = 0) {
        let context = BlockContext(
            id: nextID,
            kind: kind,
            inlineParser: makeInlineParser(),
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
            inlineParser: makeInlineParser(),
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
                updated.preventNextCoalesce = true
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

    private mutating func openIndentedCode(prefixLength: Int) {
        let context = BlockContext(
            id: nextID,
            kind: .fencedCode(language: nil),
            inlineParser: nil,
            tableState: nil,
            fenceInfo: FenceInfo(marker: "", language: nil, closingMarker: nil, isIndented: true),
            literal: "",
            fenceJustOpened: false,
            linePrefixToStrip: prefixLength,
            headingPendingSuffix: "",
            eventStartIndex: events.count,
            listIndent: 0
        )
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: .fencedCode(language: nil)))
        pushBlock(context)
    }

    /// Opens a *candidate* table context without emitting any events.
    ///
    /// Events for the table (`blockStart`, `tableHeaderCandidate`,
    /// `tableHeaderConfirmed`) are deferred until the separator line validates
    /// the candidate in `handleTableLine`. Events are drained to the assembler
    /// at every chunk boundary, so announcing the block here would make
    /// degradation impossible without retracting already-delivered events —
    /// violating the "no provisional events followed by corrections" invariant
    /// whenever the header and separator arrive in different chunks.
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
        context.tableState = TableState(stage: .header, alignments: [], bufferedLines: [])
        pushBlock(context)
    }

    private func detectFenceOpening(_ line: String) -> FenceInfo? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var index = trimmed.startIndex
        var marker = ""
        while index < trimmed.endIndex, trimmed[index] == first {
            marker.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        guard marker.count >= 3 else { return nil }
        let rawInfo = trimmed[index...].trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string may not contain backticks (CommonMark);
        // ``` ``` is a code span, not a fence.
        if first == "`", rawInfo.contains("`") { return nil }
        let info = unescapePunctuation(rawInfo)
        return FenceInfo(marker: marker, language: info.isEmpty ? nil : info, closingMarker: marker, leadingIndent: indent)
    }

    /// Backslash escapes of ASCII punctuation are processed in info strings.
    private func unescapePunctuation(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                if !(character.isASCII && (character.isPunctuation || character.isSymbol)) {
                    result.append("\\")
                }
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping { result.append("\\") }
        return result
    }

    /// Up to the opening fence's indent is removed from a content line.
    private func fenceIndentToStrip(_ content: Substring, fence: FenceInfo?) -> Int {
        guard let fence, !fence.isIndented, fence.leadingIndent > 0 else { return 0 }
        return min(fence.leadingIndent, content.prefix { $0 == " " }.count)
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
        func makeOpening(open: String, close: String, contentMayFollow: Bool) -> DisplayMathOpening? {
            guard line[index...].hasPrefix(open) else { return nil }
            let contentStart = line.index(index, offsetBy: open.count)
            guard contentStart <= line.endIndex else { return nil }
            let remainder = line[contentStart...]
            if remainder.trimmingCharacters(in: .whitespaces).isEmpty {
                return DisplayMathOpening(marker: open, closing: close, content: "", closesOnSameLine: false, leadingIndent: indent)
            }
            if let closingRange = remainder.range(of: close) {
                // Only allow trailing whitespace after the closing marker
                let afterClose = remainder[closingRange.upperBound...].trimmingCharacters(in: .whitespaces)
                guard afterClose.isEmpty else { return nil }
                let inner = remainder[..<closingRange.lowerBound]
                return DisplayMathOpening(marker: open, closing: close, content: String(inner), closesOnSameLine: true, leadingIndent: indent)
            } else if contentMayFollow {
                return DisplayMathOpening(marker: open, closing: close, content: String(remainder), closesOnSameLine: false, leadingIndent: indent)
            } else {
                return nil
            }
        }

        // Try $$...$$ first, then \[...\]. A `$$` opener may carry content
        // on its own line; `\[` opens display math only alone on its line or
        // closed on the same line, because `\[` is otherwise CommonMark's
        // escaped bracket (`\[not a link](/foo)` is a paragraph) and an
        // opener that never closed would swallow the rest of the document.
        if let open = makeOpening(open: "$$", close: "$$", contentMayFollow: true) { return open }
        if let open = makeOpening(open: "\\[", close: "\\]", contentMayFollow: false) { return open }
//        if let open = makeOpening(open: "\\(", close: "\\)") { return open }

        return nil
    }

    private mutating func emitHorizontalRuleBlock() {
        let blockID = nextID
        nextID &+= 1
        events.append(.blockStart(id: blockID, kind: .horizontalRule))
        events.append(.blockEnd(id: blockID))
        emittedCount = lineBuffer.count
        lineConsumedByRule = true
        lineAnalyzed = true
    }

    private mutating func openDisplayMathBlock(marker: String,
                                               closing: String,
                                               initialContent: String,
                                               indent: Int,
                                               closeAfterCurrentLine: Bool = false) {
        var context = BlockContext(
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
        context.pendingSameLineClose = closeAfterCurrentLine
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: .math(display: true)))
        pushBlock(context)
        if !initialContent.isEmpty {
            appendToCurrent(initialContent)
        }
    }

    /// `line` is the content line without any quote prefix, untrimmed: a
    /// code fence closes on a run of its marker at least as long as the
    /// opener, indented at most three spaces, with nothing else on the line.
    private func isClosingFence(_ line: String, fence: FenceInfo?) -> Bool {
        guard let fence = fence else { return false }
        if fence.isIndented { return false }
        let marker = fence.closingMarker ?? fence.marker
        if let first = marker.first, first == "`" || first == "~", marker.allSatisfy({ $0 == first }) {
            let indent = line.prefix { $0 == " " }.count
            guard indent <= 3 else { return false }
            let content = line.dropFirst(indent)
            let run = content.prefix { $0 == first }.count
            return run >= marker.count && content.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(marker) else { return false }
        let remainder = trimmed.dropFirst(marker.count)
        return remainder.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func detectHeading(_ line: String, isLineComplete: Bool = false) -> HeadingInfo? {
        var index = line.startIndex
        var indent = 0
        // Up to three spaces of indentation (CommonMark); four is code.
        while index < line.endIndex, line[index] == " ", indent < 4 {
            indent += 1
            index = line.index(after: index)
        }
        guard indent <= 3 else { return nil }
        var level = 0
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0 else { return nil }
        // The markers end at a space or tab, or at the end of a complete line
        // (`#` alone is an empty heading). A partial line of only `#` waits:
        // it may still become `#hashtag`.
        if index == line.endIndex {
            guard isLineComplete else { return nil }
            return HeadingInfo(level: level, prefixLength: indent + level, indent: indent)
        }
        guard line[index] == " " || line[index] == "\t" else { return nil }
        let prefixLength = indent + level + 1 // indent + heading markers + following space
        return HeadingInfo(level: level, prefixLength: prefixLength, indent: indent)
    }

    private func detectList(_ line: String, isLineComplete: Bool = false) -> ListInfo? {
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
                // "1. " followed by content (standard case)
                let hasSpaceAfterDot = afterDot < line.endIndex && line[afterDot] == " "
                // "1." at end of line — empty list item, only when line is complete
                let isEmptyMarker = isLineComplete && afterDot >= line.endIndex
                if hasSpaceAfterDot || isEmptyMarker {
                    let numberPart = line[index..<numberEnd]
                    if let number = Int(numberPart) {
                        ordered = true
                        listIndex = number
                        markerLength = hasSpaceAfterDot
                            ? digits + 2   // "1. " — digits + ". "
                            : digits + 1   // "1." — no trailing space
                    }
                }
            }
        }

        guard markerLength > 0 else { return nil }

        let markerEnd = line.index(index, offsetBy: markerLength)
        if !isLineComplete {
            // The item's task state is published with the item and cannot
            // change later: wait while the text after the marker could
            // still grow into `[ ] ` / `[x] `.
            let suffix = line[markerEnd...]
            if suffix.hasPrefix("["),
               ["[ ] ", "[x] ", "[X] "].contains(where: { $0.hasPrefix(suffix) }) {
                return nil
            }
        }
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

    /// `maxMarkers` stops after that many `>`; what follows is content.
    private func detectBlockquote(_ line: String, maxMarkers: Int? = nil) -> BlockquoteInfo? {
        var prefixLength = 0
        var markerCount = 0
        var pendingWhitespace = 0
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character == ">" {
                if let maxMarkers, markerCount >= maxMarkers { break }
                // Between markers, CommonMark allows the previous marker's
                // optional trailing space plus up to three more spaces of
                // indentation before a nested `>` (`>  > nested` nests;
                // five spaces make the inner marker literal content).
                if markerCount > 0 && pendingWhitespace > 3 { break }
                prefixLength += pendingWhitespace + 1
                pendingWhitespace = 0
                markerCount += 1
                index = line.index(after: index)
                // One optional space (or tab) belongs to the marker itself.
                if index < line.endIndex, line[index] == " " || line[index] == "\t" {
                    prefixLength += 1
                    index = line.index(after: index)
                }
            } else if character == " " || character == "\t" {
                pendingWhitespace += 1
                index = line.index(after: index)
            } else {
                break
            }
        }

        guard markerCount > 0 else { return nil }
        return BlockquoteInfo(prefixLength: prefixLength, markerCount: markerCount)
    }

    /// Source characters of indentation to strip from a list continuation
    /// line, or 0 when the line is not indented enough. The decision uses
    /// visual columns (a tab is four); the returned count is in characters,
    /// since callers use it as an offset into the line.
    private func listContinuationPrefixLength(_ line: String, currentIndent: Int) -> Int {
        var columns = 0
        var characters = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4
            } else {
                break
            }
            characters += 1
        }
        let relative = columns - currentIndent
        return relative >= 2 ? characters : 0
    }

    private func shouldStartNewListItem(currentContext: BlockContext, list: ListInfo, emittedCount: Int) -> Bool {
        guard case .listItem(let currentOrdered, let currentIndex, let currentTask) = currentContext.kind else { return true }
        if emittedCount >= list.prefixLength {
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

    private func isIndentedCodeBlock(_ context: BlockContext) -> Bool {
        guard case .fencedCode = context.kind else { return false }
        return context.fenceInfo?.isIndented == true
    }

    private func detectIndentedCodePrefix(_ line: String) -> Int? {
        guard !line.isEmpty else { return nil }
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            return nil
        }
        if line.hasPrefix("\t") {
            return 1
        }
        let spaces = line.prefix { $0 == " " }.count
        return spaces >= 4 ? 4 : nil
    }

    private func shouldDeferParagraphFallback(for line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        if trimmed.first == "|" { return true }          // table candidate
        if trimmed.hasPrefix(":::") { return true }      // unknown block extension fallback
        if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") { return true } // display math
        if trimmed == "$" || trimmed == "\\" { return true } // may become a display-math opener
        if trimmed == ":" || trimmed == "::" { return true } // may become `:::`
        if trimmed.hasPrefix("[") {
            // `[label]:` is a reference definition; until the bracket closes
            // and the next character is known, the line is ambiguous. A label
            // holds at most 999 characters (CommonMark), which also bounds
            // the rescan while the line is still ambiguous.
            let window = trimmed.prefix(1001)
            guard let close = window.firstIndex(of: "]") else { return window.count <= 1000 }
            let after = trimmed.index(after: close)
            if after == trimmed.endIndex { return true }
            // `[label]: /url` is a definition only if nothing but an optional
            // title follows, so the whole line decides.
            if trimmed[after] == ":" { return true }
        }

        if trimmed.allSatisfy({ $0 == "#" || $0 == " " }) {
            return true // heading marker may be split before text arrives
        }
        if trimmed.allSatisfy({ $0 == ">" || $0 == " " }) && trimmed.contains(">") {
            return true // blockquote markers only
        }
        if isPotentialHorizontalRule(trimmed) {
            return true // `* *` may still become a rule, which outranks a list
        }
        if isPotentialListMarkerOnly(trimmed) {
            return true
        }
        if let list = detectList(line, isLineComplete: true) {
            // `- [x` may still become a task item; its state is published
            // with the item and cannot change later.
            let suffix = line.dropFirst(list.indentText.count + list.markerLength)
            // The complete `- [ ] ` waits too: with nothing after it the
            // item is empty, which cannot interrupt a paragraph, and then
            // its trailing space must stay out of the text until the line
            // ends and trims it.
            if suffix.hasPrefix("["),
               ["[ ] ", "[x] ", "[X] "].contains(where: { $0.hasPrefix(suffix) }) {
                return true
            }
        }
        if isPotentialFencePrefixOnly(trimmed) {
            return true
        }
        if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == " " }) {
            return true // could still become horizontal rule on newline
        }
        return false
    }

    /// CommonMark: a list interrupts a paragraph only if it is a bullet list
    /// or starts at 1, and only with a non-empty item.
    private func listCanInterruptParagraph(_ list: ListInfo, line: String) -> Bool {
        if list.ordered, list.index != 1 { return false }
        return !line.dropFirst(list.prefixLength).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Lines whose classification cannot change before the newline: display
    /// math (`$$x$$` vs `$$x$$y`), table candidates and `:::` blocks. Other
    /// deferrals resolve as characters arrive.
    private func isDeferredUntilLineEnd(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") || trimmed.first == "|" || trimmed.hasPrefix(":::") {
            return true
        }
        // `[label]:` with its destination still streaming: a definition only
        // if nothing but an optional title follows on the line.
        guard trimmed.first == "[", let close = trimmed.prefix(1001).firstIndex(of: "]") else { return false }
        let after = trimmed.index(after: close)
        return after < trimmed.endIndex && trimmed[after] == ":"
    }

    /// A partial line of one rule character (`-`, `*` or `_`) and spaces,
    /// indented at most three, may still become a thematic break.
    private func isPotentialHorizontalRule(_ line: String) -> Bool {
        guard line.prefix(while: { $0 == " " }).count <= 3 else { return false }
        let content = line.drop(while: { $0 == " " })
        guard let first = content.first, first == "-" || first == "*" || first == "_" else { return false }
        return content.allSatisfy { $0 == first || $0 == " " || $0 == "\t" }
    }

    private func isPotentialListMarkerOnly(_ trimmed: String) -> Bool {
        if trimmed == "-" || trimmed == "*" || trimmed == "+" { return true }
        if (trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")) &&
            trimmed.dropFirst(2).allSatisfy({ $0 == " " }) {
            return true
        }

        var digits = 0
        var seenDot = false
        for character in trimmed {
            if character.isNumber, !seenDot {
                digits += 1
                continue
            }
            if character == ".", !seenDot, digits > 0 {
                seenDot = true
                continue
            }
            if character == " ", seenDot {
                continue
            }
            return false
        }
        // digits only (e.g. "1") — could still become "1. " ordered list marker
        // digits + dot (e.g. "1.") or digits + dot + spaces (e.g. "1. ")
        return digits > 0
    }

    private func isPotentialFencePrefixOnly(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "`" || first == "~" else { return false }
        if trimmed.allSatisfy({ $0 == first || $0 == " " }) { return true }
        // 3+ markers followed by content = fence with partial/full language identifier
        let markerCount = trimmed.prefix(while: { $0 == first }).count
        return markerCount >= 3
    }

    private func detectTableCandidate(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        guard trimmed.first == "|" else { return false }
        let pipeCount = trimmed.filter { $0 == "|" }.count
        return pipeCount >= 2
    }

    private func detectHorizontalRule(_ line: String, indent: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Spaces and tabs may separate the characters (CommonMark); at least
        // three of the characters themselves are needed.
        let stripped = trimmed.filter { $0 != " " && $0 != "\t" }
        guard stripped.count >= 3 else { return false }
        guard let first = stripped.first, ["-", "*", "_"].contains(first) else { return false }
        guard stripped.allSatisfy({ $0 == first }) else { return false }
        let leadingSpaces = line.prefix { $0 == " " }.count
        if indent > 0 {
            return leadingSpaces >= indent
        }
        // Four or more spaces is indented code, or a paragraph's continuation.
        return leadingSpaces <= 3
    }

    private func detectLinkDefinition(_ line: String) -> (label: String, url: String, title: String?)? {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " ", leadingSpaces < 3 {
            leadingSpaces += 1
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == "[" else { return nil }
        guard let closingBracket = line[index...].prefix(1001).firstIndex(of: "]") else { return nil }
        let afterBracket = line.index(after: closingBracket)
        guard afterBracket < line.endIndex, line[afterBracket] == ":" else { return nil }
        let labelStart = line.index(after: index)
        let label = String(line[labelStart..<closingBracket])
        if label.isEmpty { return nil }
        if label.hasPrefix("^") { return nil }

        var cursor = line.index(after: afterBracket)
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex else { return nil }

        let destination: String
        if line[cursor] == "<" {
            let destStart = line.index(after: cursor)
            guard let closing = line[destStart...].firstIndex(of: ">") else { return nil }
            destination = String(line[destStart..<closing])
            cursor = line.index(after: closing)
        } else {
            let destStart = cursor
            while cursor < line.endIndex, !line[cursor].isWhitespace {
                cursor = line.index(after: cursor)
            }
            destination = String(line[destStart..<cursor])
        }

        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex else {
            return (label, destination, nil)
        }

        let title: String?
        let quote = line[cursor]
        if quote == "\"" || quote == "'" {
            let titleStart = line.index(after: cursor)
            if let closing = line[titleStart...].firstIndex(of: quote) {
                title = String(line[titleStart..<closing])
            } else {
                title = nil
            }
        } else if quote == "(" {
            let titleStart = line.index(after: cursor)
            if let closing = line[titleStart...].firstIndex(of: ")") {
                title = String(line[titleStart..<closing])
            } else {
                title = nil
            }
        } else {
            title = nil
        }

        return (label, destination, title)
    }

    private func detectFootnoteDefinition(_ line: String) -> (id: String, prefixLength: Int)? {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " ", leadingSpaces < 3 {
            leadingSpaces += 1
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == "[" else { return nil }
        let caretIndex = line.index(after: index)
        guard caretIndex < line.endIndex, line[caretIndex] == "^" else { return nil }
        guard let closingBracket = line[caretIndex...].prefix(1000).firstIndex(of: "]") else { return nil }
        let afterBracket = line.index(after: closingBracket)
        guard afterBracket < line.endIndex, line[afterBracket] == ":" else { return nil }
        let idStart = line.index(after: caretIndex)
        let id = String(line[idStart..<closingBracket])
        guard !id.isEmpty else { return nil }
        var cursor = line.index(after: afterBracket)
        if cursor < line.endIndex, line[cursor] == " " {
            cursor = line.index(after: cursor)
        }
        let prefixLength = line.distance(from: line.startIndex, to: cursor)
        return (id, prefixLength)
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
                // Look ahead to see if we're escaping a pipe
                let nextIndex = line.index(after: index)
                if nextIndex < line.endIndex && line[nextIndex] == "|" {
                    // Escaping a pipe - consume the backslash
                    escaping = true
                } else {
                    // Not escaping a pipe - preserve the backslash for inline parsing
                    current.append(character)
                    escaping = true
                }
            } else if character == "|" {
                cells.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        if escaping {
            // Trailing backslash already appended above; leave as literal.
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

        // Flatten cells: LLMs sometimes produce ":--- :---" (space instead of pipe)
        var flatCells: [String] = []
        for raw in cells {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count > 1, parts.allSatisfy({ $0.allSatisfy({ $0 == ":" || $0 == "-" }) }) {
                flatCells.append(contentsOf: parts)
            } else {
                flatCells.append(trimmed)
            }
        }

        var result: [TableAlignment] = []
        for cell in flatCells {
            var s = cell

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
        splitCells(line).map { InlineParser.parseAll($0, tagPrefixes: tagPrefixes) }
    }

    private func snapshotOpenBlocks() -> [OpenBlockState] {
        var states: [OpenBlockState] = []
        states.reserveCapacity(contextStack.count)
        for (index, context) in contextStack.enumerated() {
            // Unconfirmed table candidates have not been announced via
            // `blockStart` (see `openTable`), so they must not appear in
            // `openBlocks` either — the assembler would otherwise track an ID
            // it has never seen. A candidate is always the top of the stack,
            // so skipping it cannot orphan a child context.
            if case .table = context.kind, context.tableState?.stage != TableState.Stage.rows {
                continue
            }
            let parentID = index > 0 ? contextStack[index - 1].id : nil
            states.append(OpenBlockState(id: context.id, kind: context.kind, parentID: parentID, depth: index))
        }
        return states
    }

    private func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

private extension BlockKind {
    /// Blocks whose lines are taken literally.
    var isVerbatim: Bool {
        switch self {
        case .fencedCode, .math: return true
        default: return false
        }
    }

    var isFootnoteDefinition: Bool {
        if case .footnoteDefinition = self { return true }
        return false
    }

    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }
}
