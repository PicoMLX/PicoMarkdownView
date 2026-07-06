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
}

actor MarkdownAttributeBuilder {
    private let theme: MarkdownRenderTheme
    private let imageProvider: MarkdownImageProvider?
    private let mermaidProvider: (any MermaidDiagramProvider)?
    private var runtimeMermaidMaxWidth: CGFloat?

    // Resolved platform types — created once at init, isolated to this actor.
    private let bodyFont: PlatformFont
    private let codeFont: PlatformFont
    private let headingFonts: [Int: PlatformFont]
    private let blockquoteColor: PlatformColor
    private let linkColor: PlatformColor

    init(theme: MarkdownRenderTheme,
         imageProvider: MarkdownImageProvider? = nil,
         mermaidProvider: (any MermaidDiagramProvider)? = nil) {
        self.theme = theme
        self.imageProvider = imageProvider
        self.mermaidProvider = mermaidProvider

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

    func render(snapshot: BlockSnapshot, previousBlockKind: BlockKind? = nil) async -> RenderedContentResult {
        switch snapshot.kind {
        case .table:
            let (fallback, table, images) = await renderTable(snapshot, font: bodyFont)
            return RenderedContentResult(attributed: AttributedString(fallback),
                                        table: table,
                                        listItem: nil,
                                        blockquote: nil,
                                        math: nil,
                                        images: images,
                                        codeBlock: nil)
        case .listItem(let ordered, let index, let task):
            return await renderListItem(snapshot: snapshot, ordered: ordered, index: index, task: task, previousBlockKind: previousBlockKind)
        case .blockquote:
            return await renderBlockquote(snapshot: snapshot)
        case .fencedCode:
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
                                        codeBlock: RenderedCodeBlock(code: text, language: language))
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
        // Use a 1-column NSTextTable that spans 100% width with a top border to emulate an HR
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.collapsesBorders = false
        table.setContentWidth(100, type: .percentageValueType)

        let block = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        // Minimal vertical padding so the rule is a thin line
        block.setWidth(0, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(0, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(0, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(0, type: .absoluteValueType, for: .padding, edge: .maxX)
        // Draw a single hairline using secondary label color; zero-out other edges
        block.setWidth(horizontalRuleBorderWidth, type: .absoluteValueType, for: .border, edge: .minY)
        block.setBorderColor(PlatformColor.rendererSecondaryLabel, for: .minY)
        block.setWidth(0, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(nil, for: .maxY)
        block.setWidth(0, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(nil, for: .minX)
        block.setWidth(0, type: .absoluteValueType, for: .border, edge: .maxX)
        block.setBorderColor(nil, for: .maxX)

        let blockParagraph = NSMutableParagraphStyle()
        blockParagraph.textBlocks = [block]
        blockParagraph.alignment = .left
        blockParagraph.lineBreakMode = .byWordWrapping
        blockParagraph.paragraphSpacing = 20
        blockParagraph.paragraphSpacingBefore = 20

        let result = NSMutableAttributedString()
        // Add a thin, non-breaking space to instantiate the block
        let cellContent = NSAttributedString(string: "\u{00A0}", attributes: [
            .paragraphStyle: blockParagraph,
            .font: bodyFont,
            .foregroundColor: PlatformColor.rendererLabel
        ])
        result.append(cellContent)
        // Trailing spacing beneath the rule kept minimal; rely on next block's own spacing
//        result.append(NSAttributedString(string: "\n", attributes: [
//            .font: bodyFont,
//            .paragraphStyle: blockParagraph
//        ]))
        // No extra blank paragraph appended here
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
                                previousBlockKind: BlockKind?) async -> RenderedContentResult {
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

        let bulletPrefix = bulletText + " "
        let rendered = NSMutableAttributedString(string: bulletPrefix, attributes: [.font: bodyFont])
        rendered.append(body)

        // Spacing via margin collapsing
        var listSpacing = collapsedSpacing(for: snapshot.kind, previousKind: previousBlockKind)
        if snapshot.depth > 0 {
            listSpacing.spacingAfter = max(0, listSpacing.spacingAfter - 2)
        }
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
        let nestingIndent: CGFloat = CGFloat(snapshot.depth) * 20

        // Final column where ALL wrapped lines start
        let headIndent = nestingIndent + max(bulletWidth, minReservedWidth) + bulletTextGap
        listParagraph.firstLineHeadIndent = headIndent - bulletWidth
        listParagraph.headIndent = headIndent

        rendered.addAttributes([.paragraphStyle: listParagraph],
                               range: NSRange(location: 0, length: rendered.length))

        // Apply the SAME paragraph style to the terminating "\n" as to the body,
        // mirroring renderInlineBlock. A paragraph's trailing paragraphSpacing is
        // resolved from its terminating character's style, so reusing listParagraph
        // here makes the inter-item gap honor listSpacing.spacingAfter (4pt top-level,
        // 2pt nested) instead of a hardcoded 6pt that overrode the margin system and
        // defeated the depth-based reduction above.
        rendered.append(NSAttributedString(string: "\n",
                                           attributes: [.font: bodyFont,
                                                        .paragraphStyle: listParagraph]))

        let metadata = RenderedListItem(bullet: bulletText,
                                        content: AttributedString(body),
                                        ordered: ordered,
                                        index: index,
                                        task: task)

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
            return BlockMargins(topMargin: 0, bottomMargin: 12, lineHeightMultiple: 1.24)
        case .fencedCode:
            return BlockMargins(topMargin: 12, bottomMargin: 12, lineHeightMultiple: 1.24)
        case .blockquote:
            return BlockMargins(topMargin: 8, bottomMargin: 8, lineHeightMultiple: 1.24)
        case .listItem:
            return BlockMargins(topMargin: 0, bottomMargin: 2, lineHeightMultiple: 1.24)
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
        case .unknown:
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

    private func renderMermaidFenceIfAvailable(snapshot: BlockSnapshot,
                                               previousBlockKind: BlockKind?) async -> RenderedContentResult? {
        guard theme.mermaidRenderingMode.isEnabled else { return nil }
        guard snapshot.isClosed else { return nil }
        guard let provider = mermaidProvider else { return nil }
        guard case let .fencedCode(language) = snapshot.kind, isMermaidLanguage(language) else { return nil }

        let source = snapshot.codeText ?? ""
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let mermaidMaxWidth = effectiveMermaidMaxWidth()
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

    private func renderBlockquote(snapshot: BlockSnapshot) async -> RenderedContentResult {
        var imageIndex = 0
        let bodyRuns = sanitizeInlineRuns(snapshot.inlineRuns ?? [], kind: snapshot.kind)
        let inlineImages = collectImages(from: bodyRuns, blockID: snapshot.id, counter: &imageIndex)
        let body = await renderInline(bodyRuns, font: bodyFont)
        let paragraphStyle = makeBlockquoteParagraphStyle()
        let lineColor = blockquoteColor.withAlphaComponent(0.6)
        let textColor = PlatformColor.rendererLabel

        let prefixAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: lineColor,
            .paragraphStyle: paragraphStyle
        ]

        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]

        let result = NSMutableAttributedString(string: "│ ", attributes: prefixAttributes)
        let styledBody = NSMutableAttributedString(attributedString: body)
        if styledBody.length > 0 {
            styledBody.addAttributes(bodyAttributes, range: NSRange(location: 0, length: styledBody.length))
        }
        result.append(styledBody)

        let mutableString = result.mutableString
        let prefixLength = ("│ " as NSString).length
        var searchLocation = prefixLength
        while searchLocation < mutableString.length {
            let range = mutableString.range(of: "\n", options: [], range: NSRange(location: searchLocation, length: mutableString.length - searchLocation))
            if range.location == NSNotFound { break }
            let insertLocation = range.location + range.length
            result.insert(NSAttributedString(string: "│ ", attributes: prefixAttributes), at: insertLocation)
            searchLocation = insertLocation + prefixLength
        }

        result.append(NSAttributedString(string: "\n", attributes: prefixAttributes))
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))

        return RenderedContentResult(attributed: AttributedString(result),
                                    table: nil,
                                    listItem: nil,
                                    blockquote: RenderedBlockquote(content: AttributedString(styledBody)),
                                    math: nil,
                                    images: inlineImages,
                                    codeBlock: nil)
    }

    private func makeBlockquoteParagraphStyle() -> NSMutableParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.firstLineHeadIndent = 0
        paragraphStyle.headIndent = 0
        paragraphStyle.paragraphSpacing = 8
        paragraphStyle.paragraphSpacingBefore = 4
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
    private func renderTable(_ snapshot: BlockSnapshot, font: PlatformFont) async -> (NSAttributedString, RenderedTable?, [RenderedImage]) {
        guard let table = snapshot.table else { return (NSAttributedString(), nil, []) }

        let maxRowColumns = table.rows.reduce(0) { max($0, $1.count) }
        let columnCount = max(table.headerCells?.count ?? 0, maxRowColumns)
        guard columnCount > 0 else { return (NSAttributedString(), nil, []) }

        let textTable = NSTextTable()
        textTable.numberOfColumns = columnCount
        textTable.collapsesBorders = false
        textTable.setContentWidth(100, type: .percentageValueType)
        textTable.setWidth(tableBorderWidth, type: .absoluteValueType, for: .border)
        textTable.setBorderColor(PlatformColor.rendererTableBorder)

        var renderedTable = RenderedTable(headers: nil, rows: [], alignments: table.alignments)
        var collectedImages: [RenderedImage] = []
        var imageIndex = 0
        let result = NSMutableAttributedString()
        var currentRow = 0

        if let headers = table.headerCells, !headers.isEmpty {
            let (headerAttributed, headerCells) = await renderTableRow(cells: headers,
                                                                 rowIndex: currentRow,
                                                                 numberOfColumns: columnCount,
                                                                 textTable: textTable,
                                                                 font: font,
                                                                 alignments: table.alignments,
                                                                 blockID: snapshot.id,
                                                                 imageCounter: &imageIndex,
                                                                 collectedImages: &collectedImages,
                                                                 isHeader: true)
            renderedTable.headers = headerCells
            result.append(headerAttributed)
            currentRow += 1
        }

        var renderedRows: [[AttributedString]] = []
        for row in table.rows {
            let (rowAttributed, renderedCells) = await renderTableRow(cells: row,
                                                                rowIndex: currentRow,
                                                                numberOfColumns: columnCount,
                                                                textTable: textTable,
                                                                font: font,
                                                                alignments: table.alignments,
                                                                blockID: snapshot.id,
                                                                imageCounter: &imageIndex,
                                                                collectedImages: &collectedImages,
                                                                isHeader: false)
            renderedRows.append(renderedCells)
            result.append(rowAttributed)
            currentRow += 1
        }

        renderedTable.rows = renderedRows
        result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        return (result, renderedTable, collectedImages)
    }

    private func renderTableRow(cells: [[InlineRun]],
                                rowIndex: Int,
                                numberOfColumns: Int,
                                textTable: NSTextTable,
                                font: PlatformFont,
                                alignments: [TableAlignment]?,
                                blockID: BlockID,
                                imageCounter: inout Int,
                                collectedImages: inout [RenderedImage],
                                isHeader: Bool) async -> (NSAttributedString, [AttributedString]) {
        let rowAttributed = NSMutableAttributedString()
        var renderedCells: [AttributedString] = []
        let displayFont = isHeader ? boldFont(from: font) : font

        for column in 0..<numberOfColumns {
            let block = NSTextTableBlock(table: textTable, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
            block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
            block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxY)
            block.setWidth(tableBorderWidth, type: .absoluteValueType, for: .border)
            block.setBorderColor(PlatformColor.rendererTableBorder)
            block.backgroundColor = isHeader ? PlatformColor.rendererTableHeaderBackground : PlatformColor.rendererTableRowBackground

            let paragraph = NSMutableParagraphStyle()
            paragraph.textBlocks = [block]
            paragraph.alignment = tableTextAlignment(for: column, alignments: alignments)
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.paragraphSpacing = 0
            paragraph.paragraphSpacingBefore = rowIndex == 0 ? 0 : 0

            let inlineRuns = column < cells.count ? cells[column] : []
            let inline = await renderInline(inlineRuns, font: displayFont)
            let images = collectImages(from: inlineRuns, blockID: blockID, counter: &imageCounter)
            if !images.isEmpty {
                collectedImages.append(contentsOf: images)
            }

            let cellContent = inline.length > 0 ? NSMutableAttributedString(attributedString: inline) : NSMutableAttributedString(string: " ")
            let cellRange = NSRange(location: 0, length: cellContent.length)
            // The table block/alignment must cover the whole cell, but the
            // run-level fonts and colors produced by inline styling (bold,
            // italic, code, links) must survive — only fill the base font and
            // label color where a run didn't set one.
            cellContent.addAttribute(.paragraphStyle, value: paragraph, range: cellRange)
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
            rowAttributed.append(cellContent)
            rowAttributed.append(NSAttributedString(string: "\n", attributes: [
                .paragraphStyle: paragraph,
                .font: displayFont
            ]))
        }

        return (rowAttributed, renderedCells)
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

    private var tableBorderWidth: CGFloat {
#if canImport(UIKit)
        return max(1.0 / UIScreen.main.scale, 0.5)
#else
        return 1.0
#endif
    }

    private var horizontalRuleBorderWidth: CGFloat {
#if canImport(UIKit)
        let baseBorder = max(1.0 / UIScreen.main.scale, 0.5)
        let previousWidth = max(baseBorder / 2, 0.25)
        return max(previousWidth / 2, 0.125)
#else
        return 0.1
#endif
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
