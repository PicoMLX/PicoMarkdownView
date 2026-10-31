import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct RenderedContentResult {
    var attributed: AttributedString
    var table: RenderedTable?
    var listItem: RenderedListItem?
    var blockquote: RenderedBlockquote?
    var math: RenderedMath?
    var images: [RenderedImage]
    var codeBlock: RenderedCodeBlock?
    var mermaidDiagram: RenderedMermaidDiagram? = nil
    var svgGraphic: RenderedSVGGraphic? = nil
    var vegaLiteChart: RenderedVegaLiteChart? = nil
    var paragraphSpacingAfter: CGFloat? = nil
}

/// Presentation context for macOS paragraph margins. UIKit keeps its existing
/// margin rules; this carries no tokenizer or assembler state.
struct BlockSpacingContext: Sendable, Equatable {
    enum Gap: Sendable, Equatable { case standard, paragraph, listItem, none }
    var previousSpacingAfter: CGFloat?
    var gap: Gap
    var suppressTrailingListSpacing: Bool
}

actor MarkdownAttributeBuilder {
    private let theme: MarkdownRenderTheme
    private let imageProvider: MarkdownImageProvider?
    private let mermaidProvider: (any MermaidDiagramProvider)?
#if os(macOS)
    private let vegaLiteProvider: VegaLiteChartProvider
#endif
    private var runtimeMermaidMaxWidth: CGFloat?
    private let mermaidPreviewTiming: MermaidPreviewTiming

#if canImport(AppKit)
    /// Cached geometry and its successful width must travel together when
    /// an older request returns a drawing produced by a newer resize.
    private struct MermaidVectorPresentation {
        let diagram: MermaidVectorRenderResult
        let maxWidth: CGFloat?
    }

    private struct MermaidPreview {
        var diagram: MermaidVectorPresentation?
        var attemptedBytes = 0
        var attemptedWidth: CGFloat?
        var lastAttempt: ContinuousClock.Instant?
        var generation: UInt64 = 0
        var completedSource: String?
        var previewLimitReached = false
    }

    private var mermaidPreviews: [BlockID: MermaidPreview] = [:]
    private var nextMermaidPreviewGeneration: UInt64 = 0

    func discardMermaidPreviews(for ids: Set<BlockID>) {
        for id in ids { mermaidPreviews[id] = nil }
    }

    private struct CachedTable {
        var sourceHeaders: [[InlineRun]]?
        var alignments: [TableAlignment]?
        var columnCount: Int
        var headers: [AttributedString]?
        var rows: [[AttributedString]] = []
        var images: [RenderedImage] = []
        var imageCounter = 0
    }

    private var tableCache: [BlockID: CachedTable] = [:]
    private var tableRenderVersions: [BlockID: UInt64] = [:]
    private var nextTableRenderVersion: UInt64 = 0

    /// Image availability and available-width changes can alter existing cells.
    /// Ordinary table events only append rows and reuse their rendered prefix.
    func invalidateTableCache(for ids: Set<BlockID>) {
        for id in ids {
            tableCache[id] = nil
            tableRenderVersions[id] = nil
        }
    }
#endif

    // Resolved platform types — created once at init, isolated to this actor.
    private let bodyFont: PlatformFont
    private let codeFont: PlatformFont
    private let headingFonts: [Int: PlatformFont]
    private let blockquoteColor: PlatformColor
    private let linkColor: PlatformColor

    init(theme: MarkdownRenderTheme,
         imageProvider: MarkdownImageProvider? = nil,
         mermaidProvider: (any MermaidDiagramProvider)? = nil,
         runtimeMermaidMaxWidth: CGFloat? = nil,
         mermaidPreviewTiming: MermaidPreviewTiming = .continuous) {
        self.theme = theme
        self.imageProvider = imageProvider
        self.mermaidProvider = mermaidProvider
#if os(macOS)
        self.vegaLiteProvider = VegaLiteChartProvider(theme: theme)
#endif
        self.mermaidPreviewTiming = mermaidPreviewTiming
        self.runtimeMermaidMaxWidth = runtimeMermaidMaxWidth.flatMap { $0 > 0 ? $0 : nil }

        // Resolve Sendable specs to platform types inside the actor
        self.bodyFont = theme.bodyFont.resolved()
        self.codeFont = theme.codeFont.resolved()
        self.blockquoteColor = theme.blockquoteColor.resolved()
        self.linkColor = theme.linkColor.resolved()

        var resolved: [Int: PlatformFont] = [:]
        for (level, spec) in theme.headingFonts {
            resolved[level] = spec.resolved()
        }
        self.headingFonts = resolved
    }

    func setRuntimeMermaidMaxWidth(_ width: CGFloat?) {
        if let width, width > 0 {
            runtimeMermaidMaxWidth = width
        } else {
            runtimeMermaidMaxWidth = nil
        }
    }

    /// Renders one block. `blockquoteLevel` is the number of quotes enclosing
    /// it (its own included for a `.blockquote`); a child of a quote is
    /// rendered as usual and then indented past the bars and tagged with
    /// the quote attributes so the text view draws the bars beside it.
    /// A child of a list item starts at the item's text column,
    /// `listIndent`; the first child of an item without text of its own
    /// carries the item's `listMarker` before that column, and the item,
    /// told so by `markerOnFirstChild`, renders nothing itself. The bars of
    /// a quote inside a list item start at `blockquoteBarInset`.
    func render(snapshot: BlockSnapshot, previousBlockKind: BlockKind? = nil,
                blockquoteLevel: Int = 0, listIndent: CGFloat = 0, listMarker: String? = nil,
                markerOnFirstChild: Bool = false, blockquoteBarInset: CGFloat = 0,
                spacingContext: BlockSpacingContext? = nil) async -> RenderedContentResult {
        var result = await renderContent(snapshot: snapshot, previousBlockKind: previousBlockKind,
                                         blockquoteLevel: blockquoteLevel, markerOnFirstChild: markerOnFirstChild)
#if canImport(AppKit)
        if let spacingContext {
            let spaced = applySpacing(spacingContext, to: result.attributed, previousKind: previousBlockKind)
            result.attributed = spaced.content
            result.paragraphSpacingAfter = spaced.after
        }
#endif
        if listIndent > 0 || listMarker != nil {
            result.attributed = placeInListItem(result.attributed, indent: listIndent, marker: listMarker)
        }
        guard blockquoteLevel > 0 else { return result }

        let content = NSMutableAttributedString(attributedString: .picoConverted(from: result.attributed))
        let range = NSRange(location: 0, length: content.length)
        guard range.length > 0 else { return result }
        if snapshot.kind != .blockquote {
            let gutter = BlockquoteBarMetrics.textIndent(level: blockquoteLevel)
            content.enumerateAttribute(.paragraphStyle, in: range) { value, paragraphRange, _ in
                let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent += gutter
                paragraph.headIndent += gutter
                content.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
            }
            content.addAttributes([
                .picoBlockquoteLevel: blockquoteLevel,
                .picoBlockquoteBarColor: blockquoteColor.withAlphaComponent(0.6)
            ], range: range)
        }
        // A quote inside a list item draws its bars at the item's text column.
        if blockquoteBarInset > 0 {
            content.addAttribute(.picoBlockquoteBarInset, value: blockquoteBarInset, range: range)
        }
        result.attributed = .picoConverted(from: content)
        return result
    }

#if canImport(AppKit)
    private func applySpacing(_ context: BlockSpacingContext, to attributed: AttributedString,
                              previousKind: BlockKind?) -> (content: AttributedString, after: CGFloat?) {
        let content = NSMutableAttributedString(attributedString: .picoConverted(from: attributed))
        guard content.length > 0 else { return (attributed, nil) }
        let firstRange = (content.string as NSString).paragraphRange(for: NSRange(location: 0, length: 1))
        let first = (content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        if let previousAfter = context.previousSpacingAfter {
            let desiredGap: CGFloat
            switch context.gap {
            case .paragraph: desiredGap = bodyFont.pointSize
            case .listItem: desiredGap = bodyFont.pointSize * 0.25
            case .none: desiredGap = 0
            case .standard:
                // Preserve the block's own margin, compensating for the
                // visible predecessor's actual trailing space.
                desiredGap = (previousKind.map { margins(for: $0).bottomMargin } ?? 0) + first.paragraphSpacingBefore
            }
            first.paragraphSpacingBefore = max(0, desiredGap - previousAfter)
        } else if context.gap != .standard {
            first.paragraphSpacingBefore = 0
        }
        content.addAttribute(.paragraphStyle, value: first, range: firstRange)
        if context.suppressTrailingListSpacing {
            let lastRange = (content.string as NSString).paragraphRange(for: NSRange(location: content.length - 1, length: 1))
            let last = (content.attribute(.paragraphStyle, at: content.length - 1, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            last.paragraphSpacing = 0
            content.addAttribute(.paragraphStyle, value: last, range: lastRange)
        }
        let after = (content.attribute(.paragraphStyle, at: content.length - 1, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing
        return (.picoConverted(from: content), after)
    }
#endif

    private func placeInListItem(_ attributed: AttributedString, indent: CGFloat, marker: String?) -> AttributedString {
        let content = NSMutableAttributedString(attributedString: .picoConverted(from: attributed))
        guard content.length > 0 else { return attributed }
        content.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: content.length)) { value, paragraphRange, _ in
            let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent += indent
            paragraph.headIndent += indent
            content.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
        }
        if let marker {
            // The marker hangs before the text column, as on an item's own
            // first line.
            let prefix = marker + " "
            let first = (content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            first.firstLineHeadIndent = max(0, first.headIndent - bulletPrefixWidth(for: prefix, font: bodyFont))
            content.insert(NSAttributedString(string: prefix, attributes: [
                .font: bodyFont,
                .foregroundColor: PlatformColor.rendererLabel
            ]), at: 0)
            let firstParagraph = (content.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            content.addAttribute(.paragraphStyle, value: first, range: firstParagraph)
        }
        return .picoConverted(from: content)
    }

    private func renderContent(snapshot: BlockSnapshot, previousBlockKind: BlockKind?,
                               blockquoteLevel: Int, markerOnFirstChild: Bool) async -> RenderedContentResult {
        switch snapshot.kind {
        case .table:
#if canImport(AppKit)
            let (fallback, table, images) = await renderTable(snapshot, font: bodyFont,
                                                             previousBlockKind: previousBlockKind)
#else
            let (fallback, table, images) = await renderTable(snapshot, font: bodyFont)
#endif
            return RenderedContentResult(attributed: AttributedString(fallback),
                                        table: table,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: images,
                                        codeBlock: nil)
        case .listItem(let ordered, let index, let task):
            return await renderListItem(snapshot: snapshot, ordered: ordered, index: index, task: task,
                                        previousBlockKind: previousBlockKind,
                                        listDepth: max(0, snapshot.depth - blockquoteLevel),
                                        markerOnFirstChild: markerOnFirstChild)
        case .blockquote:
            return await renderBlockquote(snapshot: snapshot, previousBlockKind: previousBlockKind,
                                          level: max(1, blockquoteLevel))
        case .fencedCode:
#if os(macOS)
            if let chart = await renderVegaLiteFenceIfAvailable(snapshot: snapshot, previousBlockKind: previousBlockKind) {
                return chart
            }
            if let graphic = SVGDiagramSupport.graphic(for: snapshot, enabled: theme.svgRenderingEnabled,
                                                       maxWidth: theme.imageMaxWidth), !graphic.isClosed {
                // Reserve one stable attachment while source streams. Raw SVG
                // stays in metadata for copying, without repeatedly highlighting
                // it or decoding incomplete SVG documents.
                let content = NSMutableAttributedString(string: "\u{FFFC}\n", attributes: [
                    .font: bodyFont,
                    .paragraphStyle: makeParagraphStyle(collapsedSpacing(for: snapshot.kind,
                                                                        previousKind: previousBlockKind))
                ])
                return RenderedContentResult(attributed: .picoConverted(from: content),
                    table: nil, listItem: nil, blockquote: nil, math: nil, images: [],
                    codeBlock: RenderedCodeBlock(code: graphic.source, language: graphic.language),
                    svgGraphic: graphic)
            }
#endif
            if let mermaid = await renderMermaidFenceIfAvailable(snapshot: snapshot, previousBlockKind: previousBlockKind) {
                return mermaid
            }
            let text = snapshot.codeText ?? ""
            let codeBlockSpacing = collapsedSpacing(for: snapshot.kind, previousKind: previousBlockKind)
            let content: NSMutableAttributedString
            if let codeTheme = theme.codeBlockTheme {
                let resolvedCodeFont = codeTheme.resolvedFont()
                let resolvedFg = codeTheme.resolvedForegroundColor()
                let resolvedBg = codeTheme.resolvedBackgroundColor()
                let hasBackground = codeTheme.backgroundColor != .clear

                if CodeHighlightingPolicy.shouldBypassHighlighting(byteCount: text.utf8.count,
                                                                   isClosed: snapshot.isClosed) {
                    // Every appended chunk re-renders the whole block, so
                    // highlighting an unbounded open block would be O(block²)
                    // over the stream. Small blocks highlight live (bounded
                    // per-chunk cost, LRU-cached); past the threshold, render
                    // base attributes now — the fence-close diff refreshes the
                    // block for one full highlight pass.
                    content = NSMutableAttributedString(string: text, attributes: [
                        .font: resolvedCodeFont,
                        .foregroundColor: resolvedFg
                    ])
                } else {
                    let highlighter = theme.codeHighlighter ?? AnyCodeSyntaxHighlighter(PlainCodeSyntaxHighlighter())
                    let highlighted = await highlighter.highlight(text, language: {
                        if case let .fencedCode(value) = snapshot.kind {
                            return value
                        }
                        return nil
                    }(), theme: codeTheme)
                    content = NSMutableAttributedString(highlighted)
                }

                if content.length > 0 {
                    applyCodeBlockParagraphStyles(to: content, spacing: codeBlockSpacing)
                    if hasBackground {
                        content.addAttribute(.backgroundColor, value: resolvedBg, range: NSRange(location: 0, length: content.length))
                    }
                }

                let suffixParagraphStyle = makeCodeParagraphStyle(
                    lineHeightMultiple: codeBlockSpacing.lineHeightMultiple,
                    spacingBefore: content.length == 0 ? codeBlockSpacing.spacingBefore : 0,
                    spacingAfter: codeBlockSpacing.spacingAfter
                )
                var suffixAttrs: [NSAttributedString.Key: Any] = [
                    .font: resolvedCodeFont,
                    .paragraphStyle: suffixParagraphStyle
                ]
                suffixAttrs[.foregroundColor] = resolvedFg
                if hasBackground {
                    suffixAttrs[.backgroundColor] = resolvedBg
                }
                content.append(NSAttributedString(string: "\n", attributes: suffixAttrs))
            } else {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: codeFont,
                    .foregroundColor: PlatformColor.rendererLabel
                ]
                content = NSMutableAttributedString(string: text, attributes: attributes)
                if content.length > 0 {
                    applyCodeBlockParagraphStyles(to: content, spacing: codeBlockSpacing)
                }
                let suffixParagraphStyle = makeCodeParagraphStyle(
                    lineHeightMultiple: codeBlockSpacing.lineHeightMultiple,
                    spacingBefore: content.length == 0 ? codeBlockSpacing.spacingBefore : 0,
                    spacingAfter: codeBlockSpacing.spacingAfter
                )
                let suffixAttrs: [NSAttributedString.Key: Any] = [
                    .font: codeFont,
                    .foregroundColor: PlatformColor.rendererLabel,
                    .paragraphStyle: suffixParagraphStyle
                ]
                content.append(NSAttributedString(string: "\n", attributes: suffixAttrs))
            }
            let language: String?
            if case let .fencedCode(value) = snapshot.kind {
                language = value
            } else {
                language = nil
            }
            return RenderedContentResult(attributed: AttributedString(content),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: [],
                                        codeBlock: RenderedCodeBlock(code: text, language: language),
                                        svgGraphic: SVGDiagramSupport.graphic(for: snapshot, enabled: theme.svgRenderingEnabled,
                                                                              maxWidth: theme.imageMaxWidth))
        case .horizontalRule:
            let content = renderHorizontalRule()
            return RenderedContentResult(attributed: AttributedString(content),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: [],
                                        codeBlock: nil)
        case .heading(let level):
            let font = headingFonts[level] ?? headingFonts[headingFonts.keys.sorted().last ?? 1] ?? bodyFont
            let spacing = headingParagraphSpacing(for: level, previousKind: previousBlockKind)
            let (ns, images) = await renderInlineBlock(snapshot,
                                                prefix: nil,
                                                suffix: "\n",
                                                font: font,
                                                spacing: spacing)
            return RenderedContentResult(attributed: AttributedString(ns),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: images,
                                        codeBlock: nil)
        case .paragraph:
            let suffix = "\n"
            let spacing = paragraphSpacing(previousKind: previousBlockKind)
            let (ns, images) = await renderInlineBlock(snapshot,
                                                prefix: nil,
                                                suffix: suffix,
                                                font: bodyFont,
                                                spacing: spacing)
            return RenderedContentResult(attributed: AttributedString(ns),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: images,
                                        codeBlock: nil)
        case .footnoteDefinition(_, let index):
            let prefixText = "[\(index)] "
            let suffix = "\n"
            let spacing = collapsedSpacing(for: snapshot.kind, previousKind: previousBlockKind)
            let (ns, images) = await renderInlineBlock(snapshot,
                                                prefix: prefixText,
                                                suffix: suffix,
                                                font: bodyFont,
                                                spacing: spacing)
            return RenderedContentResult(attributed: AttributedString(ns),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: images,
                                        codeBlock: nil)
        case .htmlBlock:
            // Raw HTML is not rendered: its text is shown as typed, in the
            // body font, line breaks kept.
            var plain = snapshot
            let text = snapshot.codeText ?? ""
            plain.inlineRuns = [InlineRun(text: text.hasSuffix("\n") ? String(text.dropLast()) : text)]
            let spacing = collapsedSpacing(for: .htmlBlock, previousKind: previousBlockKind)
            let (ns, _) = await renderInlineBlock(plain,
                                                  prefix: nil,
                                                  suffix: "\n",
                                                  font: bodyFont,
                                                  spacing: spacing)
            return RenderedContentResult(attributed: AttributedString(ns),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: [],
                                        codeBlock: nil)
        case .unknown:
            let suffix = "\n"
            let spacing = collapsedSpacing(for: .unknown, previousKind: previousBlockKind)
            let (ns, images) = await renderInlineBlock(snapshot,
                                                prefix: nil,
                                                suffix: suffix,
                                                font: bodyFont,
                                                spacing: spacing)
            return RenderedContentResult(attributed: AttributedString(ns),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: images,
                                        codeBlock: nil)
        case .math(let display):
            let tex = snapshot.mathText ?? snapshot.inlineRuns?.map { $0.text }.joined() ?? ""
            
            // Render math using InlineMathAttachment (same approach as inline math)
            let mathNS = InlineMathAttachment.mathString(tex: tex,
                                                        display: display,
                                                        baseFont: bodyFont)
            let result = NSMutableAttributedString(attributedString: mathNS)
            
            let suffix = display ? "\n" : ""
            let mathSpacing = makeParagraphStyle(collapsedSpacing(for: snapshot.kind, previousKind: previousBlockKind))
            let suffixAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .paragraphStyle: mathSpacing]
            result.append(NSAttributedString(string: suffix, attributes: suffixAttrs))
            
            return RenderedContentResult(attributed: AttributedString(result),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: RenderedMath(tex: tex,
                                                           display: display,
                                                           fontSize: bodyFont.pointSize),
                                        images: [],
                                        codeBlock: nil)
        }
    }

    private func renderHorizontalRule() -> NSAttributedString {
        _ = paragraphSpacing()

        #if !canImport(AppKit)
        // UIKit has no NSTextTable, so a border-drawn hairline is not
        // available. Approximate the rule with connecting box-drawing glyphs
        // in the secondary label color.
        let ruleParagraph = NSMutableParagraphStyle()
        ruleParagraph.alignment = .left
        ruleParagraph.lineBreakMode = .byClipping
        ruleParagraph.paragraphSpacing = 20
        ruleParagraph.paragraphSpacingBefore = 20
        return NSAttributedString(string: String(repeating: "\u{2500}", count: 32) + "\n", attributes: [
            .paragraphStyle: ruleParagraph,
            .font: bodyFont,
            .foregroundColor: PlatformColor.rendererSecondaryLabel
        ])
        #else
        let ruleParagraph = NSMutableParagraphStyle()
        ruleParagraph.paragraphSpacing = 20
        ruleParagraph.paragraphSpacingBefore = 20
        let result = NSMutableAttributedString(attachment: MacHorizontalRuleAttachment())
        result.addAttributes([.paragraphStyle: ruleParagraph, .font: bodyFont],
                             range: NSRange(location: 0, length: result.length))
        result.append(NSAttributedString(string: "\n", attributes: [
            .paragraphStyle: ruleParagraph, .font: bodyFont
        ]))
        return result
        #endif
    }

    private func renderInlineBlock(_ snapshot: BlockSnapshot,
                                   prefix: String?,
                                   suffix: String,
                                   font: PlatformFont,
                                   spacing: ParagraphSpacing) async -> (NSAttributedString, [RenderedImage]) {
        var imageIndex = 0
        let result = NSMutableAttributedString()
        if let prefix {
            result.append(NSAttributedString(string: prefix, attributes: [.font: font]))
        }
        let bodyRuns = sanitizeInlineRuns(snapshot.inlineRuns ?? [], kind: snapshot.kind)
        let inlineImages = collectImages(from: bodyRuns, blockID: snapshot.id, counter: &imageIndex)
        let body = await renderInline(bodyRuns, font: font)
        result.append(body)
        let paragraph = makeParagraphStyle(spacing)
        if result.length > 0 {
            result.addAttributes([.paragraphStyle: paragraph], range: NSRange(location: 0, length: result.length))
        }
        let suffixAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]
        result.append(NSAttributedString(string: suffix, attributes: suffixAttributes))
        return (result, inlineImages)
    }

    private func collectImages(from runs: [InlineRun],
                               blockID: BlockID,
                               counter: inout Int) -> [RenderedImage] {
        guard !runs.isEmpty else { return [] }
        var images: [RenderedImage] = []
        for run in runs {
            guard let image = run.image else { continue }
            let id = RenderedImage.Identifier.make(blockID: blockID, index: counter)
            counter += 1
            let url = URL(string: image.source)
            images.append(RenderedImage(id: id,
                                        source: image.source,
                                        url: url,
                                        altText: run.text,
                                        title: image.title))
        }
        return images
    }

    private func renderInline(_ runs: [InlineRun], font: PlatformFont) async -> NSMutableAttributedString {
        let reduced = NSMutableAttributedString()
        for run in runs {
            let fragment = await render(run: run, baseFont: font)
            reduced.append(fragment)
        }
        return reduced
    }

    private func renderListItem(snapshot: BlockSnapshot,
                                ordered: Bool,
                                index: Int?,
                                task: TaskListState?,
                                previousBlockKind: BlockKind?,
                                listDepth: Int,
                                markerOnFirstChild: Bool) async -> RenderedContentResult {
        let bulletText: String
        if let task {
            bulletText = task.checked ? "☑︎" : "☐"
        } else if ordered {
            let number = index ?? 1
            bulletText = "\(number)."
        } else {
            bulletText = "•"
        }

        var imageIndex = 0
        let runs = sanitizeInlineRuns(snapshot.inlineRuns ?? [], kind: snapshot.kind)
        let inlineImages = collectImages(from: runs, blockID: snapshot.id, counter: &imageIndex)
        let body = await renderInline(runs, font: bodyFont)
        trimLeadingWhitespace(in: body)
        // A finalized list line stores a trailing "\n" run. It normally
        // coalesces into the plain text and is sanitized to a space, but when
        // the item ends in a styled span (inline code, bold, link) the runs
        // can't merge and the bare "\n" survives — combined with the "\n"
        // terminator appended below it rendered as an empty paragraph
        // (a full blank line between bullets). Trim it here.
        trimTrailingNewlines(in: body)

        let bulletPrefix = bulletText + " "
        let rendered = NSMutableAttributedString(string: bulletPrefix, attributes: [.font: bodyFont])
        rendered.append(body)

        // Spacing via margin collapsing
        var listSpacing = collapsedSpacing(for: snapshot.kind, previousKind: previousBlockKind)
#if !canImport(AppKit)
        if listDepth > 0 {
            listSpacing.spacingAfter = max(0, listSpacing.spacingAfter - 2)
        }
#endif
        let listParagraph = makeParagraphStyle(listSpacing)

        // Measure the actual bullet width
        let bulletWidth = bulletPrefixWidth(for: bulletPrefix, font: bodyFont)

        // Reserve minimum width so all items in the list align.
        // For ordered lists, compute based on digit count of the current index
        // to handle "1." through "999." consistently at each magnitude.
        let minReservedWidth: CGFloat
        if ordered {
            minReservedWidth = orderedBulletMinWidth(for: index ?? 1, font: bodyFont)
        } else if task != nil {
            // Task list checkboxes are uniform width
            minReservedWidth = bulletWidth
        } else {
            minReservedWidth = 0
        }

        let bulletTextGap: CGFloat = 12
        let nestingIndent: CGFloat = CGFloat(listDepth) * 20

        // Final column where ALL wrapped lines start
        let headIndent = nestingIndent + max(bulletWidth, minReservedWidth) + bulletTextGap
        listParagraph.firstLineHeadIndent = headIndent - bulletWidth
        listParagraph.headIndent = headIndent

        let metadata = RenderedListItem(bullet: bulletText,
                                        content: AttributedString(body),
                                        ordered: ordered,
                                        index: index,
                                        task: task,
                                        textIndent: headIndent)
        // Without text of its own, the item's marker goes on its first
        // child's line instead of a line of its own.
        if markerOnFirstChild, body.length == 0 {
            return RenderedContentResult(attributed: AttributedString(),
                                         table: nil,
                                         listItem: metadata,
                                         blockquote: nil,
                                         math: nil,
                                         images: inlineImages,
                                         codeBlock: nil)
        }

        rendered.addAttributes([.paragraphStyle: listParagraph],
                               range: NSRange(location: 0, length: rendered.length))

        // Apply the SAME paragraph style to the terminating "\n" as to the body,
        // mirroring renderInlineBlock. A paragraph's trailing paragraphSpacing is
        // resolved from its terminating character's style, so reusing listParagraph
        // here makes the inter-item gap honor the margin system instead of a
        // separate, hardcoded gap on the terminating character.
        rendered.append(NSAttributedString(string: "\n",
                                           attributes: [.font: bodyFont,
                                                        .paragraphStyle: listParagraph]))

        return RenderedContentResult(attributed: AttributedString(rendered),
                                     table: nil,
                                     listItem: metadata,
                                     blockquote: nil,
                                     math: nil,
                                     images: inlineImages,
                                     codeBlock: nil)
    }

    private func bulletPrefixWidth(for bullet: String, font: PlatformFont) -> CGFloat {
        let ns = bullet as NSString
        let size = ns.size(withAttributes: [.font: font])
        // Add a tiny extra padding so wrapped lines don't collide with the bullet
        return ceil(size.width)
    }

    /// Compute minimum bullet width for ordered lists based on the magnitude of the index.
    /// All items in the same digit range (1-9, 10-99, 100-999) get the same reserved width.
    private func orderedBulletMinWidth(for index: Int, font: PlatformFont) -> CGFloat {
        let digits = max(1, String(max(index, 1)).count)
        let sample = String(repeating: "0", count: digits) + ". " as NSString
        let size = sample.size(withAttributes: [.font: font])
        return ceil(size.width)
    }

    private struct ParagraphSpacing {
        var lineHeightMultiple: CGFloat
        var spacingBefore: CGFloat
        var spacingAfter: CGFloat
    }

    // MARK: - Block Margin System (CSS-style collapsing)

    /// Desired margins for a block kind. Adjacent blocks collapse:
    /// the gap between A and B = max(A.bottomMargin, B.topMargin).
    private struct BlockMargins {
        var topMargin: CGFloat
        var bottomMargin: CGFloat
        var lineHeightMultiple: CGFloat
    }

    private func margins(for kind: BlockKind) -> BlockMargins {
        switch kind {
        case .heading(let level):
            switch level {
            case 1:  return BlockMargins(topMargin: 24, bottomMargin: 10, lineHeightMultiple: 1.18)
            case 2:  return BlockMargins(topMargin: 20, bottomMargin: 10, lineHeightMultiple: 1.16)
            case 3:  return BlockMargins(topMargin: 16, bottomMargin: 6, lineHeightMultiple: 1.14)
            default: return BlockMargins(topMargin: 12, bottomMargin: 6, lineHeightMultiple: 1.12)
            }
        case .paragraph:
#if canImport(AppKit)
            return BlockMargins(topMargin: 0, bottomMargin: bodyFont.pointSize, lineHeightMultiple: 1.24)
#else
            return BlockMargins(topMargin: 0, bottomMargin: 12, lineHeightMultiple: 1.24)
#endif
        case .fencedCode:
            return BlockMargins(topMargin: 12, bottomMargin: 12, lineHeightMultiple: 1.24)
        case .blockquote:
            return BlockMargins(topMargin: 8, bottomMargin: 8, lineHeightMultiple: 1.24)
        case .listItem:
#if canImport(AppKit)
            return BlockMargins(topMargin: 0, bottomMargin: bodyFont.pointSize * 0.25, lineHeightMultiple: 1.24)
#else
            return BlockMargins(topMargin: 0, bottomMargin: 2, lineHeightMultiple: 1.24)
#endif
        case .horizontalRule:
            return BlockMargins(topMargin: 20, bottomMargin: 20, lineHeightMultiple: 1.0)
        case .table:
            return BlockMargins(topMargin: 8, bottomMargin: 8, lineHeightMultiple: 1.24)
        case .math(let display):
            if display {
                return BlockMargins(topMargin: 8, bottomMargin: 12, lineHeightMultiple: 1.24)
            }
            return BlockMargins(topMargin: 0, bottomMargin: 0, lineHeightMultiple: 1.24)
        case .footnoteDefinition:
            return BlockMargins(topMargin: 0, bottomMargin: 12, lineHeightMultiple: 1.24)
        case .htmlBlock, .unknown:
            return BlockMargins(topMargin: 0, bottomMargin: 12, lineHeightMultiple: 1.24)
        }
    }

    /// Compute collapsed spacing between the current block and its predecessor.
    /// If `previousKind` is nil (first block), uses the block's own top margin.
    private func collapsedSpacing(for kind: BlockKind, previousKind: BlockKind?) -> ParagraphSpacing {
        let current = margins(for: kind)
        let spacingBefore: CGFloat

        if let previousKind {
            let previous = margins(for: previousKind)
            // CSS-style margin collapsing: desired gap = max(prev.bottom, current.top)
            // prev.bottom is already applied as prev's paragraphSpacing.
            // So current.spacingBefore = max(0, desired_gap - prev.bottom)
            let desiredGap = max(previous.bottomMargin, current.topMargin)
            spacingBefore = max(0, desiredGap - previous.bottomMargin)
        } else {
            spacingBefore = current.topMargin
        }

        return ParagraphSpacing(lineHeightMultiple: current.lineHeightMultiple,
                                spacingBefore: spacingBefore,
                                spacingAfter: current.bottomMargin)
    }

    private func paragraphSpacing(previousKind: BlockKind? = nil) -> ParagraphSpacing {
        collapsedSpacing(for: .paragraph, previousKind: previousKind)
    }

    private func headingParagraphSpacing(for level: Int, previousKind: BlockKind? = nil) -> ParagraphSpacing {
        collapsedSpacing(for: .heading(level: level), previousKind: previousKind)
    }

    private func makeParagraphStyle(_ spacing: ParagraphSpacing) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineHeightMultiple = spacing.lineHeightMultiple
        style.paragraphSpacingBefore = spacing.spacingBefore
        style.paragraphSpacing = spacing.spacingAfter
        style.headIndent = 0
        style.firstLineHeadIndent = 0
        return style
    }

    private func makeCodeParagraphStyle(lineHeightMultiple: CGFloat,
                                        spacingBefore: CGFloat,
                                        spacingAfter: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.headIndent = 0
        style.firstLineHeadIndent = 0
        return style
    }

    private func applyCodeBlockParagraphStyles(to content: NSMutableAttributedString,
                                               spacing: ParagraphSpacing) {
        guard content.length > 0 else { return }

        let innerStyle = makeCodeParagraphStyle(lineHeightMultiple: spacing.lineHeightMultiple,
                                                spacingBefore: 0,
                                                spacingAfter: 0)
        content.addAttribute(.paragraphStyle,
                             value: innerStyle,
                             range: NSRange(location: 0, length: content.length))

        let firstParagraphRange = (content.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let firstParagraphStyle = makeCodeParagraphStyle(lineHeightMultiple: spacing.lineHeightMultiple,
                                                         spacingBefore: spacing.spacingBefore,
                                                         spacingAfter: 0)
        content.addAttribute(.paragraphStyle,
                             value: firstParagraphStyle,
                             range: firstParagraphRange)
    }

#if os(macOS)
    private func renderVegaLiteFenceIfAvailable(snapshot: BlockSnapshot,
                                               previousBlockKind: BlockKind?) async -> RenderedContentResult? {
        guard theme.vegaLiteRenderingEnabled,
              case let .fencedCode(language) = snapshot.kind, isVegaLiteLanguage(language) else { return nil }
        let source = snapshot.codeText ?? ""
        if !snapshot.isClosed {
            // Append-only source remains in metadata. The native document keeps
            // one marker instead of highlighting and laying out JSON prefixes.
            return vegaLiteMarker(snapshot: snapshot, source: source, language: language,
                                  svg: "", size: .zero, width: effectiveAttachmentMaxWidth(),
                                  previousBlockKind: previousBlockKind)
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        while !Task.isCancelled {
            let width = effectiveAttachmentMaxWidth()
            let chart = await vegaLiteProvider.render(source: source, targetWidth: width)
            // A resize can arrive while compilation is suspended. Geometry and
            // its width cap must belong to the same accepted presentation.
            guard width == effectiveAttachmentMaxWidth() else { continue }
            guard !Task.isCancelled, let chart else { return nil }
            return vegaLiteMarker(snapshot: snapshot, source: source, language: language,
                                  svg: chart.svg, size: chart.intrinsicSize, width: width,
                                  previousBlockKind: previousBlockKind)
        }
        return nil
    }

    private func vegaLiteMarker(snapshot: BlockSnapshot, source: String, language: String?,
                                svg: String, size: CGSize, width: CGFloat?,
                                previousBlockKind: BlockKind?) -> RenderedContentResult {
        let result = NSMutableAttributedString(string: "\u{FFFC}\n", attributes: [
            .font: bodyFont,
            .paragraphStyle: makeParagraphStyle(collapsedSpacing(for: snapshot.kind,
                                                                previousKind: previousBlockKind))
        ])
        return RenderedContentResult(attributed: .picoConverted(from: result),
                                     table: nil, listItem: nil, blockquote: nil, math: nil, images: [],
                                     codeBlock: RenderedCodeBlock(code: source, language: language),
                                     vegaLiteChart: RenderedVegaLiteChart(source: source, language: language,
                                                                        svg: svg, intrinsicSize: size, maxWidth: width))
    }

#endif

    private func renderMermaidFenceIfAvailable(snapshot: BlockSnapshot,
                                               previousBlockKind: BlockKind?) async -> RenderedContentResult? {
        guard theme.mermaidRenderingMode.isEnabled else { return nil }
        guard let provider = mermaidProvider else { return nil }
        guard case let .fencedCode(language) = snapshot.kind, isMermaidLanguage(language) else { return nil }

        let source = snapshot.codeText ?? ""
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let mermaidMaxWidth = effectiveMermaidMaxWidth()
#if canImport(AppKit)
        if let vectorProvider = provider as? any MermaidVectorDiagramProvider {
            guard let presentation = await vectorDiagram(snapshot: snapshot, source: source,
                                                         provider: vectorProvider, width: mermaidMaxWidth) else { return nil }
            let diagram = presentation.diagram
            // A stable marker retains native paragraph/list/quote placement.
            // The main-actor backend supplies the actual view attachment.
            let result = NSMutableAttributedString(string: "\u{FFFC}\n", attributes: [
                .font: bodyFont,
                .paragraphStyle: makeParagraphStyle(collapsedSpacing(for: snapshot.kind,
                                                                    previousKind: previousBlockKind))
            ])
            return RenderedContentResult(attributed: .picoConverted(from: result),
                                         table: nil, listItem: nil, blockquote: nil, math: nil, images: [],
                                         codeBlock: RenderedCodeBlock(code: source, language: language),
                                         mermaidDiagram: RenderedMermaidDiagram(source: source,
                                                                              size: diagram.intrinsicSize,
                                                                              diagnostics: diagram.diagnostics,
                                                                              svg: diagram.svg,
                                                                              maxWidth: presentation.maxWidth))
        }
#endif
        guard snapshot.isClosed else { return nil }
        let request = MermaidRenderRequest(source: source,
                                           targetWidth: mermaidMaxWidth,
                                           scale: await mermaidRenderScale())
        guard let diagram = await provider.render(request) else {
            return nil
        }

        let attachment = NSTextAttachment()
        attachment.image = diagram.image
        let targetSize = constrainImageSize(diagram.intrinsicSize, maxWidth: mermaidMaxWidth)
        attachment.bounds = CGRect(origin: .zero, size: targetSize)

        let spacing = collapsedSpacing(for: snapshot.kind, previousKind: previousBlockKind)
        let result = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        let suffixAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont
        ]
        result.append(NSAttributedString(string: "\n", attributes: suffixAttributes))
        if result.length > 0 {
            result.addAttribute(.paragraphStyle,
                                value: makeParagraphStyle(spacing),
                                range: NSRange(location: 0, length: result.length))
        }

        return RenderedContentResult(attributed: AttributedString(result),
                                     table: nil,
                                     listItem: nil,
                                     blockquote: nil,
                                     math: nil,
                                     images: [],
                                     codeBlock: RenderedCodeBlock(code: source, language: language),
                                     mermaidDiagram: RenderedMermaidDiagram(source: source,
                                                                          size: targetSize,
                                                                          diagnostics: diagram.diagnostics))
    }

#if canImport(AppKit)
    /// Pele lays out the whole diagram, so previews are bounded and coalesced
    /// at completed lines. Markdown tokenization and surrounding blocks stay
    /// incremental; an invalid tail keeps the last successful drawing.
    private func vectorDiagram(snapshot: BlockSnapshot, source: String,
                               provider: any MermaidVectorDiagramProvider,
                               width: CGFloat?) async -> MermaidVectorPresentation? {
        let previous = mermaidPreviews[snapshot.id]
        var preview = previous ?? MermaidPreview()
        let candidate: String
        if snapshot.isClosed {
            if preview.completedSource == source, preview.attemptedWidth == width { return preview.diagram }
            candidate = source
        } else {
            guard case .bestEffortDebounced(let milliseconds) = theme.mermaidRenderingMode else { return nil }
            guard !preview.previewLimitReached else { return preview.diagram }
            guard source.utf8.count <= 8_192 else {
                preview.previewLimitReached = true
                mermaidPreviews[snapshot.id] = preview
                return preview.diagram
            }
            if width == preview.attemptedWidth, let lastAttempt = preview.lastAttempt,
               lastAttempt.duration(to: mermaidPreviewTiming.now()) < .milliseconds(max(0, milliseconds)) {
                return preview.diagram
            }
            guard let lastNewline = source.lastIndex(of: "\n") else { return preview.diagram }
            let prefix = source[...lastNewline]
            let bytes = prefix.utf8.count
            guard bytes != preview.attemptedBytes || width != preview.attemptedWidth else { return preview.diagram }
            candidate = String(prefix)
            let lines = candidate.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count <= 257 else {
                preview.previewLimitReached = true
                mermaidPreviews[snapshot.id] = preview
                return preview.diagram
            }
            guard lines.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count > 1 else {
                return preview.diagram
            }
        }

        nextMermaidPreviewGeneration &+= 1
        preview.generation = nextMermaidPreviewGeneration
        preview.attemptedBytes = candidate.utf8.count
        preview.attemptedWidth = width
        preview.lastAttempt = mermaidPreviewTiming.now()
        mermaidPreviews[snapshot.id] = preview
        let generation = preview.generation
        let rendered = await provider.renderVector(MermaidRenderRequest(source: candidate, targetWidth: width,
                                                                        scale: 1, isPreview: !snapshot.isClosed))
        guard let current = mermaidPreviews[snapshot.id], current.generation == generation else {
            return mermaidPreviews[snapshot.id]?.diagram
        }
        guard !Task.isCancelled else {
            mermaidPreviews[snapshot.id] = previous
            return snapshot.isClosed ? nil : previous?.diagram
        }
        let presentation = rendered.map { MermaidVectorPresentation(diagram: $0, maxWidth: width) }
        if snapshot.isClosed {
            mermaidPreviews[snapshot.id]?.completedSource = source
            mermaidPreviews[snapshot.id]?.diagram = presentation
            return presentation
        }
        if let presentation { mermaidPreviews[snapshot.id]?.diagram = presentation }
        return mermaidPreviews[snapshot.id]?.diagram
    }
#endif

    private func isMermaidLanguage(_ language: String?) -> Bool {
        guard let language else { return false }
        switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mermaid", "mmd", "mermaidjs":
            return true
        default:
            return false
        }
    }

    private func mermaidRenderScale() async -> CGFloat {
        #if canImport(UIKit)
        return await MainActor.run { UIScreen.main.scale }
        #elseif canImport(AppKit)
        return await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        #else
        return 2.0
        #endif
    }

    private func effectiveMermaidMaxWidth() -> CGFloat? {
        effectiveAttachmentMaxWidth()
    }

    private func effectiveInlineImageMaxWidth() -> CGFloat? {
        effectiveAttachmentMaxWidth()
    }

    private func effectiveAttachmentMaxWidth() -> CGFloat? {
        let runtime = runtimeMermaidMaxWidth.flatMap { $0 > 0 ? $0 : nil }
        let themeCap = theme.imageMaxWidth.flatMap { $0 > 0 ? $0 : nil }
        switch (runtime, themeCap) {
        case let (.some(runtime), .some(themeCap)):
            return min(runtime, themeCap)
        case let (.some(runtime), .none):
            return runtime
        case let (.none, .some(themeCap)):
            return themeCap
        case (.none, .none):
            return nil
        }
    }

    private func trimLeadingWhitespace(in attributedString: NSMutableAttributedString) {
        guard attributedString.length > 0 else { return }
        while attributedString.length > 0 {
            let range = NSRange(location: 0, length: 1)
            let firstCharacter = attributedString.attributedSubstring(from: range).string
            guard firstCharacter == " " || firstCharacter == "\t" else { break }
            attributedString.deleteCharacters(in: range)
        }
    }

    private func trimTrailingNewlines(in attributedString: NSMutableAttributedString) {
        let newline: unichar = 0x0A
        while attributedString.length > 0 {
            let lastIndex = attributedString.length - 1
            guard attributedString.mutableString.character(at: lastIndex) == newline else { break }
            attributedString.deleteCharacters(in: NSRange(location: lastIndex, length: 1))
        }
    }


    private func renderBlockquote(snapshot: BlockSnapshot, previousBlockKind: BlockKind? = nil,
                                  level: Int) async -> RenderedContentResult {
        var imageIndex = 0
        let bodyRuns = sanitizeInlineRuns(snapshot.inlineRuns ?? [], kind: snapshot.kind)
        // Container-only parents (e.g. the implicit level-1 block that
        // `>> nested` opens) render nothing: their children draw the bars for
        // every enclosing level themselves, so emitting a newline here would
        // show up as a stray blank quote line above the nested content.
        // Atomic payloads (images, math) count as content even when their
        // text — e.g. an empty alt — is blank.
        let hasOwnContent = bodyRuns.contains { run in
            run.image != nil || run.math != nil ||
                !run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !hasOwnContent && !snapshot.childIDs.isEmpty {
            return RenderedContentResult(attributed: AttributedString(),
                                        table: nil,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: [],
                                        codeBlock: nil)
        }
        let inlineImages = collectImages(from: bodyRuns, blockID: snapshot.id, counter: &imageIndex)
        let body = await renderInline(bodyRuns, font: bodyFont)
        // Trailing newline runs that survive styled spans would otherwise
        // combine with the terminator below into a blank quoted line. Only
        // newlines: trailing spaces can be real content (e.g. a code span
        // ending in a space).
        trimTrailingNewlines(in: body)
        // Nested quotes arrive as child blocks (depth 1, 2, …). The bars are
        // NOT characters: the range is marked with the quote level + bar
        // color and indented past a leading gutter; the text views draw one
        // continuous vertical bar per level there (see
        // BlockquoteBarDecoration.swift). Because the attribute also covers
        // the trailing newline, adjacent quote blocks merge into one
        // uninterrupted bar. Suppress the inter-paragraph gap between
        // adjacent quote blocks so a nested quote reads as one quote body.
        let followsBlockquote = previousBlockKind == .blockquote
        let paragraphStyle = makeBlockquoteParagraphStyle(level: level,
                                                          spacingBefore: followsBlockquote ? 0 : 4)
        let textColor = PlatformColor.rendererLabel

        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]

        let styledBody = NSMutableAttributedString(attributedString: body)
        if styledBody.length > 0 {
            styledBody.addAttributes(bodyAttributes, range: NSRange(location: 0, length: styledBody.length))
        }

        let result = NSMutableAttributedString(attributedString: styledBody)
        result.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
        result.addAttributes([
            .picoBlockquoteLevel: level,
            .picoBlockquoteBarColor: blockquoteColor.withAlphaComponent(0.6)
        ], range: NSRange(location: 0, length: result.length))

        // The plain AttributedString initializer drops the custom keys —
        // convert through the pico scope so the bar attributes survive.
        return RenderedContentResult(attributed: AttributedString.picoConverted(from: result),
                                    table: nil,
                                    listItem: nil,
                                    blockquote: RenderedBlockquote(content: AttributedString(styledBody)),
                                    math: nil,
                                    images: inlineImages,
                                    codeBlock: nil)
    }

    private func makeBlockquoteParagraphStyle(level: Int, spacingBefore: CGFloat = 4) -> NSMutableParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let indent = BlockquoteBarMetrics.textIndent(level: level)
        paragraphStyle.firstLineHeadIndent = indent
        paragraphStyle.headIndent = indent
#if canImport(AppKit)
        paragraphStyle.lineHeightMultiple = 1.24
        paragraphStyle.paragraphSpacing = bodyFont.pointSize
#else
        paragraphStyle.paragraphSpacing = 8
#endif
        paragraphStyle.paragraphSpacingBefore = spacingBefore
        return paragraphStyle
    }

#if !canImport(AppKit)
    /// UIKit fallback: iOS TextKit has no `NSTextTable`, so tables render as
    /// styled text rows — bold header, cells joined by a thin vertical
    /// separator — until a native iOS table presentation exists.
    /// `RenderedTable` is still populated with per-cell content so the view
    /// layer (or a future overlay) has the structured data.
    private func renderTable(_ snapshot: BlockSnapshot, font: PlatformFont) async -> (NSAttributedString, RenderedTable?, [RenderedImage]) {
        guard let table = snapshot.table else { return (NSAttributedString(), nil, []) }

        let maxRowColumns = table.rows.reduce(0) { max($0, $1.count) }
        let columnCount = max(table.headerCells?.count ?? 0, maxRowColumns)
        guard columnCount > 0 else { return (NSAttributedString(), nil, []) }

        var renderedTable = RenderedTable(headers: nil, rows: [], alignments: table.alignments)
        var collectedImages: [RenderedImage] = []
        var imageIndex = 0
        let result = NSMutableAttributedString()

        if let headers = table.headerCells, !headers.isEmpty {
            let (headerAttributed, headerCells) = await renderTableRow(cells: headers,
                                                                       numberOfColumns: columnCount,
                                                                       font: font,
                                                                       blockID: snapshot.id,
                                                                       imageCounter: &imageIndex,
                                                                       collectedImages: &collectedImages,
                                                                       isHeader: true)
            renderedTable.headers = headerCells
            result.append(headerAttributed)
        }

        var renderedRows: [[AttributedString]] = []
        for row in table.rows {
            let (rowAttributed, renderedCells) = await renderTableRow(cells: row,
                                                                      numberOfColumns: columnCount,
                                                                      font: font,
                                                                      blockID: snapshot.id,
                                                                      imageCounter: &imageIndex,
                                                                      collectedImages: &collectedImages,
                                                                      isHeader: false)
            renderedRows.append(renderedCells)
            result.append(rowAttributed)
        }

        renderedTable.rows = renderedRows
        result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        return (result, renderedTable, collectedImages)
    }

    private func renderTableRow(cells: [[InlineRun]],
                                numberOfColumns: Int,
                                font: PlatformFont,
                                blockID: BlockID,
                                imageCounter: inout Int,
                                collectedImages: inout [RenderedImage],
                                isHeader: Bool) async -> (NSAttributedString, [AttributedString]) {
        let rowAttributed = NSMutableAttributedString()
        var renderedCells: [AttributedString] = []
        let displayFont = isHeader ? boldFont(from: font) : font

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = 2

        let cellSeparator = NSAttributedString(string: "  \u{2502}  ", attributes: [
            .font: font,
            .foregroundColor: PlatformColor.rendererSecondaryLabel
        ])

        for column in 0..<numberOfColumns {
            let inlineRuns = column < cells.count ? cells[column] : []
            let inline = await renderInline(inlineRuns, font: displayFont)
            let images = collectImages(from: inlineRuns, blockID: blockID, counter: &imageCounter)
            if !images.isEmpty {
                collectedImages.append(contentsOf: images)
            }

            let cellContent = inline.length > 0 ? NSMutableAttributedString(attributedString: inline) : NSMutableAttributedString(string: " ")
            let cellRange = NSRange(location: 0, length: cellContent.length)
            // Fill the base font and label color only where inline runs
            // didn't set one, so run-level styling (bold, code, links)
            // survives — mirroring the AppKit cell path.
            cellContent.enumerateAttribute(.font, in: cellRange, options: []) { value, range, _ in
                if value == nil {
                    cellContent.addAttribute(.font, value: displayFont, range: range)
                }
            }
            cellContent.enumerateAttribute(.foregroundColor, in: cellRange, options: []) { value, range, _ in
                if value == nil {
                    cellContent.addAttribute(.foregroundColor, value: PlatformColor.rendererLabel, range: range)
                }
            }

            renderedCells.append(AttributedString(cellContent))
            if column > 0 {
                rowAttributed.append(cellSeparator)
            }
            rowAttributed.append(cellContent)
        }

        rowAttributed.append(NSAttributedString(string: "\n", attributes: [.font: displayFont]))
        rowAttributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: rowAttributed.length))

        return (rowAttributed, renderedCells)
    }
