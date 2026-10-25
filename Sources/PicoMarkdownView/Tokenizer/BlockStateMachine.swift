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

        var prefixLength: Int { indent + markerLength + taskMarkerLength }
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
    /// Characters at the start of `lineBuffer` that are the enclosing
    /// blockquote's `>` markers (with their optional space). Resolved once
    /// per line by `analyzeQuotedLine`; everything after it is the line as
    /// the quote's children see it.
    private var lineQuotePrefix: Int = 0
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
            lineAnalyzed = true
            return
        }

        if contextStack.contains(where: { $0.kind == .blockquote }),
           analyzeQuotedLine(isLineComplete: isLineComplete) {
            return
        }

        if contextStack.isEmpty {
            if let footnote = detectFootnoteDefinition(lineBuffer) {
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

            if let heading = detectHeading(lineBuffer) {
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
                if let heading = detectHeading(lineBuffer) {
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
                if let list = detectList(lineBuffer, isLineComplete: isLineComplete) {
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
                // A heading at or before the item's marker column breaks out
                // of all open list contexts; one indented past the marker is
                // the item's own content.
                if let heading = detectHeading(lineBuffer), heading.indent <= ctx.listIndent {
                    closeCurrentBlock()
                    closeListContexts(deeperThan: -1)
                    openInlineBlock(kind: .heading(level: heading.level), prefixToStrip: heading.prefixLength)
                    emittedCount = min(lineBuffer.count, heading.prefixLength)
                    lineAnalyzed = true
                    return
                }
                // A fenced code block at column 0 breaks out of all open list contexts.
                if isLineComplete, let fence = detectFenceOpening(lineBuffer) {
                    closeCurrentBlock()
                    closeListContexts(deeperThan: -1)
                    openFencedCode(fence)
                    emittedCount = lineBuffer.count
                    lineAnalyzed = true
                    return
                }
                if let list = detectList(lineBuffer, isLineComplete: isLineComplete) {
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
                        emitHorizontalRuleBlock()
                        return
                    }
                    if continuation > 0 {
                        current.linePrefixToStrip = continuation
                        current.sawBlankInSubContext = false
                        setCurrentBlock(current)
                        if emittedCount < continuation {
                            emittedCount = min(lineBuffer.count, continuation)
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
                        emittedCount = 0
                        lineAnalyzed = true
                        return
                    }
                    setCurrentBlock(current)
                }
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
                break
            case .unknown:
                break
            }
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
        case .blockquote, .paragraph:
            if !isLineComplete, shouldDeferParagraphFallback(for: String(content)) {
                lineDeferredUntilComplete = isDeferredUntilLineEnd(String(content))
                lineAnalyzed = true
                return true
            }
            if openQuotedChild(from: content, isLineComplete: isLineComplete) {
                return true
            }
            if current.kind == .blockquote, current.hasBlockChildren,
               !content.allSatisfy({ $0 == " " || $0 == "\t" }) {
                openInlineBlock(kind: .paragraph, prefixToStrip: quote.prefixLength)
            }
            lineAnalyzed = true
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
            if let current = currentBlock, current.kind == .paragraph {
                closeCurrentBlock()
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
        if let heading = detectHeading(line) {
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
        return false
    }

    /// Whether a line (already stripped of any quote prefix) opens a block
    /// that interrupts a paragraph. Mirrors the openers `openQuotedChild`
    /// knows plus the ones a top-level paragraph yields to.
    private func startsBlock(_ content: Substring, isLineComplete: Bool) -> Bool {
        let line = String(content)
        if detectHeading(line) != nil { return true }
        if detectList(line, isLineComplete: isLineComplete) != nil { return true }
        // `$$x$$` is display math only if nothing follows on the line
        // (`$$x$$y` is a paragraph), so math waits for the complete line
        // like fences, rules and tables.
        guard isLineComplete else { return false }
        return detectDisplayMathOpening(line) != nil || detectFenceOpening(line) != nil
            || detectHorizontalRule(line, indent: 0) || detectTableCandidate(line) || line.hasPrefix(":::")
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
                // A partial line made only of the fence's marker may still
                // become the closing fence; emitting it now would put stray
                // backticks in the code. Likewise a partial math closer.
                if !context.fenceJustOpened, let fence = context.fenceInfo, !fence.isIndented, !trimmedLine.isEmpty {
                    let closing = fence.closingMarker ?? fence.marker
                    if let marker = closing.first, trimmedLine.allSatisfy({ $0 == marker }) { return }
                    if case .math = context.kind, closing.hasPrefix(trimmedLine) { return }
                }
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
        append(delta, context: &context)
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
                    // When a blank line closes a list item, mark the parent
                    // list item (if any) so that non-continuation text on the
                    // next line ends the list instead of being lazily appended.
                    if isBlank, var parent = currentBlock, case .listItem = parent.kind {
                        parent.sawBlankInSubContext = true
                        setCurrentBlock(parent)
                    }
                } else {
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
        emittedLineUTF8Offset = nil
        emittedLineBlockID = nil
        lineAnalyzed = false
        lineQuotePrefix = 0
        lineBufferTrimmed = 0
        lineDeferredUntilComplete = false
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
        switch ctx.kind {
        case .paragraph, .listItem, .blockquote, .footnoteDefinition:
            if var parser = ctx.inlineParser {
                var input = text
                if ctx.kind == .paragraph, ctx.pendingSoftBreak {
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
                var emitted = ""
                var pending = ctx.headingPendingSuffix
                for character in text {
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
        let info = trimmed[index...].trimmingCharacters(in: .whitespaces)
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
//        if let open = makeOpening(open: "\\(", close: "\\)") { return open }

        return nil
    }

    private mutating func emitHorizontalRuleBlock() {
        let blockID = nextID
        nextID &+= 1
        events.append(.blockStart(id: blockID, kind: .horizontalRule))
        events.append(.blockEnd(id: blockID))
        emittedCount = lineBuffer.count
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

    private func detectHeading(_ line: String) -> HeadingInfo? {
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
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
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
        if isPotentialFencePrefixOnly(trimmed) {
            return true
        }
        if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == " " }) {
            return true // could still become horizontal rule on newline
        }
        return false
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
        return content.allSatisfy { $0 == first || $0 == " " }
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

    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }
}
