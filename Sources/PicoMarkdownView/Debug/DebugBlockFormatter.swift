#if DEBUG

import Foundation

struct DebugBlockFormatter {
    func makeLines(from blocks: [RenderedBlock]) -> [String] {
        var lines: [String] = []
        for block in blocks {
            append(block: block, to: &lines)
        }
        return lines
    }

    private func append(block: RenderedBlock, to lines: inout [String]) {
        let indent = max(block.snapshot.depth, 0)
        let prefix = String(repeating: "  ", count: indent)
        lines.append(prefix + describe(block: block))

        switch block.kind {
        case .math:
            if let math = block.math {
                lines.append(prefix + "  tex → " + sanitizeNewlines(in: math.tex))
                let displayValue = math.display ? "true" : "false"
                lines.append(prefix + "  display → \(displayValue)")
            } else if let text = block.snapshot.mathText {
                lines.append(prefix + "  tex (snapshot) → " + sanitizeNewlines(in: text))
            }
        case .paragraph, .heading, .blockquote, .listItem, .unknown:
            if let runs = block.snapshot.inlineRuns, !runs.isEmpty {
                for run in runs {
                    lines.append(prefix + "  " + describe(run: run))
                }
            }
        case .fencedCode:
            if let code = block.snapshot.codeText {
                lines.append(prefix + "  code → " + sanitizeNewlines(in: code))
            }
        case .table:
            lines.append(prefix + "  table headers: \(block.table?.headers?.count ?? 0), rows: \(block.table?.rows.count ?? 0)")
        }

        if !block.images.isEmpty {
            for image in block.images {
                lines.append(prefix + "  image[\(image.altText)](\(image.source))")
            }
        }
    }

    private func describe(block: RenderedBlock) -> String {
        switch block.kind {
        case .paragraph:
            return "paragraph (id: \(block.id))"
        case .heading(let level):
            return "heading level \(level) (id: \(block.id))"
        case .listItem(let ordered, let index, let task):
            var parts: [String] = []
            parts.append(ordered ? "ordered" : "unordered")
            if let index {
                parts.append("index=\(index)")
            }
            if let task {
                let taskValue = task.checked ? "checked" : "unchecked"
                parts.append("task=\(taskValue)")
            }
            return "listItem (id: \(block.id)) [\(parts.joined(separator: ", "))]"
        case .blockquote:
            return "blockquote (id: \(block.id))"
        case .fencedCode(let language):
            let lang = language ?? ""
            return lang.isEmpty ? "fencedCode (id: \(block.id))" : "fencedCode(\(lang)) (id: \(block.id))"
        case .math(let display):
            return "math(display: \(display)) (id: \(block.id))"
        case .table:
            return "table (id: \(block.id))"
        case .unknown:
            return "unknown (id: \(block.id))"
        }
    }

    private func describe(run: InlineRun) -> String {
        if let payload = run.math {
            let mode = payload.display ? "block" : "inline"
            return "math run (\(mode)) → " + sanitizeNewlines(in: payload.tex)
        }

        if let image = run.image {
            return "image run → alt=\(run.text), source=\(image.source)"
        }

        var attributes: [String] = []
        if run.style.contains(.bold) { attributes.append("bold") }
        if run.style.contains(.italic) { attributes.append("italic") }
        if run.style.contains(.code) { attributes.append("code") }
        if run.style.contains(.strikethrough) { attributes.append("strikethrough") }
        if run.style.contains(.link) { attributes.append("link") }

        let stylePrefix: String
        if attributes.isEmpty {
            stylePrefix = "text"
        } else {
            stylePrefix = attributes.joined(separator: "+")
        }

        var line = "run \(stylePrefix) → " + sanitizeNewlines(in: run.text)
        if let url = run.linkURL {
            line += " (url: \(url))"
        }
        return line
    }

    private func sanitizeNewlines(in text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "⏎")
    }
}

#endif