#else
    private func renderTable(_ snapshot: BlockSnapshot, font: PlatformFont,
                             previousBlockKind: BlockKind?) async -> (NSAttributedString, RenderedTable?, [RenderedImage]) {
        guard let table = snapshot.table else { return (NSAttributedString(), nil, []) }

        // The assembler's emitted table rows are immutable. Inspect only newly
        // appended rows; explicit image/width refreshes invalidate this cache.
        var cached = tableCache[snapshot.id]
        if let existing = cached,
           existing.sourceHeaders != table.headerCells || existing.alignments != table.alignments ||
            existing.rows.count > table.rows.count {
            cached = nil
        }
        let renderedRowCount = cached?.rows.count ?? 0
        let appendedColumnCount = table.rows[renderedRowCount...].reduce(0) { max($0, $1.count) }
        let columnCount = max(table.headerCells?.count ?? 0, cached?.columnCount ?? 0, appendedColumnCount)
        guard columnCount > 0 else { return (NSAttributedString(), nil, []) }
        if cached?.columnCount != columnCount { cached = nil }
        var state = cached ?? CachedTable(sourceHeaders: table.headerCells,
                                         alignments: table.alignments, columnCount: columnCount)

        nextTableRenderVersion &+= 1
        let version = nextTableRenderVersion
        tableRenderVersions[snapshot.id] = version

        if cached == nil, let headers = table.headerCells, !headers.isEmpty {
            state.headers = await renderHostedTableRow(cells: headers, numberOfColumns: columnCount,
                                                      font: font, alignments: table.alignments,
                                                      blockID: snapshot.id, imageCounter: &state.imageCounter,
                                                      collectedImages: &state.images, isHeader: true)
        }
        for row in table.rows[state.rows.count...] {
            let cells = await renderHostedTableRow(cells: row, numberOfColumns: columnCount,
                                                   font: font, alignments: table.alignments,
                                                   blockID: snapshot.id, imageCounter: &state.imageCounter,
                                                   collectedImages: &state.images, isHeader: false)
            state.rows.append(cells)
        }

        // An image lookup can suspend this actor. A newer render or explicit
        // invalidation must win over the older render's cached prefix.
        if tableRenderVersions[snapshot.id] == version {
            tableCache[snapshot.id] = snapshot.isClosed ? nil : state
            if snapshot.isClosed { tableRenderVersions[snapshot.id] = nil }
        }

        let paragraph = makeParagraphStyle(collapsedSpacing(for: .table, previousKind: previousBlockKind))
        let placeholder = NSAttributedString(string: "\u{FFFC}\n", attributes: [
            .font: font, .paragraphStyle: paragraph
        ])
        let rendered = RenderedTable(headers: state.headers, rows: state.rows, alignments: state.alignments)
        return (placeholder, rendered, state.images)
    }

    private func renderHostedTableRow(cells: [[InlineRun]], numberOfColumns: Int,
                                      font: PlatformFont, alignments: [TableAlignment]?, blockID: BlockID,
                                      imageCounter: inout Int, collectedImages: inout [RenderedImage],
                                      isHeader: Bool) async -> [AttributedString] {
        var renderedCells: [AttributedString] = []
        renderedCells.reserveCapacity(numberOfColumns)
        let displayFont = isHeader ? boldFont(from: font) : font

        for column in 0..<numberOfColumns {
            let inlineRuns = column < cells.count ? cells[column] : []
            let inline = await renderInline(inlineRuns, font: displayFont)
            collectedImages.append(contentsOf: collectImages(from: inlineRuns, blockID: blockID, counter: &imageCounter))
            let cellContent = inline.length > 0 ? NSMutableAttributedString(attributedString: inline) : NSMutableAttributedString(string: " ")
            let cellRange = NSRange(location: 0, length: cellContent.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = tableTextAlignment(for: column, alignments: alignments)
            paragraph.lineBreakMode = .byWordWrapping
            cellContent.addAttribute(.paragraphStyle, value: paragraph, range: cellRange)
            cellContent.enumerateAttribute(.font, in: cellRange) { value, range, _ in
                if value == nil { cellContent.addAttribute(.font, value: displayFont, range: range) }
            }
            cellContent.enumerateAttribute(.foregroundColor, in: cellRange) { value, range, _ in
                if value == nil { cellContent.addAttribute(.foregroundColor, value: PlatformColor.rendererLabel, range: range) }
            }
            renderedCells.append(AttributedString(cellContent))
        }
        return renderedCells
    }

#endif

    private func tableTextAlignment(for column: Int, alignments: [TableAlignment]?) -> NSTextAlignment {
        guard let alignments, column < alignments.count else { return .left }
        switch alignments[column] {
        case .left, .none:
            return .left
        case .center:
            return .center
        case .right:
            return .right
        }
    }

    private func render(run: InlineRun, baseFont: PlatformFont) async -> NSAttributedString {
        if run.style.contains(.math), let payload = run.math {
            return InlineMathAttachment.mathString(tex: payload.tex,
                                                   display: payload.display,
                                                   baseFont: baseFont)
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: run.style, baseFont: baseFont)
        ]
        if run.style.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if run.style.contains(.link), let url = run.linkURL, let linkURL = URL(string: url) {
            attributes[.foregroundColor] = linkColor
            attributes[.link] = linkURL
        }
        if run.style.contains(.code) {
            attributes[.font] = codeFont
        }
        if run.style.contains(.keyboard) {
            attributes[.font] = codeFont
            attributes[.backgroundColor] = PlatformColor.rendererKeyboardBackground
            attributes[.foregroundColor] = PlatformColor.rendererLabel
        }

        if run.style.contains(.superscript) || run.style.contains(.subscriptText) {
            let baseFont = (attributes[.font] as? PlatformFont) ?? baseFont
            let size = baseFont.pointSize * 0.75
#if canImport(UIKit)
            let adjusted = UIFont(descriptor: baseFont.fontDescriptor, size: size)
#else
            let adjusted = NSFont(descriptor: baseFont.fontDescriptor, size: size) ?? baseFont
#endif
            attributes[.font] = adjusted
            let offset = baseFont.pointSize * (run.style.contains(.superscript) ? 0.35 : -0.2)
            attributes[.baselineOffset] = offset
        }

        if let imagePayload = run.image {
            if let url = URL(string: imagePayload.source), let provider = imageProvider {
                if let result = await provider.image(for: url) {
                    let attachment = NSTextAttachment()
                    attachment.image = result.image
                    let size = result.size ?? result.image.size
                    let target = constrainImageSize(size, maxWidth: effectiveInlineImageMaxWidth())
                    attachment.bounds = CGRect(origin: .zero, size: target)
                    return NSAttributedString(attachment: attachment)
                }
            }
            // Fallback: render alt text if image not available
            return NSAttributedString(string: run.text, attributes: attributes)
        }

        return NSAttributedString(string: run.text, attributes: attributes)
    }

    private func constrainImageSize(_ size: CGSize, maxWidth: CGFloat?) -> CGSize {
        guard let maxWidth, maxWidth > 0 else { return size }
        guard size.width > maxWidth else { return size }
        let scale = maxWidth / size.width
        return CGSize(width: maxWidth, height: size.height * scale)
    }

    private func sanitizeInlineRuns(_ runs: [InlineRun], kind: BlockKind) -> [InlineRun] {
        guard !runs.isEmpty else { return runs }
        switch kind {
        case .paragraph, .heading, .listItem, .blockquote, .footnoteDefinition:
            return runs.map { run in
                guard run.text.contains("\n"), run.text != "\n" else { return run }
                guard !run.style.contains(.math) else { return run }
                var copy = run
                copy.text = run.text.replacingOccurrences(of: "\n", with: " ")
                return copy
            }
        default:
            return runs
        }
    }

    private func font(for style: InlineStyle, baseFont: PlatformFont) -> PlatformFont {
        var font = style.contains(.code) ? codeFont : baseFont
#if canImport(UIKit)
        if style.contains(.bold) && style.contains(.italic) {
            let descriptor = font.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) ?? font.fontDescriptor
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        } else if style.contains(.bold) {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        } else if style.contains(.italic) {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) ?? font.fontDescriptor
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        }
#else
        if style.contains(.bold) || style.contains(.italic) {
            var traits = font.fontDescriptor.symbolicTraits
            if style.contains(.bold) { traits.insert(.bold) }
            if style.contains(.italic) { traits.insert(.italic) }
            let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
            font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }
