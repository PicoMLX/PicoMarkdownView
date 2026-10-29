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
        var pendingSoftBreak: Bool = false
        /// The line ended with an odd run of backslashes: a hard break if
        /// another line follows, a literal backslash if the block ends.
        var pendingHardBreak: Bool = false
        var pendingSameLineClose: Bool = false
        var preventNextCoalesce: Bool = false
        /// 1-based nesting level for `.blockquote` contexts (`>` = 1,
        /// `>>` = 2, …); 0 for every other kind.
        var blockquoteLevel: Int = 0
        /// A blockquote that has opened a child block (heading, fence, …) or
        /// seen a marker-only line (a paragraph boundary). Later plain text
        /// goes into a paragraph child so source order is kept, instead of
        /// being appended to the quote's own inline runs.
        var hasBlockChildren: Bool = false
        /// Non-whitespace inline text has been appended: for a blockquote
        /// this means its own text acts as an open paragraph.
        var hasInlineContent: Bool = false
        /// For a list item outside any quote: the column its content starts
        /// at (CommonMark's W + N). A line belongs to the item when it is
        /// indented at least this far.
        var listContentColumn: Int = 0
        /// A heading has received content other than a possible closing
        /// sequence; decides whether trailing `#`s alone close an empty heading.
        var headingHasContent: Bool = false
        /// Escape state of a heading's text at a chunk boundary: the last
        /// emitted character was a backslash, or a `#` run that a backslash
        /// started as content is still running.
        var headingAfterBackslash: Bool = false
        var headingEscapedRun: Bool = false
        /// For an HTML block: what ends it, whether the current line holds
        /// its end marker, and the current line's last bytes (ASCII
        /// lowercased), so a marker split across chunks is still found.
        var htmlEnd: HTMLBlockEnd?
        var htmlEndSeen: Bool = false
        var htmlLineTail: [UInt8] = []
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
        /// The marker and the whitespace after it that precedes the content.
        var markerLength: Int
        var indentText: String
        var task: TaskListState?
        var taskMarkerLength: Int
        /// The column the item's content starts at: the marker's, plus its
        /// width, plus one to four spaces (one for an empty item, or when
        /// five or more follow, which then start indented code).
        var contentColumn: Int

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
    /// Top-level lines that may still be link reference definitions, which
    /// can span lines (`[foo]:`, then the destination, then the title). They
    /// are held, not shown, until the lines decide (`resolveDefinitionHold`).
    private var definitionHold = ""
    /// The held definition's title, still open: the next line resumes it
    /// rather than parsing the whole definition again.
    private var definitionTitleProgress: LinkDefinitionTitleProgress?
    /// A line joined the hold; it is resolved once the line is finalized.
    private var definitionHoldPending = false
    /// The next line is held text being replayed as what it turned out to
    /// be, which is not a definition.
    private var suppressDefinitionHold = false

    private var currentBlock: BlockContext? {
        contextStack.last
    }

    /// Index of the outermost open quote, or the end of the stack. List
    /// items below it are containers (`analyzeListContainers`); items above
    /// it are quoted lists.
    private var outermostQuoteIndex: Int {
        contextStack.firstIndex { $0.kind == .blockquote } ?? contextStack.count
    }

    /// Index of the deepest list item outside any quote.
    private var lastContainerItemIndex: Int? {
        contextStack[..<outermostQuoteIndex].lastIndex(where: \.kind.isListItem)
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
    /// Length of the run of backslashes the current line ends with, kept as
    /// characters arrive so it survives look-behind trimming; its parity
    /// decides whether the line ending is a hard break.
    private var lineTrailingBackslashes = 0
    /// A child block opener ran on the current line (`openQuotedChild`).
    private var lineOpenedChild = false
    /// Some of the current line's content reached a block. Consuming a list
    /// item's indentation alone does not count, so a later opener on the
    /// same line is still allowed.
    private var lineEmittedContent = false
    /// How many runs of open list items, outermost first, have judged the
    /// current line (`analyzeListContainers`); a re-analysis only routes
    /// its content through them.
    private var lineItemRunsJudged = 0
    /// The line lazily continues a paragraph inside a list item.
    private var lineListLazy = false
    /// The list items the line opened.
    private var lineOpenedListItems = 0
    /// Characters at the start of `lineBuffer` that are the prefixes of the
    /// line's containers: `>` markers (with their optional space) and list
    /// item indentation. Everything after it is the line as the innermost
    /// container's children see it.
    private var lineQuotePrefix: Int = 0
    /// The line is read container run by container run, outermost first:
    /// the run at stack index `lineContainerIndex` (list items, or quotes)
    /// reads it from `lineContainerBase`, past the prefixes of the runs
    /// below it.
    private var lineContainerIndex = 0
    private var lineContainerBase = 0
    /// The run of quotes that handed the line to the items inside it, and
    /// where it read the line from: when no item keeps the line, it is that
    /// quote's again.
    private var lineQuoteRunStart = 0
    private var lineQuoteRunBase = 0
    /// Columns of the last tab in the line's container prefix that reach
    /// past the container's content column: they are indentation of the
    /// content, though their character went to the prefix.
    private var linePrefixOvershoot = 0
    /// Spaces that start the line's indented code text: the columns of a
    /// tab in its prefix that reach past the code's four.
    private var lineCodePadding = 0
    /// End of the deepest run of quotes whose `>` markers the line carries,
    /// as a stack index; 0 when it carries none.
    private var lineMarkedQuoteEnd = 0
    /// The line carries the `>` markers of every open quote. Without them, a
    /// blank line ends the quotes it does not mark, and quoted code cannot
    /// continue.
    private var lineQuoteMarked: Bool {
        !contextStack[min(lineMarkedQuoteEnd, contextStack.count)...].contains { $0.kind == .blockquote }
    }
    /// Set when the line became a horizontal rule, which pushes no context:
    /// the enclosing block must not treat the line as its own text.
    private var lineConsumedByRule = false
    /// The line may still start an HTML block (`<div` without its next
    /// character, or a tag that must turn out alone on its line): none of it
    /// is content until that is decided.
    private var lineHTMLPending = false
    private var events: [BlockEvent] = []

    /// The current line is blank to an HTML block: only whitespace inside
    /// its containers. A line some of whose text has gone out is not, even
    /// once the look-behind budget has trimmed all of it but whitespace.
    private var htmlLineIsBlank: Bool {
        !lineEmittedContent && lineContent.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// The current line without its blockquote prefix.
    private var lineContent: Substring {
        lineQuotePrefix > 0 ? lineBuffer.dropFirst(lineQuotePrefix) : lineBuffer[...]
    }

    /// The look-behind budget trimmed the front of a line whose content
    /// already reached a block: the line is classified, and what remains of
    /// it is that block's text, not the start of a line (`- - -` after a
    /// trim is no rule or list marker). Its tail streams without re-analysis.
    private var lineIsSettled: Bool {
        lineBufferTrimmed > 0 && lineEmittedContent
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
                suppressDefinitionHold = false
                if definitionHoldPending {
                    definitionHoldPending = false
                    resolveDefinitionHold(isFinal: false)
                }
            } else {
                lineBuffer.append(character)
                // Counted as characters arrive: the line buffer may be trimmed
                // by the look-behind budget, so it cannot be counted later.
                lineTrailingBackslashes = character == "\\" ? lineTrailingBackslashes + 1 : 0
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
            suppressDefinitionHold = false
            definitionHoldPending = false
            if !definitionHold.isEmpty {
                resolveDefinitionHold(isFinal: true)
            }
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
            if !lineQuoteMarked, contextStack.contains(where: { $0.kind == .blockquote }),
               lineBuffer.allSatisfy({ $0 == " " || $0 == "\t" }) {
                return false
            }
            return !ctx.fenceJustOpened
        case .htmlBlock:
            // Every line ends with its newline, except a blank line that ends
            // the block (or, unmarked, the quote around it).
            let blank = htmlLineIsBlank
            if blank, ctx.htmlEnd == .blankLine { return false }
            if blank, !lineQuoteMarked, contextStack.contains(where: { $0.kind == .blockquote }) { return false }
            return true
        case .horizontalRule:
            return false
        case .unknown:
            return !lineBuffer.isEmpty
        case .table:
            return false
        }
    }

    /// GFM: a table ends at a blank line or the start of another block,
    /// judged on the line's content inside its containers. Only the line in
    /// hand is reconsidered; emitted rows stay as they are.
    private func lineEndsTable(_ table: BlockContext, isLineComplete: Bool) -> Bool {
        isLineComplete && table.tableState?.stage == .rows
            && (startsBlock(lineContent, isLineComplete: true, interruptingParagraph: false) || detectBlockquote(String(lineContent)) != nil)
            && !detectTableCandidate(String(lineContent))
    }

    private mutating func analyzeLineIfNeeded(isLineComplete: Bool) {
        if lineAnalyzed { return }

        lineIsLinkDefinition = false
        lineHTMLPending = false
        if !definitionHold.isEmpty, analyzeLineAfterDefinitionHold(isLineComplete: isLineComplete) { return }
        if lineIsSettled {
            lineAnalyzed = true
            return
        }

        let trimmed = lineBuffer.trimmingCharacters(in: .whitespaces)
        // The open containers read the line outermost first; the walk starts
        // afresh each time the line grows.
        lineContainerIndex = 0
        lineContainerBase = 0
        linePrefixOvershoot = 0

        // Outermost list items judge a line by its indentation before
        // anything else: a line they do not keep ends them first, so a
        // definition after them is a top-level one. A quote inside the
        // deepest of them reads its markers after their indentation.
        let walkedItems = !trimmed.isEmpty && contextStack.first?.kind.isListItem == true
        if walkedItems, walkContainers(isLineComplete: isLineComplete) {
            return
        }
        let insideQuote = contextStack.contains(where: { $0.kind == .blockquote })

        // An unmarked line inside a quote is the quote's business first: it
        // ends quoted code (and is then a definition at the outer level) or
        // continues a quoted paragraph, which a definition cannot interrupt.
        let unmarkedInsideQuote = insideQuote && detectBlockquote(String(lineBuffer.dropFirst(lineContainerBase))) == nil
        // A definition cannot interrupt a paragraph; at the top level it may
        // span lines, so its lines are held until they decide.
        if isLineComplete, !unmarkedInsideQuote, contextStack.isEmpty, !suppressDefinitionHold,
           startsLinkDefinition(lineBuffer) {
            holdDefinitionLine()
            return
        }
        if isLineComplete, !unmarkedInsideQuote, let ctx = currentBlock, case .listItem = ctx.kind,
           let linkDefinition = detectLinkDefinition(lineBuffer) {
            linkReferenceStore.define(label: linkDefinition.label, url: linkDefinition.url, title: linkDefinition.title)
            lineIsLinkDefinition = true
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return
        }

        if trimmed.isEmpty {
            if var ctx = currentBlock, case .listItem = ctx.kind {
                ctx.linePrefixToStrip = 0
                setCurrentBlock(ctx)
            }
            // A blank line stays in the list items outside quotes, so it
            // loses their indentation, up to the deepest content column,
            // before a code block inside sees it.
            if let itemIndex = lastContainerItemIndex {
                lineQuotePrefix = characters(covering: contextStack[itemIndex].listContentColumn, in: lineBuffer).count
            }
            consumeBlankCodeIndentation()
            lineAnalyzed = true
            return
        }

        if !walkedItems, contextStack.first?.kind == .blockquote, walkContainers(isLineComplete: isLineComplete) {
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
            if openHTMLBlockIfStarted(lineBuffer[...], isLineComplete: isLineComplete, interruptingParagraph: false) {
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
                // What follows the marker is the item's content, which may
                // open a block of its own (`- # Heading`, `- - nested`).
                if analyzeListContent(isLineComplete: isLineComplete) == .next { _ = walkContainers(isLineComplete: isLineComplete) }
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
                if openHTMLBlockIfStarted(lineBuffer[...], isLineComplete: isLineComplete, interruptingParagraph: true) {
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
                    if analyzeListContent(isLineComplete: isLineComplete) == .next { _ = walkContainers(isLineComplete: isLineComplete) }
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
                // List items judge their lines in `analyzeListContainers`.
                break
            case .blockquote:
                // Every line inside a quote is handled by `analyzeQuotedLine`.
                break
            case .math, .htmlBlock:
                break
            case .fencedCode:
                if isIndentedCodeBlock(ctx) {
                    // Inside a quote the code sees the line after the `>`
                    // prefix: `>` alone is a blank code line, and the code's
                    // own four columns follow the prefix.
                    let content = String(lineContent)
                    if let code = indentedCodePrefix(content, startColumn: 0, extraColumns: linePrefixOvershoot) {
                        let strip = lineQuotePrefix + code.characters
                        ctx.linePrefixToStrip = strip
                        setCurrentBlock(ctx)
                        if emittedCount < strip {
                            emittedCount = min(lineBuffer.count, strip)
                        }
                        if !lineEmittedContent { lineCodePadding = code.padding }
                        lineAnalyzed = true
                        return
                    }
                    if !content.allSatisfy({ $0 == " " || $0 == "\t" }) {
                        closeCurrentBlock()
                        analyzeLineIfNeeded(isLineComplete: isLineComplete)
                        return
                    }
                    // A blank line inside the code loses up to four columns
                    // of indentation like any code line; the rest is content
                    // (the unquoted case is handled with other blank lines).
                    let blankPrefix = min(4, content.hasPrefix("\t") ? 1 : content.prefix { $0 == " " }.count)
                    let strip = lineQuotePrefix + blankPrefix
                    if emittedCount < strip {
                        emittedCount = min(lineBuffer.count, strip)
                    }
                }
                break
            case .horizontalRule:
                break
            case .table:
                if lineEndsTable(ctx, isLineComplete: isLineComplete) {
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

    // MARK: List item containers

    /// A line judged by a run of open list items (consecutive items in the
    /// stack, starting at `lineContainerIndex`), read from
    /// `lineContainerBase`, past the containers outside the run: CommonMark
    /// list item containers. Each item, outermost first, keeps the line if
    /// it is indented to the item's content column. The first one the line
    /// does not reach ends, with everything in it, unless the line lazily
    /// continues an open paragraph. The rest of the line, past the deepest
    /// keeping item's content column, is that item's content
    /// (`analyzeListContent`). When no item keeps the line, it is the
    /// enclosing quote's again, or a top-level line. (Blank lines are
    /// handled in `finalizeLine`.)
    private mutating func analyzeListContainers(isLineComplete: Bool) -> LineRouting {
        if lineListLazy {
            lineAnalyzed = true
            return .handled
        }
        let start = lineContainerIndex
        let base = lineContainerBase
        if itemRunOrdinal(start) < lineItemRunsJudged {
            // Once the line's container is known and some of its content has
            // gone out, a re-analysis as the line grows has nothing to decide,
            // unless a quote inside the item reads the rest of it.
            let runEnd = containerRunEnd(from: start)
            if lineEmittedContent, runEnd == contextStack.count || contextStack[runEnd].kind != .blockquote {
                lineAnalyzed = true
                return .handled
            }
            return analyzeListContent(isLineComplete: isLineComplete)
        }
        // A prefix set while the line was only whitespace is decided afresh.
        lineQuotePrefix = base
        let line = String(lineBuffer.dropFirst(base))
        let indent = leadingColumns(line)
        // The indentation decides, so it must be complete.
        guard indent.characters < line.count else {
            // Blank inside a quote, the line stays in the items: it loses
            // their indentation, up to the deepest content column, before a
            // code block inside sees it.
            if isLineComplete {
                let deepest = contextStack[containerRunEnd(from: start) - 1]
                lineQuotePrefix = base + characters(covering: deepest.listContentColumn, in: line).count
                consumeBlankCodeIndentation()
            }
            lineAnalyzed = true
            return .handled
        }
        var deepest: Int?
        var firstUnkept: Int?
        for index in start..<containerRunEnd(from: start) {
            if indent.columns >= contextStack[index].listContentColumn {
                deepest = index
            } else {
                firstUnkept = index
                break
            }
        }
        if let firstUnkept {
            let rest = String(line.dropFirst(indent.characters))
            if let top = currentBlock, paragraphIsOpen(top) {
                // A partial line may still turn out to open a block. Its
                // indentation is not content meanwhile, whatever it becomes.
                if !isLineComplete, shouldDeferParagraphFallback(for: rest) || listMarkerIsPending(rest) {
                    lineQuotePrefix = base + indent.characters
                    lineDeferredUntilComplete = isDeferredUntilLineEnd(rest)
                    lineAnalyzed = true
                    return .handled
                }
                // The line is judged where it would go: in the deepest item
                // that keeps it, or in the enclosing container. There any list
                // item starts (the item it would interrupt is the one that
                // ended, not a paragraph); four columns more are indented code,
                // which interrupts nothing.
                let column = deepest.map { contextStack[$0].listContentColumn } ?? 0
                let (localStart, localColumn) = characters(covering: column, in: line)
                let local = String(line.dropFirst(localStart))
                let opensBlock = leadingColumns(local, startColumn: localColumn).columns < 4
                    && (detectList(local, isLineComplete: isLineComplete, columnBase: localColumn) != nil
                        || detectBlockquote(local) != nil
                        || startsBlock(local[...], isLineComplete: isLineComplete, columnBase: localColumn))
                if !opensBlock {
                    lineListLazy = true
                    if emittedCount < base + indent.characters { emittedCount = base + indent.characters }
                    lineAnalyzed = true
                    return .handled
                }
            }
            closeContexts(above: firstUnkept - 1)
        }
        markItemRunJudged(start)
        guard deepest != nil else {
            // Inside a quote, the line is the quote's own, whose items
            // have ended; at the top level it is a top-level line.
            guard start > 0 else { return .unhandled }
            lineContainerIndex = lineQuoteRunStart
            lineContainerBase = lineQuoteRunBase
            return .next
        }
        return analyzeListContent(isLineComplete: isLineComplete)
    }

    /// The current line as content of the deepest item of the run at
    /// `lineContainerIndex`: it continues the item's open child block (code,
    /// a paragraph) or its own text, or starts a block of its own. When a
    /// quote inside the item reads the rest of the line, the walk continues
    /// there (`lineContainerIndex`, `lineContainerBase`).
    private mutating func analyzeListContent(isLineComplete: Bool) -> LineRouting {
        // An item opened on this line has content of its own after its
        // marker, which may open a further item: a loop, not recursion,
        // since a line may nest many.
        while true {
            let start = lineContainerIndex
            guard start < contextStack.count, contextStack[start].kind.isListItem else { return .unhandled }
            let runEnd = containerRunEnd(from: start)
            let itemIndex = runEnd - 1
            let item = contextStack[itemIndex]
            // A tab may reach past the content column; the content then starts
            // at the column the tab reaches.
            let (covered, contentColumn) = characters(covering: item.listContentColumn,
                                                      in: String(lineBuffer.dropFirst(lineContainerBase)))
            let prefix = lineContainerBase + covered
            lineQuotePrefix = prefix
            linePrefixOvershoot = endsOnTabStop(lineContainerBase) ? contentColumn - item.listContentColumn : 0
            if runEnd < contextStack.count, contextStack[runEnd].kind == .blockquote {
                lineContainerBase = prefix
                lineContainerIndex = runEnd
                return .next
            }
            let content = String(lineContent)
            if itemIndex < contextStack.count - 1, var child = currentBlock {
                switch child.kind {
                case .table where lineEndsTable(child, isLineComplete: isLineComplete):
                    // The line is the item's next block. Table lines are
                    // consumed whole, so none of it has gone out yet.
                    closeCurrentBlock()
                    emittedCount = 0
                case .fencedCode where !isIndentedCodeBlock(child), .math, .table, .unknown, .htmlBlock:
                    // Their own line handling reads `lineContent`.
                    lineAnalyzed = true
                    return .handled
                case .fencedCode:
                    if let code = indentedCodePrefix(content, startColumn: contentColumn, extraColumns: linePrefixOvershoot) {
                        child.linePrefixToStrip = prefix + code.characters
                        setCurrentBlock(child)
                        if emittedCount < prefix + code.characters {
                            emittedCount = min(lineBuffer.count, prefix + code.characters)
                        }
                        if !lineEmittedContent { lineCodePadding = code.padding }
                        lineAnalyzed = true
                        return .handled
                    }
                    // Less indented than code: the code ends.
                    closeCurrentBlock()
                default:
                    break
                }
            }
            let leading = content.prefix { $0 == " " || $0 == "\t" }.count
            guard leading < content.count else {
                lineAnalyzed = true
                return .handled
            }
            // A definition cannot interrupt the item's open paragraph.
            if isLineComplete, lineOpenedListItems == 0, !lineEmittedContent, let current = currentBlock,
               current.kind.isListItem, !paragraphIsOpen(current),
               let linkDefinition = detectLinkDefinition(content) {
                linkReferenceStore.define(label: linkDefinition.label, url: linkDefinition.url, title: linkDefinition.title)
                lineIsLinkDefinition = true
                emittedCount = lineBuffer.count
                lineAnalyzed = true
                return .handled
            }
            if !isLineComplete, shouldDeferParagraphFallback(for: content) || listMarkerIsPending(content) {
                lineDeferredUntilComplete = isDeferredUntilLineEnd(content)
                lineAnalyzed = true
                return .handled
            }
            if !lineOpenedChild, !lineEmittedContent,
               openContainerChild(from: lineContent, columnBase: contentColumn, isLineComplete: isLineComplete) {
                // A nested item opened in this run has content of its own,
                // and a quote opened in the item reads the rest of the line.
                let openedRunEnd = containerRunEnd(from: start)
                if openedRunEnd < contextStack.count, contextStack[openedRunEnd].kind == .blockquote {
                    continue
                }
                if openedRunEnd == contextStack.count, let opened = currentBlock,
                   opened.kind.isListItem, opened.id != item.id {
                    lineOpenedChild = false
                    continue
                }
                return .handled
            }
            guard let current = currentBlock else { return .unhandled }
            if current.kind == .paragraph {
                // The line continues the item's paragraph child.
            } else if current.kind.isListItem, current.hasBlockChildren {
                // The item's own text has ended: text is a new paragraph child.
                openInlineBlock(kind: .paragraph, prefixToStrip: prefix + leading)
            }
            if emittedCount < prefix + leading { emittedCount = min(lineBuffer.count, prefix + leading) }
            lineAnalyzed = true
            return .handled
        }
    }

    /// A blank line inside indented code loses up to four columns of
    /// indentation past its containers' prefix, like any code line; the
    /// rest is content.
    private mutating func consumeBlankCodeIndentation() {
        guard let ctx = currentBlock, isIndentedCodeBlock(ctx) else { return }
        let content = lineContent
        let blankPrefix = lineQuotePrefix + min(4, content.hasPrefix("\t") ? 1 : content.prefix { $0 == " " }.count)
        if emittedCount < blankPrefix {
            emittedCount = min(lineBuffer.count, blankPrefix)
        }
    }

    /// What a run of containers made of the current line.
    private enum LineRouting {
        /// The line is analyzed.
        case handled
        /// The generic handling decides: a top-level line, or the per-kind
        /// handling of the innermost block.
        case unhandled
        /// Another run reads the rest of it (`lineContainerIndex`).
        case next
    }

    /// Hands the line from run to run of open containers, starting at
    /// `lineContainerIndex`, in a loop: however deeply quotes and items
    /// nest, each run reads its part once. Returns whether the line is
    /// analyzed.
    private mutating func walkContainers(isLineComplete: Bool) -> Bool {
        while lineContainerIndex < contextStack.count {
            let routing: LineRouting
            if contextStack[lineContainerIndex].kind.isListItem {
                routing = analyzeListContainers(isLineComplete: isLineComplete)
            } else if contextStack[lineContainerIndex].kind == .blockquote {
                routing = analyzeQuotedLine(isLineComplete: isLineComplete)
            } else {
                return false
            }
            switch routing {
            case .handled: return true
            case .unhandled: return false
            case .next: continue
            }
        }
        return false
    }

    /// End of the run of containers of one kind (list items, or quotes)
    /// that starts at stack index `start`: the first index past it that is
    /// not of that kind.
    private func containerRunEnd(from start: Int) -> Int {
        let quotes = contextStack[start].kind == .blockquote
        var end = start + 1
        while end < contextStack.count,
              quotes ? contextStack[end].kind == .blockquote : contextStack[end].kind.isListItem {
            end += 1
        }
        return end
    }

    /// How many runs of list items lie below stack index `start`.
    private func itemRunOrdinal(_ start: Int) -> Int {
        (0..<start).filter { contextStack[$0].kind.isListItem && ($0 == 0 || !contextStack[$0 - 1].kind.isListItem) }.count
    }

    /// The run of list items at `start` has judged the current line.
    private mutating func markItemRunJudged(_ start: Int) {
        lineItemRunsJudged = max(lineItemRunsJudged, itemRunOrdinal(start) + 1)
    }

    /// A paragraph is open at `context`: a paragraph, or a list item or
    /// quote whose own text has not ended.
    private func paragraphIsOpen(_ context: BlockContext) -> Bool {
        if context.kind == .paragraph { return true }
        return (context.kind.isListItem || context.kind == .blockquote)
            && context.hasInlineContent && !context.hasBlockChildren
    }

    /// Leading whitespace of `line`: its width in columns (a tab advances
    /// to the next multiple of four, counted from `startColumn`, where the
    /// line starts) and in characters.
    private func leadingColumns(_ line: String, startColumn: Int = 0) -> (columns: Int, characters: Int) {
        var columns = 0
        var characters = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4 - (startColumn + columns) % 4
            } else {
                break
            }
            characters += 1
        }
        return (columns, characters)
    }

    /// Characters at the start of `line` that span `columns` columns (a tab
    /// counts whole), or the whole line when it is narrower, and the column
    /// they reach.
    private func characters(covering columns: Int, in line: String) -> (count: Int, column: Int) {
        var column = 0
        var count = 0
        for character in line {
            guard column < columns else { break }
            column += character == "\t" ? 4 - column % 4 : 1
            count += 1
        }
        return (count, column)
    }

    // MARK: Blockquote containers

    /// Handles a line for the run of nested quotes at `lineContainerIndex`:
    /// its `>` markers are read from `lineContainerBase`, and the remainder
    /// is treated like a line of a normal document whose blocks become
    /// children of the innermost quote (CommonMark container prefixes), or
    /// is judged by the list items inside it. `.unhandled` means the
    /// per-kind handling below should still run on the stripped line
    /// (verbatim, math and table children).
    private mutating func analyzeQuotedLine(isLineComplete: Bool) -> LineRouting {
        let start = lineContainerIndex
        guard start < contextStack.count, contextStack[start].kind == .blockquote,
              let top = currentBlock else { return .unhandled }
        // Once the look-behind budget has trimmed the front of this line,
        // its container prefix was resolved and emitted; what remains is
        // content of the block that is open, not a new line to classify.
        if lineBufferTrimmed > 0 {
            lineAnalyzed = true
            return .handled
        }
        let quoteIndex = containerRunEnd(from: start) - 1
        let activeLevel = contextStack[quoteIndex].blockquoteLevel
        let topIsQuote = contextStack.count - 1 == quoteIndex
        let topIsVerbatim = top.kind.isVerbatim || top.kind == .table || top.kind == .unknown
        // List items inside the quote judge the line after its markers.
        let itemsInside = quoteIndex + 1 < contextStack.count && contextStack[quoteIndex + 1].kind.isListItem
        // Inside a list item the markers follow the item's indentation.
        let base = lineContainerBase
        let line = String(lineBuffer.dropFirst(base))
        // Lazy continuation needs an open paragraph (CommonMark). There is
        // none in a heading, in a quote whose own text ended at a separator
        // or that holds child blocks, or in a list item whose own text ended.
        let paragraphEnded: Bool
        if top.kind.isHeading || (top.kind == .blockquote && top.hasBlockChildren) {
            paragraphEnded = true
        } else if case .listItem = top.kind {
            paragraphEnded = !paragraphIsOpen(top)
        } else {
            paragraphEnded = false
        }

        // Inside quoted code or math, further `>` markers are content, so
        // only the enclosing quote's own markers are stripped. With items
        // inside the quote, a further `>` is theirs to judge first.
        guard let quote = detectBlockquote(line, maxMarkers: topIsVerbatim || itemsInside ? activeLevel : nil) else {
            // A partial line of only whitespace may still grow a marker.
            if !isLineComplete, line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                lineAnalyzed = true
                return .handled
            }
            lineQuotePrefix = base
            // Quoted code, math and tables cannot continue without the
            // marker: the quote ends as soon as the line is known not to
            // carry one, before any of the line could reach the verbatim
            // block.
            if topIsVerbatim {
                closeContexts(above: start - 1)
                lineAnalyzed = false
                analyzeLineIfNeeded(isLineComplete: isLineComplete)
                return .handled
            }
            // An unmarked line continues a quoted paragraph lazily
            // (CommonMark); anything else — a heading, code or rule that
            // already closed, or a line that starts a new block — ends the
            // quote.
            if !isLineComplete, shouldDeferParagraphFallback(for: line) {
                lineDeferredUntilComplete = isDeferredUntilLineEnd(line)
                lineAnalyzed = true
                return .handled
            }
            if paragraphEnded || startsBlock(line[...], isLineComplete: isLineComplete) {
                closeContexts(above: start - 1)
                lineAnalyzed = false
                analyzeLineIfNeeded(isLineComplete: isLineComplete)
                return .handled
            }
            // The enclosing items' indentation is not the paragraph's text.
            if emittedCount < base { emittedCount = min(lineBuffer.count, base) }
            lineAnalyzed = true
            return .handled
        }

        // A partial line of only markers may still grow deeper (`>` then
        // `> `): keep the markers seen so far out of the content and wait.
        // Inside quoted indented code a further `>` is content whose
        // indentation decides (four columns: a code line; fewer: the code
        // ends), so the code's own line handling judges it at once. With
        // items inside the quote, once all its markers are there, the items
        // strip their own indentation first.
        if !isLineComplete, !(itemsInside && quote.markerCount == activeLevel),
           line.allSatisfy({ $0 == ">" || $0 == " " || $0 == "\t" }),
           quote.markerCount <= activeLevel,
           !(isIndentedCodeBlock(top) && line.dropFirst(quote.prefixLength).contains(">")) {
            lineQuotePrefix = base + quote.prefixLength
            linePrefixOvershoot = endsOnTabStop(base) ? quoteTabOvershoot(line, prefixLength: quote.prefixLength) : 0
            lineMarkedQuoteEnd = start + quote.markerCount
            if emittedCount < lineQuotePrefix {
                emittedCount = min(lineBuffer.count, lineQuotePrefix)
            }
            lineAnalyzed = true
            return .handled
        }

        if quote.markerCount > activeLevel {
            // Deeper markers open nested quotes. They are children of the
            // enclosing quote, so an open child block of it ends first.
            if !topIsQuote { closeContexts(above: quoteIndex) }
            openBlockquotes(from: activeLevel, to: quote.markerCount, prefixLength: base + quote.prefixLength)
        } else if quote.markerCount < activeLevel {
            // Fewer markers: a paragraph continues lazily at the deeper
            // level; blank content or a new block closes the inner quotes.
            let content = line.dropFirst(quote.prefixLength)
            let blank = content.allSatisfy { $0 == " " || $0 == "\t" }
            if topIsVerbatim || paragraphEnded
                || (blank && isLineComplete) || startsBlock(content, isLineComplete: isLineComplete) {
                closeContexts(above: start + quote.markerCount - 1)
            } else if blank {
                lineAnalyzed = true
                return .handled
            }
        }

        lineQuotePrefix = base + quote.prefixLength
        linePrefixOvershoot = endsOnTabStop(base) ? quoteTabOvershoot(line, prefixLength: quote.prefixLength) : 0
        lineMarkedQuoteEnd = start + quote.markerCount
        if emittedCount < lineQuotePrefix {
            emittedCount = min(lineBuffer.count, lineQuotePrefix)
        }
        // List items inside the quote judge the rest of the line, unless a
        // lazy line continues a deeper quote's paragraph.
        let runEnd = containerRunEnd(from: start)
        if runEnd < contextStack.count, contextStack[runEnd].kind.isListItem,
           quote.markerCount == contextStack[runEnd - 1].blockquoteLevel {
            // If no item keeps the line, the items end and it comes back
            // here, where its further markers may then nest quotes.
            lineQuoteRunStart = start
            lineQuoteRunBase = base
            lineContainerIndex = runEnd
            lineContainerBase = lineQuotePrefix
            return .next
        }
        guard let current = currentBlock else { return .unhandled }
        let content = lineContent

        switch current.kind {
        case .blockquote, .paragraph, .footnoteDefinition:
            if !isLineComplete, shouldDeferParagraphFallback(for: String(content)) || listMarkerIsPending(String(content)) {
                lineDeferredUntilComplete = isDeferredUntilLineEnd(String(content))
                lineAnalyzed = true
                return .handled
            }
            // Openers are decided once per line: after one ran, or after any
            // of the line's content has been emitted, a re-analysis (the line
            // grew) must not open the same block again. Indentation consumed
            // for a list item is not content, so an opener may still follow.
            if !lineOpenedChild, !lineEmittedContent, openContainerChild(from: content, isLineComplete: isLineComplete) {
                // An item opened in the quote starts a run of items there;
                // what follows its marker is its content, as at the top level.
                let runEnd = containerRunEnd(from: start)
                if runEnd < contextStack.count, contextStack[runEnd].kind.isListItem {
                    lineContainerIndex = runEnd
                    lineContainerBase = lineQuotePrefix
                    lineOpenedChild = false
                    return .next
                }
                return .handled
            }
            if current.kind == .blockquote, current.hasBlockChildren,
               !content.allSatisfy({ $0 == " " || $0 == "\t" }) {
                openInlineBlock(kind: .paragraph, prefixToStrip: base + quote.prefixLength)
            }
            lineAnalyzed = true
            return .handled
        case .listItem:
            // Only a lazy line with fewer markers gets here (the items judge
            // every other line): it continues the item's text.
            lineAnalyzed = true
            return .handled
        case .heading, .horizontalRule:
            // Single-line blocks close at the end of their line.
            lineAnalyzed = true
            return .handled
        default:
            return .unhandled
        }
    }

    /// Opens a child block of the enclosing quote or list item when
    /// `content` starts one. A paragraph child in progress ends first; the
    /// container itself stays open. `columnBase` is the column `content`
    /// starts at, for a nested list item's columns.
    private mutating func openContainerChild(from content: Substring, columnBase: Int = 0, isLineComplete: Bool) -> Bool {
        let line = String(content)
        let prefix = lineQuotePrefix
        // Openers read indentation as spaces; indented code and list items
        // count its columns themselves.
        let (opener, dropped) = droppingTabbedIndent(line, columnBase: columnBase)
        // A paragraph is open (a paragraph child, or the container's own
        // text): only a block that may interrupt a paragraph starts here.
        let paragraphIsOpen = currentBlock.map(self.paragraphIsOpen) ?? false

        func beginChild() {
            lineOpenedChild = true
            if let current = currentBlock {
                switch current.kind {
                case .paragraph, .footnoteDefinition: closeCurrentBlock()
                default: break
                }
            }
            if let containerIndex = contextStack.lastIndex(where: { $0.kind == .blockquote || $0.kind.isListItem }) {
                var container = contextStack[containerIndex]
                if container.kind.isListItem, !container.hasBlockChildren, container.hasInlineContent {
                    // The item's own text is complete: settle its inline
                    // parser, which children never feed.
                    emitFinishedInlineRuns(&container)
                    container.inlineParser = makeInlineParser()
                }
                container.hasBlockChildren = true
                contextStack[containerIndex] = container
            }
        }

        if isLineComplete, let mathOpen = detectDisplayMathOpening(opener) {
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
        if isLineComplete, let fence = detectFenceOpening(opener) {
            beginChild()
            openFencedCode(fence)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return true
        }
        // Four columns after the marker are indented code (CommonMark), which
        // cannot interrupt a paragraph: there the line is paragraph text.
        if !paragraphIsOpen,
           let code = indentedCodePrefix(line, startColumn: columnBase, extraColumns: linePrefixOvershoot) {
            beginChild()
            openIndentedCode(prefixLength: prefix + code.characters)
            emittedCount = min(lineBuffer.count, prefix + code.characters)
            lineCodePadding = code.padding
            lineAnalyzed = true
            return true
        }
        // A quote inside a list item: its markers are read after the item's
        // indentation, by the quote's own line handling as the walk goes on
        // (`analyzeListContent`), which then opens its first child. (Inside
        // a quote, deeper markers nest instead.)
        if contextStack.last(where: { $0.kind == .blockquote || $0.kind.isListItem })?.kind.isListItem == true,
           leadingColumns(line, startColumn: columnBase).columns < 4, let quote = detectBlockquote(opener) {
            beginChild()
            openBlockquotes(from: 0, to: quote.markerCount, prefixLength: prefix + dropped + quote.prefixLength)
            lineOpenedChild = false
            return true
        }
        if let heading = detectHeading(opener, isLineComplete: isLineComplete) {
            beginChild()
            openInlineBlock(kind: .heading(level: heading.level), prefixToStrip: prefix + dropped + heading.prefixLength)
            emittedCount = min(lineBuffer.count, prefix + dropped + heading.prefixLength)
            lineAnalyzed = true
            return true
        }
        switch htmlBlockStart(opener[...], isLineComplete: isLineComplete, interruptingParagraph: paragraphIsOpen) {
        case .start(let end):
            beginChild()
            openHTMLBlock(end)
            emittedCount = max(emittedCount, min(lineBuffer.count, prefix))
            lineAnalyzed = true
            return true
        case .pending:
            markHTMLPending()
            lineAnalyzed = true
            return true
        case .none:
            break
        }
        if isLineComplete, detectHorizontalRule(opener, indent: 0) {
            beginChild()
            emitHorizontalRuleBlock()
            return true
        }
        if let footnote = detectFootnoteDefinition(opener) {
            beginChild()
            let index = footnoteRegistry.index(for: footnote.id)
            openInlineBlock(kind: .footnoteDefinition(id: footnote.id, index: index),
                            prefixToStrip: prefix + dropped + footnote.prefixLength)
            emittedCount = min(lineBuffer.count, prefix + dropped + footnote.prefixLength)
            lineAnalyzed = true
            return true
        }
        if isLineComplete, detectTableCandidate(opener) {
            beginChild()
            openTable(opener)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return true
        }
        // Each item opened on a line reads the rest of it again, so like
        // cmark-gfm (`MAX_LIST_DEPTH`) one line opens fewer than 100; any
        // further marker is text.
        if lineOpenedListItems < 99, let list = detectList(line, isLineComplete: isLineComplete, columnBase: columnBase) {
            // A quoted paragraph (a paragraph child, or the quote's own text)
            // is only interrupted by a list that may interrupt a paragraph.
            if paragraphIsOpen, !listCanInterruptParagraph(list, line: line) {
                return false
            }
            beginChild()
            openListItem(list, columnBase: columnBase)
            emittedCount = min(lineBuffer.count, prefix + list.prefixLength)
            lineAnalyzed = true
            return true
        }
        if isLineComplete, opener.hasPrefix(":::") {
            beginChild()
            openUnknown()
            appendUnknownLiteral(line)
            emittedCount = lineBuffer.count
            lineAnalyzed = true
            return true
        }
        return false
    }

    /// `line`, which starts at column `columnBase`, without its indentation
    /// when that holds a tab and spans fewer than four columns, and the
    /// characters dropped. Block openers read indentation as spaces; a tab
    /// counts from the line's start, so inside an item it may span less
    /// than the four columns it would at the top level.
    private func droppingTabbedIndent(_ line: String, columnBase: Int) -> (line: String, dropped: Int) {
        let indentation = leadingColumns(line, startColumn: columnBase)
        guard indentation.columns < 4, line.prefix(indentation.characters).contains("\t") else { return (line, 0) }
        return (String(line.dropFirst(indentation.characters)), indentation.characters)
    }

    /// Whether a line (already stripped of any quote prefix) opens a block
    /// that interrupts a paragraph. Mirrors the openers `openQuotedChild`
    /// knows plus the ones a top-level paragraph yields to. `columnBase` is
    /// the column the line starts at, from which its tabs count.
    private func startsBlock(_ content: Substring, isLineComplete: Bool, interruptingParagraph: Bool = true,
                             columnBase: Int = 0) -> Bool {
        let original = String(content)
        // Four columns of indentation make the line indented code, which
        // cannot interrupt a paragraph: it is a lazy continuation line.
        if interruptingParagraph, detectIndentedCodePrefix(original, startColumn: columnBase) != nil { return false }
        if let list = detectList(original, isLineComplete: isLineComplete, columnBase: columnBase) {
            // Ending a table (or another non-paragraph) has no interruption
            // rule; only a paragraph is picky about which lists may follow.
            return !interruptingParagraph || listCanInterruptParagraph(list, line: original)
        }
        let line = droppingTabbedIndent(original, columnBase: columnBase).line
        if detectHeading(line, isLineComplete: isLineComplete) != nil { return true }
        // A lone tag starts a block but does not interrupt a paragraph.
        if case .start = htmlBlockStart(line[...], isLineComplete: isLineComplete, interruptingParagraph: interruptingParagraph) {
            return true
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
        if lineHTMLPending, !isLineComplete { return }
        // Until a list item has judged the line by its indentation, none of
        // it is content: the leading whitespace may still be the item's.
        if !isLineComplete, lineItemRunsJudged == 0, !lineListLazy,
           lineBuffer.allSatisfy({ $0 == " " || $0 == "\t" }),
           lastContainerItemIndex != nil {
            return
        }
        if ctx.kind == .table {
            emittedCount = lineBuffer.count
            return
        }
        var context = ctx
        if case .fencedCode = ctx.kind {
            let strip = lineQuotePrefix + fenceIndentToStrip(lineContent, fence: ctx.fenceInfo)
            if emittedCount < strip { emittedCount = min(lineBuffer.count, strip) }
        }
        if ctx.kind == .htmlBlock {
            // The line inside its containers is the block's, whitespace and
            // all, but a blank line that ends the block is not.
            if emittedCount < lineQuotePrefix { emittedCount = min(lineBuffer.count, lineQuotePrefix) }
            if isLineComplete, htmlLineIsBlank, ctx.htmlEnd == .blankLine
                || (!lineQuoteMarked && contextStack.contains(where: { $0.kind == .blockquote })) {
                return
            }
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
        let trimmedLine = lineContent.trimmingCharacters(in: .whitespaces)
        // Marker-only quote lines (`>`, `>  `) are paragraph separators, not
        // content: never emit their leftover whitespace (or a hard-break
        // newline from trailing spaces) into the quote or its inline child.
        // While the line may still grow this only defers — if text follows,
        // the full delta is emitted then.
        if lineQuotePrefix > 0, trimmedLine.isEmpty {
            switch context.kind {
            case .blockquote, .paragraph, .listItem, .footnoteDefinition, .heading: return
            default: break
            }
        }
        if !isLineComplete, !lineIsSettled {
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
            case .htmlBlock:
                // Whitespace alone may still be a blank line, which ends the
                // block or its quote; it goes out once text follows it.
                if trimmedLine.isEmpty, !lineEmittedContent { return }
            default:
                break
            }
        }
        var delta = String(sourceLine[start...])
        // The columns of a tab the line's prefix only partly consumed are
        // the code's own spaces, ahead of everything else on the line.
        if lineCodePadding > 0, isIndentedCodeBlock(context) {
            delta = String(repeating: " ", count: lineCodePadding) + delta
            lineCodePadding = 0
        }
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
            // Whitespace of a blank line inside indented code is held, as it
            // streams, until a code line follows; trailing blank lines are not
            // part of the block. If this line turns out to carry text, the
            // held whitespace is its leading indentation and precedes it.
            if pendingCodeBlankLinesBlock != context.id {
                pendingCodeBlankLines.removeAll(keepingCapacity: true)
                pendingCodeBlankLinesBlock = context.id
            }
            pendingCodeBlankLines.append(delta)
            setCurrentBlock(context)
            emittedLineUTF8Offset = lineBuffer.utf8.count
            emittedLineBlockID = context.id
            emittedCount = lineBuffer.count
            enforceLineBufferBudget()
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
        // The line that opens a list item is not blank, even when only its
        // marker, which the container prefix strips, is on it. Nor is a line
        // whose text has gone out, when the look-behind budget has trimmed
        // all of it but trailing whitespace.
        let isBlank = trimmed.isEmpty && lineOpenedListItems == 0 && !(lineEmittedContent && lineBufferTrimmed > 0)

        if isBlank, !force,
           let unmarked = contextStack.indices.first(where: { $0 >= lineMarkedQuoteEnd && contextStack[$0].kind == .blockquote }) {
            // A blank line ends the first quote whose markers it does not
            // carry, and everything in it. A marker-only line (`>`, `>  `) is
            // a blank line *inside* the quotes it marks: it ends the open
            // child below, as a blank line would at the top level, and they
            // stay open (CommonMark).
            closeContexts(above: unmarked - 1)
            resetLineState()
            return
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
                    if lineTrailingBackslashes % 2 == 1 {
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
                if isBlank, !force {
                    // An item stays open across a blank line: the next line
                    // decides by its indentation. Its own text has ended. An
                    // item still empty ends: it begins with at most one blank
                    // line (CommonMark).
                    if !ctx.hasInlineContent, !ctx.hasBlockChildren {
                        closeCurrentBlock()
                    } else if !ctx.hasBlockChildren {
                        emitFinishedInlineRuns(&ctx)
                        ctx.inlineParser = makeInlineParser()
                        ctx.hasBlockChildren = true
                        setCurrentBlock(ctx)
                    }
                } else if force {
                    closeCurrentBlock()
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
                if force {
                    closeBlockquoteContexts()
                } else if isBlank {
                    // A marker-only line is a paragraph boundary, whether or
                    // not the quote has text yet: what follows is a paragraph
                    // child, and an unquoted line no longer continues the
                    // quote lazily (that needs an open paragraph). The quote
                    // itself stays open.
                    if !ctx.hasBlockChildren {
                        ctx.hasBlockChildren = true
                        // The quote's own paragraph is complete: settle its
                        // inline parser now, so text it still holds (an
                        // unmatched opener) is not withheld until the quote
                        // closes. Children never feed it again.
                        emitFinishedInlineRuns(&ctx)
                        ctx.inlineParser = makeInlineParser()
                        setCurrentBlock(ctx)
                    }
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
            case .htmlBlock:
                if force || ctx.htmlEndSeen || (isBlank && htmlLineIsBlank && ctx.htmlEnd == .blankLine) {
                    closeCurrentBlock()
                } else {
                    ctx.htmlLineTail.removeAll(keepingCapacity: true)
                    setCurrentBlock(ctx)
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
        lineTrailingBackslashes = 0
        emittedCount = 0
        emittedLineUTF8Offset = nil
        emittedLineBlockID = nil
        lineAnalyzed = false
        lineQuotePrefix = 0
        lineContainerIndex = 0
        lineContainerBase = 0
        lineMarkedQuoteEnd = 0
        linePrefixOvershoot = 0
        lineCodePadding = 0
        lineConsumedByRule = false
        lineBufferTrimmed = 0
        lineDeferredUntilComplete = false
        lineOpenedChild = false
        lineEmittedContent = false
        lineItemRunsJudged = 0
        lineListLazy = false
        lineOpenedListItems = 0
        lineHTMLPending = false
    }

    /// Whether a line may begin a link reference definition: up to three
    /// spaces, then `[` (but not a footnote's `[^`).
    private func startsLinkDefinition(_ line: String) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        return rest.hasPrefix("[") && !rest.hasPrefix("[^")
    }

    private mutating func holdDefinitionLine() {
        definitionHold += lineBuffer + "\n"
        definitionHoldPending = true
        lineIsLinkDefinition = true
        emittedCount = lineBuffer.count
        lineAnalyzed = true
    }

    /// The current line while definitions are held. A blank line or one
    /// that interrupts a paragraph ends them first; any other complete line
    /// joins them (it may hold the destination or title, or be the
    /// paragraph text that follows). Until it is complete, a line is held
    /// too, unless it cannot begin a title and the held lines are complete
    /// definitions without it: then it streams at once. Returns whether the
    /// line is handled.
    private mutating func analyzeLineAfterDefinitionHold(isLineComplete: Bool) -> Bool {
        if !isLineComplete {
            guard let first = lineBuffer.unicodeScalars.first(where: { $0 != " " && $0 != "\t" }) else {
                lineAnalyzed = true
                return true
            }
            if !"\"'(".unicodeScalars.contains(first), definitionHoldIsComplete() {
                resolveDefinitionHold(isFinal: true)
                return false
            }
            lineDeferredUntilComplete = true
            lineAnalyzed = true
            return true
        }
        let blank = lineBuffer.allSatisfy { $0 == " " || $0 == "\t" }
        if blank || startsBlock(lineBuffer[...], isLineComplete: true) || detectBlockquote(lineBuffer) != nil {
            let line = lineBuffer
            let backslashes = lineTrailingBackslashes
            resetLineState()
            resolveDefinitionHold(isFinal: true)
            lineBuffer = line
            lineTrailingBackslashes = backslashes
            lineAnalyzed = false
            return false
        }
        holdDefinitionLine()
        return true
    }

    private func definitionHoldIsComplete() -> Bool {
        // A title still open would end with its lines left over as text.
        guard definitionTitleProgress == nil else { return false }
        var rest = definitionHold[...]
        var progress: LinkDefinitionTitleProgress?
        while !rest.isEmpty {
            guard case .definition(_, _, _, let end) = parseLinkDefinition(rest, isFinal: true, progress: &progress) else {
                return false
            }
            rest = rest[end...]
        }
        return true
    }

    /// Defines the held definitions that are complete. Text that turns out
    /// not to be one is replayed as ordinary lines (a paragraph); a
    /// definition that may still continue stays held.
    private mutating func resolveDefinitionHold(isFinal: Bool) {
        let held = definitionHold
        var rest = held[...]
        definitionHold = ""
        while !rest.isEmpty {
            switch parseLinkDefinition(rest, isFinal: isFinal, progress: &definitionTitleProgress) {
            case .definition(let label, let url, let title, let end):
                linkReferenceStore.define(label: label, url: url, title: title)
                rest = rest[end...]
            case .incomplete:
                // Kept without a copy when nothing was defined: a title may
                // hold many lines, each resolved as it arrives.
                definitionHold = rest.startIndex == held.startIndex ? held : String(rest)
                return
            case .invalid:
                suppressDefinitionHold = true
                process(String(rest), isFinal: false)
                return
            }
        }
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
                    // trailing backslash it kept pending: a hard break. If it
                    // turns out to fall inside a code span, the span's content
                    // keeps the backslash and turns the newline into a space.
                    input = "\n" + input
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
        case .htmlBlock:
            // The end marker may come anywhere in a line, also split across
            // chunks: each chunk is searched with the line's last bytes
            // before it.
            if case .markers(let markers) = ctx.htmlEnd, !ctx.htmlEndSeen {
                var window = ctx.htmlLineTail
                window.append(contentsOf: text.utf8.map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 })
                ctx.htmlEndSeen = markers.contains { window.firstRange(of: Array($0.utf8)) != nil }
                ctx.htmlLineTail = Array(window.suffix(HTMLBlockEnd.longestMarker - 1))
            }
            if let lastIndex = events.indices.last,
               case .blockAppendFencedCode(let existingID, let existingText) = events[lastIndex], existingID == ctx.id {
                events[lastIndex] = .blockAppendFencedCode(id: ctx.id, textChunk: existingText + text)
            } else {
                events.append(.blockAppendFencedCode(id: ctx.id, textChunk: text))
            }
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
            eventStartIndex: ctx.eventStartIndex
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
        var finished = ctx
        emitFinishedInlineRuns(&finished)
        if !ctx.literal.isEmpty {
            var literalRuns = [InlineRun(text: ctx.literal)]
            coalesceInlineRuns(&literalRuns)
            events.append(.blockAppendInline(id: ctx.id, runs: literalRuns))
        }
        events.append(.blockEnd(id: ctx.id))
        _ = popBlock()
    }

    /// Settles the block's inline parser: everything it still holds (an
    /// unmatched opener's text, a pending tail) is emitted as runs.
    private mutating func emitFinishedInlineRuns(_ ctx: inout BlockContext) {
        guard var parser = ctx.inlineParser else { return }
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
        ctx.inlineParser = parser
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
            eventStartIndex: events.count
        )
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: kind))
        pushBlock(context)
    }

    /// `columnBase` is the column the line `info` was read from starts at,
    /// within an enclosing list item's content.
    private mutating func openListItem(_ info: ListInfo, columnBase: Int = 0) {
        var context = BlockContext(
            id: nextID,
            kind: .listItem(ordered: info.ordered, index: info.index, task: info.task),
            inlineParser: makeInlineParser(),
            tableState: nil,
            fenceInfo: nil,
            literal: "",
            fenceJustOpened: false,
            linePrefixToStrip: info.prefixLength,
            headingPendingSuffix: "",
            eventStartIndex: events.count
        )
        context.listContentColumn = columnBase + info.contentColumn
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: .listItem(ordered: info.ordered, index: info.index, task: info.task)))
        pushBlock(context)
        // The line has found its container: a re-analysis as it grows only
        // routes its content.
        lineOpenedListItems += 1
        var runStart = contextStack.count - 1
        while runStart > 0, contextStack[runStart - 1].kind.isListItem { runStart -= 1 }
        markItemRunJudged(runStart)
        // A nested item keeps its line's indentation as a leading run; read
        // within an enclosing item's content, that is the whole line's, past
        // the containers outside the item's run.
        let indentText = columnBase > 0
            ? String(lineBuffer.dropFirst(lineContainerBase).prefix { $0 == " " || $0 == "\t" })
            : info.indentText
        if !indentText.isEmpty {
            appendToCurrent(indentText)
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
            eventStartIndex: events.count
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
            eventStartIndex: events.count
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

    /// Opens an HTML block when `content` starts one, first ending the open
    /// paragraph when `interruptingParagraph`. Returns whether the line is
    /// handled, which it also is while it may still start one.
    private mutating func openHTMLBlockIfStarted(_ content: Substring, isLineComplete: Bool, interruptingParagraph: Bool) -> Bool {
        switch htmlBlockStart(content, isLineComplete: isLineComplete, interruptingParagraph: interruptingParagraph) {
        case .start(let end):
            if interruptingParagraph { closeCurrentBlock() }
            openHTMLBlock(end)
            lineAnalyzed = true
            return true
        case .pending:
            markHTMLPending()
            lineAnalyzed = true
            return true
        case .none:
            return false
        }
    }

    /// The line may still start an HTML block. Only a lone tag (kind 7) can
    /// stay undecided for long, and reading it again with every chunk would
    /// cost the whole tag each time, so past a few hundred bytes the line
    /// waits for its end instead, like display math.
    private mutating func markHTMLPending() {
        lineHTMLPending = true
        if lineBuffer.utf8.count > 256 { lineDeferredUntilComplete = true }
    }

    /// Its whole first line, leading whitespace included, is its text.
    private mutating func openHTMLBlock(_ end: HTMLBlockEnd) {
        var context = BlockContext(
            id: nextID,
            kind: .htmlBlock,
            inlineParser: nil,
            tableState: nil,
            fenceInfo: nil,
            literal: "",
            fenceJustOpened: false,
            linePrefixToStrip: 0,
            headingPendingSuffix: "",
            eventStartIndex: events.count
        )
        context.htmlEnd = end
        nextID &+= 1
        events.append(.blockStart(id: context.id, kind: .htmlBlock))
        pushBlock(context)
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
            eventStartIndex: events.count
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
            eventStartIndex: events.count
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
        let info = HTMLEntities.unescaping(rawInfo[...])
        return FenceInfo(marker: marker, language: info.isEmpty ? nil : info, closingMarker: marker, leadingIndent: indent)
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
            eventStartIndex: events.count
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

    /// `columnBase` is the column `line` starts at, inside an enclosing
    /// item's content, so tabs reach the same columns as in the whole line.
    private func detectList(_ line: String, isLineComplete: Bool = false, columnBase: Int = 0) -> ListInfo? {
        let (indent, indentCharacters) = leadingColumns(line, startColumn: columnBase)
        let index = line.index(line.startIndex, offsetBy: indentCharacters)
        guard index < line.endIndex else { return nil }
        let indentText = String(line[line.startIndex..<index])

        // A bullet (`-`, `+`, `*`) or one to nine digits and `.` or `)`
        // (CommonMark), then a space or tab, or the end of the line for an
        // empty item.
        var ordered = false
        var listIndex: Int? = nil
        var markerEnd = line.index(after: index)
        if !"-+*".contains(line[index]) {
            var numberEnd = index
            while numberEnd < line.endIndex, line[numberEnd].isASCII, line[numberEnd].isNumber {
                numberEnd = line.index(after: numberEnd)
            }
            let digits = line.distance(from: index, to: numberEnd)
            guard (1...9).contains(digits), numberEnd < line.endIndex, line[numberEnd] == "." || line[numberEnd] == ")" else {
                return nil
            }
            ordered = true
            listIndex = Int(line[index..<numberEnd])
            markerEnd = line.index(after: numberEnd)
        }
        let markerWidth = line.distance(from: index, to: markerEnd)
        guard markerEnd == line.endIndex || line[markerEnd] == " " || line[markerEnd] == "\t" else { return nil }
        // The spaces after the marker set the content column, so they must
        // all have arrived: an item with nothing after its marker yet waits.
        var gapEnd = markerEnd
        var column = indent + markerWidth
        while gapEnd < line.endIndex, line[gapEnd] == " " || line[gapEnd] == "\t" {
            column += line[gapEnd] == "\t" ? 4 - (columnBase + column) % 4 : 1
            gapEnd = line.index(after: gapEnd)
        }
        let empty = gapEnd == line.endIndex
        if empty, !isLineComplete { return nil }
        let contentColumn: Int
        let contentStart: String.Index
        if empty {
            contentColumn = indent + markerWidth + 1
            contentStart = gapEnd
        } else if column - (indent + markerWidth) >= 5 {
            // Five or more spaces: the content is indented code, one column
            // after the marker.
            contentColumn = indent + markerWidth + 1
            contentStart = line.index(after: markerEnd)
        } else {
            contentColumn = column
            contentStart = gapEnd
        }
        let markerLength = line.distance(from: index, to: contentStart)

        let taskStart = contentStart
        if !isLineComplete {
            // The item's task state is published with the item and cannot
            // change later: wait while the text after the marker could
            // still grow into `[ ] ` / `[x] `.
            let suffix = line[taskStart...]
            if suffix.hasPrefix("["),
               ["[ ] ", "[x] ", "[X] "].contains(where: { $0.hasPrefix(suffix) }) {
                return nil
            }
        }
        var task: TaskListState? = nil
        var taskMarkerLength = 0
        if taskStart < line.endIndex, line[taskStart] == "[" {
            let statusIndex = line.index(after: taskStart)
            if statusIndex < line.endIndex {
                let closingIndex = line.index(after: statusIndex)
                if closingIndex < line.endIndex, line[closingIndex] == "]" {
                    let postClosing = line.index(after: closingIndex)
                    if postClosing < line.endIndex, line[postClosing] == " " {
                        let statusChar = line[statusIndex]
                        if statusChar == " " || statusChar == "x" || statusChar == "X" {
                            task = TaskListState(checked: statusChar == "x" || statusChar == "X")
                            taskMarkerLength = line.distance(from: taskStart, to: line.index(after: postClosing))
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
            taskMarkerLength: taskMarkerLength,
            contentColumn: contentColumn
        )
    }

    /// `maxMarkers` stops after that many `>`; what follows is content.
    /// Whether the line's first `characters` end on a tab stop (a multiple
    /// of four columns). Containers measure tabs from where their part of
    /// the line starts, which agrees with the line's own tab stops only
    /// there; elsewhere a partly consumed tab is not carried into code.
    private func endsOnTabStop(_ characters: Int) -> Bool {
        var column = 0
        for character in lineBuffer.prefix(characters) { column += character == "\t" ? 4 - column % 4 : 1 }
        return column % 4 == 0
    }

    /// Columns of a tab right after a quote's last `>` beyond the one the
    /// marker's optional space takes: indentation of the quoted content
    /// (CommonMark), though the tab itself is part of the prefix.
    private func quoteTabOvershoot(_ line: String, prefixLength: Int) -> Int {
        let prefix = Array(line.prefix(prefixLength))
        guard prefix.count >= 2, prefix[prefix.count - 1] == "\t", prefix[prefix.count - 2] == ">" else { return 0 }
        var column = 0
        for character in prefix.dropLast() { column += character == "\t" ? 4 - column % 4 : 1 }
        return 4 - column % 4 - 1
    }

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

    private func isIndentedCodeBlock(_ context: BlockContext) -> Bool {
        guard case .fencedCode = context.kind else { return false }
        return context.fenceInfo?.isIndented == true
    }

    /// Characters of indentation that make up four columns (a tab advances
    /// to the next multiple of four, counted from `startColumn`, where the
    /// line starts), or `nil` when the line is less indented.
    private func detectIndentedCodePrefix(_ line: String, startColumn: Int = 0) -> Int? {
        indentedCodePrefix(line, startColumn: startColumn, extraColumns: 0)?.characters
    }

    /// Indented code's prefix on `line`, which starts at column
    /// `startColumn`, `extraColumns` past its container's content column
    /// (the rest of a tab the container's prefix only partly consumed): the
    /// characters that make up four columns counted from the content
    /// column, and how far the last of them, a tab, reaches past them. Those
    /// columns are the code's own leading spaces (CommonMark). `nil` when
    /// the line is less indented, or blank.
    private func indentedCodePrefix(_ line: String, startColumn: Int, extraColumns: Int) -> (characters: Int, padding: Int)? {
        guard line.contains(where: { $0 != " " && $0 != "\t" }) else { return nil }
        if extraColumns >= 4 { return (0, extraColumns - 4) }
        var column = extraColumns
        var count = 0
        for character in line {
            guard character == " " || character == "\t" else { break }
            column += character == "\t" ? 4 - (startColumn + column - extraColumns) % 4 : 1
            count += 1
            if column >= 4 { return (count, column - 4) }
        }
        return nil
    }

    private func shouldDeferParagraphFallback(for line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        if trimmed.first == "|" { return true }          // table candidate
        // `<di` may still become `<div>`, which interrupts a paragraph.
        if trimmed.first == "<", htmlBlockStart(line[...], isLineComplete: false, interruptingParagraph: true) == .pending {
            return true
        }
        if trimmed.hasPrefix(":::") { return true }      // unknown block extension fallback
        if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") { return true } // display math
        if trimmed == "$" || trimmed == "\\" { return true } // may become a display-math opener
        if trimmed == ":" || trimmed == "::" { return true } // may become `:::`
        if trimmed.hasPrefix("[") {
            // `[label]:` is a reference definition; until the label closes
            // and the next character is known, the line is ambiguous (the
            // label may also go on to the next line). `[label]: /url` is a
            // definition only if nothing but an optional title follows, so
            // then the whole line decides.
            switch definitionLabel(trimmed[...]) {
            case .open, .closedAtEnd, .colon: return true
            case .notDefinition: return false
            }
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
        guard trimmed.first == "[" else { return false }
        if case .colon = definitionLabel(trimmed) { return true }
        return false
    }

    private enum DefinitionLabel {
        /// The label has not closed yet.
        case open
        /// `[label]` ends the line so far.
        case closedAtEnd
        /// `[label]:`
        case colon
        case notDefinition
    }

    /// How far a line starting with `[` is a definition's label. A label
    /// holds at most 999 characters and no unescaped `[` (CommonMark), which
    /// also bounds the scan while the line is still ambiguous.
    private func definitionLabel(_ trimmed: Substring) -> DefinitionLabel {
        var count = 0
        var cursor = trimmed.index(after: trimmed.startIndex)
        while cursor < trimmed.endIndex {
            let character = trimmed[cursor]
            if character == "]" {
                let after = trimmed.index(after: cursor)
                if after == trimmed.endIndex { return .closedAtEnd }
                return trimmed[after] == ":" ? .colon : .notDefinition
            }
            if character == "[" { return .notDefinition }
            if character == "\\" {
                cursor = trimmed.index(after: cursor)
                count += 1
                if cursor == trimmed.endIndex { return .open }
            }
            count += 1
            if count > 999 { return .notDefinition }
            cursor = trimmed.index(after: cursor)
        }
        return .open
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
        if let first = trimmed.first, "-*+".contains(first),
           trimmed.dropFirst().allSatisfy({ $0 == " " || $0 == "\t" }) {
            return true
        }

        var digits = 0
        var seenDelimiter = false
        for character in trimmed {
            if character.isASCII, character.isNumber, !seenDelimiter {
                digits += 1
                continue
            }
            if character == "." || character == ")", !seenDelimiter, digits > 0 {
                seenDelimiter = true
                continue
            }
            if character == " " || character == "\t", seenDelimiter {
                continue
            }
            return false
        }
        // Digits alone (`1`) may still become a marker; so may a marker with
        // nothing after it yet (`1.`, `1) `).
        return (1...9).contains(digits)
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
        case .fencedCode, .math, .htmlBlock: return true
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

    var isListItem: Bool {
        if case .listItem = self { return true }
        return false
    }
}

/// How a CommonMark HTML block ends, which the kind of line that started it
/// decides.
enum HTMLBlockEnd: Equatable {
    /// Kinds 1 to 5 (`<script>`, `<pre>`, `<style>`, `<textarea>`, comments,
    /// processing instructions, declarations, CDATA): the first line holding
    /// one of these, ASCII case-insensitively, is the block's last. Lowercase.
    case markers([String])
    /// Kinds 6 and 7 (a known block tag, any complete tag alone on its line):
    /// a blank line, which is not part of the block.
    case blankLine

    static let rawTextMarkers = ["</pre>", "</script>", "</style>", "</textarea>"]
    static let longestMarker = 11
}

enum HTMLBlockStart: Equatable {
    case start(HTMLBlockEnd)
    /// The line so far may still start one; more of it decides.
    case pending
    case none
}

private let htmlRawTextNames = ["pre", "script", "style", "textarea"]
/// CommonMark 0.31.2's block-level tag names (kind 6).
private let htmlBlockTagNames: Set<String> = [
    "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
    "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
    "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
    "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
    "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot",
    "th", "thead", "title", "tr", "track", "ul"
]

/// Whether `line`, the line inside its containers, starts an HTML block
/// (CommonMark 4.6): up to three spaces, then `<` and one of seven start
/// conditions. All but kind 7 (a complete tag alone on its line) may
/// interrupt a paragraph, and all but kind 7 are known a few characters
/// after the `<`; kind 7 needs the whole line.
func htmlBlockStart(_ line: Substring, isLineComplete: Bool, interruptingParagraph: Bool) -> HTMLBlockStart {
    let utf8 = line.utf8
    var index = utf8.startIndex
    var spaces = 0
    while index < utf8.endIndex, utf8[index] == 0x20 {
        spaces += 1
        index = utf8.index(after: index)
    }
    guard spaces < 4, index < utf8.endIndex, utf8[index] == 0x3C else { return .none }
    // Kinds 1 to 6 are decided within a few bytes of the `<` (the longest
    // name is ten), so a paragraph's line is not copied whole on every check.
    let rest = utf8[utf8.index(after: index)...]
    let bytes = interruptingParagraph ? Array(rest.prefix(16)) : Array(rest)
    // What running out of text means: the line may still go on.
    let ranOut: HTMLBlockStart = isLineComplete ? .none : .pending
    func isLetter(_ b: UInt8) -> Bool { (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }
    func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }
    /// `true` when the bytes start with `pattern`, `nil` when they end
    /// inside it.
    func starts(with pattern: String) -> Bool? {
        for (offset, byte) in pattern.utf8.enumerated() {
            guard offset < bytes.count else { return nil }
            guard bytes[offset] == byte else { return false }
        }
        return true
    }

    guard let first = bytes.first else { return ranOut }
    if first == 0x3F { return .start(.markers(["?>"])) }
    if first == 0x21 {
        switch starts(with: "!--") {
        case true: return .start(.markers(["-->"]))
        case nil: return ranOut
        default: break
        }
        switch starts(with: "![CDATA[") {
        case true: return .start(.markers(["]]>"]))
        case nil: return ranOut
        default: break
        }
        return isLetter(bytes[1]) ? .start(.markers([">"])) : .none
    }

    let closing = first == 0x2F
    var cursor = closing ? 1 : 0
    guard cursor < bytes.count else { return ranOut }
    guard isLetter(bytes[cursor]) else { return .none }
    let nameStart = cursor
    while cursor < bytes.count, isLetter(bytes[cursor]) || (0x30...0x39).contains(bytes[cursor]) || bytes[cursor] == 0x2D {
        cursor += 1
    }
    let name = String(decoding: bytes[nameStart..<cursor].map { isLetter($0) ? $0 | 0x20 : $0 }, as: UTF8.self)
    if cursor == bytes.count, !isLineComplete {
        // The name may still grow. A lone tag needs the whole line anyway.
        if !interruptingParagraph { return .pending }
        let known = htmlBlockTagNames.contains { $0.hasPrefix(name) }
            || (!closing && htmlRawTextNames.contains { $0.hasPrefix(name) })
        return known ? .pending : .none
    }
    // The byte after the name, `nil` at the end of the line.
    let next = cursor < bytes.count ? bytes[cursor] : nil
    let nameEnds = next.map { isSpace($0) || $0 == 0x3E } ?? true
    if !closing, nameEnds, htmlRawTextNames.contains(name) {
        return .start(.markers(HTMLBlockEnd.rawTextMarkers))
    }
    if htmlBlockTagNames.contains(name) {
        if nameEnds { return .start(.blankLine) }
        if next == 0x2F {
            if cursor + 1 == bytes.count { return ranOut }
            if bytes[cursor + 1] == 0x3E { return .start(.blankLine) }
        }
    }
    // Kind 1 has already taken `<script>` and the like; any other tag of
    // those names (`</script>`, `<pre/>`) is a lone tag, as in cmark-gfm.
    guard !interruptingParagraph else { return .none }
    switch htmlTagFillsLine(bytes, from: cursor, closing: closing) {
    case true: return isLineComplete ? .start(.blankLine) : .pending
    case nil: return ranOut
    default: return .none
    }
}

/// Whether the rest of a tag, after its name at `start`, closes it and
/// only spaces or tabs follow (kind 7): `true`, `false`, or `nil` when the
/// bytes end first. CommonMark's open tag: attributes, each after
/// whitespace, a name with an optional value (unquoted, or in single or
/// double quotes), then optional whitespace, an optional `/`, and `>`. A
/// closing tag has only whitespace before its `>`.
private func htmlTagFillsLine(_ bytes: [UInt8], from start: Int, closing: Bool) -> Bool? {
    func isLetter(_ b: UInt8) -> Bool { (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }
    func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }
    func isNameStart(_ b: UInt8) -> Bool { isLetter(b) || b == 0x5F || b == 0x3A }
    func isNameByte(_ b: UInt8) -> Bool { isNameStart(b) || (0x30...0x39).contains(b) || b == 0x2E || b == 0x2D }
    var cursor = start
    func skipSpaces() -> Int {
        let from = cursor
        while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
        return cursor - from
    }
    while true {
        let spaced = skipSpaces() > 0
        guard cursor < bytes.count else { return nil }
        let b = bytes[cursor]
        if b == 0x3E {
            cursor += 1
            break
        }
        if closing { return false }
        if b == 0x2F {
            guard cursor + 1 < bytes.count else { return nil }
            guard bytes[cursor + 1] == 0x3E else { return false }
            cursor += 2
            break
        }
        guard spaced, isNameStart(b) else { return false }
        while cursor < bytes.count, isNameByte(bytes[cursor]) { cursor += 1 }
        let afterName = cursor
        _ = skipSpaces()
        guard cursor < bytes.count else { return nil }
        guard bytes[cursor] == 0x3D else {
            // No value: the whitespace read is the next attribute's.
            cursor = afterName
            continue
        }
        cursor += 1
        _ = skipSpaces()
        guard cursor < bytes.count else { return nil }
        let quote = bytes[cursor]
        if quote == 0x22 || quote == 0x27 {
            guard let close = bytes[(cursor + 1)...].firstIndex(of: quote) else { return nil }
            cursor = close + 1
        } else {
            let valueStart = cursor
            while cursor < bytes.count, !isSpace(bytes[cursor]), !"\"'=<>`".utf8.contains(bytes[cursor]) { cursor += 1 }
            guard cursor > valueStart else { return false }
        }
    }
    return bytes[cursor...].allSatisfy(isSpace)
}

/// One link reference definition at the start of `text`, which holds whole
/// lines (each ending in a line feed). CommonMark: up to three spaces, a
/// label of at most 999 characters with no unescaped bracket, a colon,
/// optional whitespace with at most one line ending, a destination, and an
/// optional title separated from it by whitespace. Nothing but spaces or tabs
/// may follow on the title's line; when a title on the next line fails that,
/// the definition ends with the destination's line instead. Backslash escapes
/// are resolved in the destination and the title, not in the label.
enum LinkDefinitionParse: Equatable {
    case definition(label: String, url: String, title: String?, end: String.Index)
    /// More lines may still complete it (or decide a title).
    case incomplete
    case invalid
}

/// A definition whose title was still open when its text ran out. All
/// before the title is settled, and a title may run over any number of
/// lines, so the next line resumes the title instead of starting over.
/// Positions are UTF-8 offsets from the definition's start.
struct LinkDefinitionTitleProgress {
    var label: String
    var url: String
    var opening: Unicode.Scalar
    var title: String.UnicodeScalarView
    var endWithoutTitle: Int?
    var cursor: Int
}

/// `progress` resumes a definition at the start of `text` whose title was
/// open, and receives that state when the title is open again.
func parseLinkDefinition(_ text: Substring, isFinal: Bool,
                         progress: inout LinkDefinitionTitleProgress?) -> LinkDefinitionParse {
    let scalars = text.unicodeScalars
    let end = text.endIndex
    let unfinished: LinkDefinitionParse = isFinal ? .invalid : .incomplete
    let punctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars)
    var cursor = text.startIndex
    func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar == " " || scalar == "\t" }
    func advance() { cursor = scalars.index(after: cursor) }
    func skipSpaces() { while cursor < end, isSpace(scalars[cursor]) { advance() } }
    /// Spaces and tabs with at most one line ending among them.
    func skipWhitespace() {
        skipSpaces()
        if cursor < end, scalars[cursor] == "\n" {
            advance()
            skipSpaces()
        }
    }
    /// The escaped character at a backslash, which `cursor` then passes.
    func escaped() -> Unicode.Scalar? {
        let next = scalars.index(after: cursor)
        guard next < end, punctuation.contains(scalars[next]) else { return nil }
        cursor = scalars.index(after: next)
        return scalars[next]
    }
    /// A character reference at `cursor`, appended to `target`.
    func reference(into target: inout String.UnicodeScalarView) -> Bool {
        guard scalars[cursor] == "&", case .reference(let replacement, let referenceEnd) = HTMLEntities.scan(text, at: cursor) else {
            return false
        }
        target.append(contentsOf: replacement.unicodeScalars)
        cursor = referenceEnd
        return true
    }

    func offset(_ index: String.Index) -> Int { text.utf8.distance(from: text.startIndex, to: index) }
    func index(_ offset: Int) -> String.Index { text.utf8.index(text.startIndex, offsetBy: offset) }

    let label: String
    let url: String
    let opening: Unicode.Scalar
    var title = String.UnicodeScalarView()
    var endWithoutTitle: String.Index?
    if let saved = progress {
        progress = nil
        label = saved.label
        url = saved.url
        opening = saved.opening
        title = saved.title
        endWithoutTitle = saved.endWithoutTitle.map(index)
        cursor = index(saved.cursor)
    } else {
        var indent = 0
        while cursor < end, scalars[cursor] == " ", indent < 3 {
            indent += 1
            advance()
        }
        guard cursor < end else { return unfinished }
        guard scalars[cursor] == "[" else { return .invalid }
        advance()
        let labelStart = cursor
        var count = 0
        while true {
            guard cursor < end else { return unfinished }
            let scalar = scalars[cursor]
            if scalar == "]" { break }
            if scalar == "[" { return .invalid }
            if scalar == "\\" {
                advance()
                count += 1
                guard cursor < end else { return unfinished }
            }
            count += 1
            if count > 999 { return .invalid }
            advance()
        }
        let labelText = text[labelStart..<cursor]
        // `[^id]:` is a footnote definition.
        guard !labelText.hasPrefix("^"), labelText.unicodeScalars.contains(where: { !isSpace($0) && $0 != "\n" }) else { return .invalid }
        label = String(labelText)
        advance()
        guard cursor < end else { return unfinished }
        guard scalars[cursor] == ":" else { return .invalid }
        advance()
        skipWhitespace()
        guard cursor < end else { return unfinished }

        var destination = String.UnicodeScalarView()
        if scalars[cursor] == "<" {
            advance()
            while true {
                guard cursor < end else { return unfinished }
                let scalar = scalars[cursor]
                if scalar == ">" { break }
                if scalar == "\n" || scalar == "<" { return .invalid }
                if scalar == "\\", let escaped = escaped() {
                    destination.append(escaped)
                    continue
                }
                if reference(into: &destination) { continue }
                destination.append(scalar)
                advance()
            }
            advance()
        } else {
            var depth = 0
            while cursor < end {
                let scalar = scalars[cursor]
                if scalar == "\\", let escaped = escaped() {
                    destination.append(escaped)
                    continue
                }
                if scalar.value <= 0x20 || scalar.value == 0x7F { break }
                if reference(into: &destination) { continue }
                if scalar == "(" {
                    depth += 1
                    if depth > 32 { return .invalid }
                } else if scalar == ")" {
                    if depth == 0 { return .invalid }
                    depth -= 1
                }
                destination.append(scalar)
                advance()
            }
            guard !destination.isEmpty, depth == 0 else { return .invalid }
        }
        url = String(destination)
        let afterDestination = cursor

        // Without a title the definition ends with the destination's line,
        // provided only spaces or tabs follow it there.
        skipSpaces()
        if cursor == end {
            endWithoutTitle = end
        } else if scalars[cursor] == "\n" {
            endWithoutTitle = scalars.index(after: cursor)
        }

        cursor = afterDestination
        skipWhitespace()
        // The next line has not arrived: it may still hold a title.
        guard cursor < end else {
            guard isFinal, let endWithoutTitle else { return isFinal ? .invalid : .incomplete }
            return .definition(label: label, url: url, title: nil, end: endWithoutTitle)
        }
        opening = scalars[cursor]
        guard cursor > afterDestination, opening == "\"" || opening == "'" || opening == "(" else {
            guard let endWithoutTitle else { return .invalid }
            return .definition(label: label, url: url, title: nil, end: endWithoutTitle)
        }
        advance()
    }
    func withoutTitle() -> LinkDefinitionParse {
        guard let endWithoutTitle else { return .invalid }
        return .definition(label: label, url: url, title: nil, end: endWithoutTitle)
    }
    let closing: Unicode.Scalar = opening == "(" ? ")" : opening
    while true {
        guard cursor < end else {
            guard !isFinal else { return withoutTitle() }
            progress = LinkDefinitionTitleProgress(label: label, url: url, opening: opening, title: title,
                                                   endWithoutTitle: endWithoutTitle.map(offset), cursor: offset(cursor))
            return .incomplete
        }
        let scalar = scalars[cursor]
        if scalar == closing { break }
        if opening == "(", scalar == "(" { return withoutTitle() }
        if scalar == "\\", let escaped = escaped() {
            title.append(escaped)
            continue
        }
        if reference(into: &title) { continue }
        title.append(scalar)
        advance()
    }
    advance()
    skipSpaces()
    if cursor == end {
        return isFinal ? .definition(label: label, url: url, title: String(title), end: end) : .incomplete
    }
    guard scalars[cursor] == "\n" else { return withoutTitle() }
    return .definition(label: label, url: url, title: String(title), end: scalars.index(after: cursor))
}
