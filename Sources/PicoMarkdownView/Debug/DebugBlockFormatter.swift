#if DEBUG

import Foundation

struct DebugBlockFormatter {
    func makeLines(from blocks: [RenderedBlock]) -> [String] {
        var lines: [String] = []
        let resolver = BlockResolver(blocks: blocks)
        for block in blocks where block.snapshot.parentID == nil {
            append(blockID: block.id, resolver: resolver, lines: &lines, indent: 0)
        }
        return lines
    }

    private func append(blockID: BlockID,
                        resolver: BlockResolver,
                        lines: inout [String],
                        indent: Int) {
        guard let block = resolver.block(for: blockID) else { return }
        let prefix = String(repeating: "  ", count: indent)
        lines.append(prefix + describe(block: block))

        emitDetails(for: block, prefix: prefix, into: &lines)

        for child in block.snapshot.childIDs {
            append(blockID: child, resolver: resolver, lines: &lines, indent: indent + 1)
        }
    }

    private func emitDetails(for block: RenderedBlock,
                             prefix: String,
                             into lines: inout [String]) {
        switch block.kind {
        case .paragraph, .heading, .blockquote, .listItem, .unknown:
            emitInlineRuns(block.snapshot.inlineRuns, prefix: prefix, into: &lines)
        case .math:
            emitMath(block, prefix: prefix, into: &lines)
        case .fencedCode:
            if let code = block.snapshot.codeText {
                lines.append(prefix + "  code: \"" + sanitizeNewlines(in: code) + "\"")
            }
        case .table:
            emitTable(block, prefix: prefix, into: &lines)
        case .horizontalRule:
            break
        }

        if !block.images.isEmpty {
            for image in block.images {
                lines.append(prefix + "  image: alt=\"\(image.altText)\" source=\"\(image.source)\"")
            }
        }
    }

    private func emitInlineRuns(_ runs: [InlineRun]?,
                                prefix: String,
                                into lines: inout [String]) {
        guard let runs, !runs.isEmpty else { return }
        for run in runs {
            let label = inlineLabel(for: run)
            lines.append(prefix + "  " + label)
        }
    }

    private func inlineLabel(for run: InlineRun) -> String {
        if let payload = run.math {
            let mode = payload.display ? "math (display)" : "math"
            return "\(mode): \"" + sanitizeNewlines(in: payload.tex) + "\""
        }

        if let image = run.image {
            return "image: alt=\"\(run.text)\" source=\"\(image.source)\""
        }

        var modifiers: [String] = []
        if run.style.contains(.bold) { modifiers.append("strong") }
        if run.style.contains(.italic) { modifiers.append("emphasized") }
        if run.style.contains(.code) { modifiers.append("code") }
        if run.style.contains(.strikethrough) { modifiers.append("strikethrough") }
        if run.style.contains(.link) { modifiers.append("link") }

        var parts: [String] = []
        parts.append(modifiers.isEmpty ? "text" : modifiers.joined(separator: "+"))
        parts.append("\"" + sanitizeNewlines(in: run.text) + "\"")
        if let url = run.linkURL {
            parts.append("(url: \(url))")
        }
        return parts.joined(separator: ": ")
    }

    private func emitMath(_ block: RenderedBlock,
                          prefix: String,
                          into lines: inout [String]) {
        if let math = block.math {
            lines.append(prefix + "  tex: \"" + sanitizeNewlines(in: math.tex) + "\"")
            lines.append(prefix + "  display: \(math.display ? "true" : "false")")
        } else if let text = block.snapshot.mathText {
            lines.append(prefix + "  tex: \"" + sanitizeNewlines(in: text) + "\" (snapshot)")
        }
    }

    private func emitTable(_ block: RenderedBlock,
                           prefix: String,
                           into lines: inout [String]) {
        if let headers = block.table?.headers {
            for (index, header) in headers.enumerated() {
                lines.append(prefix + "  header[\(index)]: \"\(String(header.characters))\"")
            }
        }
        if let rows = block.table?.rows {
            for (rowIndex, row) in rows.enumerated() {
                lines.append(prefix + "  row[\(rowIndex)]")
                for (cellIndex, cell) in row.enumerated() {
                    lines.append(prefix + "    cell[\(cellIndex)]: \"\(String(cell.characters))\"")
                }
            }
        }
    }

    private func describe(block: RenderedBlock) -> String {
        switch block.kind {
        case .paragraph:
            return "paragraph"
        case .heading(let level):
            return "heading (level \(level))"
        case .listItem(let ordered, _, let task):
            var components: [String] = []
            components.append(ordered ? "ordered list" : "list")
            if let task {
                components.append(task.checked ? "checked" : "unchecked")
            }
            return components.joined(separator: " ")
        case .blockquote:
            return "blockQuote"
        case .fencedCode(let language):
            if let language, !language.isEmpty {
                return "codeBlock (language \(language))"
            }
            return "codeBlock"
        case .math(let display):
            return display ? "mathBlock" : "math"
        case .table:
            return "table"
        case .horizontalRule:
            return "horizontalRule"
        case .unknown:
            return "unknown"
        }
    }

    private func sanitizeNewlines(in text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "⏎")
    }
}

private struct BlockResolver {
    private let map: [BlockID: RenderedBlock]

    init(blocks: [RenderedBlock]) {
        self.map = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
    }

    func block(for id: BlockID) -> RenderedBlock? {
        map[id]
    }
}

#endif