#endif
        return font
    }

    private func boldFont(from base: PlatformFont) -> PlatformFont {
#if canImport(UIKit)
        if let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) {
            return PlatformFont(descriptor: descriptor, size: base.pointSize)
        }
        return PlatformFont.systemFont(ofSize: base.pointSize, weight: .bold)
#else
        var traits = base.fontDescriptor.symbolicTraits
        traits.insert(.bold)
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        if let font = PlatformFont(descriptor: descriptor, size: base.pointSize) {
            return font
        }
        return PlatformFont.boldSystemFont(ofSize: base.pointSize)
#endif
    }
}

private extension PlatformColor {
    static var rendererLabel: PlatformColor {
#if canImport(UIKit)
        return .label
#else
        return .labelColor
#endif
    }

    static var rendererTableBorder: PlatformColor {
#if canImport(UIKit)
        return .separator
#else
        return .separatorColor
#endif
    }

    static var rendererTableHeaderBackground: PlatformColor {
#if canImport(UIKit)
        return .secondarySystemBackground
#else
        return NSColor.alternatingContentBackgroundColors.first ?? .windowBackgroundColor
#endif
    }

    static var rendererTableRowBackground: PlatformColor {
#if canImport(UIKit)
        return .systemBackground
#else
        return .textBackgroundColor
#endif
    }

    static var rendererSecondaryLabel: PlatformColor {
#if canImport(UIKit)
        return .secondaryLabel
#else
        return .secondaryLabelColor
#endif
    }

    static var rendererKeyboardBackground: PlatformColor {
#if canImport(UIKit)
        return .systemGray5
#else
        return .controlBackgroundColor
#endif
    }
}
