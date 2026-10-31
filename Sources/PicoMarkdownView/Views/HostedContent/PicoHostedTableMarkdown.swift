#if os(macOS)
import Foundation

enum PicoHostedTableMarkdown {
    static func render(_ table: TableSnapshot) -> String {
        let headers = (table.headerCells ?? []).map(inline)
        let rows = table.rows.map { $0.map(inline) }
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return "" }
        func row(_ cells: [String]) -> String {
            let values = (0..<columns).map { escapeCell($0 < cells.count ? cells[$0] : "") }
            return "| " + values.joined(separator: " | ") + " |"
        }
        let separators = (0..<columns).map { column -> String in
            switch table.alignments.flatMap({ column < $0.count ? $0[column] : nil }) ?? .none {
            case .none: "---"
            case .left: ":---"
            case .center: ":---:"
            case .right: "---:"
            }
        }
        return ([row(headers), row(separators)] + rows.map(row)).joined(separator: "\n") + "\n"
    }

    static func inline(_ runs: [InlineRun]) -> String {
        var coalesced: [InlineRun] = []
        for run in runs {
            if let last = coalesced.last, last.canCoalesce(with: run) {
                coalesced[coalesced.count - 1].text += run.text
            } else { coalesced.append(run) }
        }
        var active: [Wrapper] = []
        var result = ""
        for run in coalesced {
            let desired = wrappers(for: run)
            // Keep continuing outer spans open. Reopening an emphasis span
            // at each run can put delimiters beside whitespace or combine
            // them with adjacent delimiters, changing the copied styles.
            let shared = active.prefix { desired.contains($0) }.count
            for wrapper in active.dropFirst(shared).reversed() { result += wrapper.closing }
            active = Array(active.prefix(shared))
            for wrapper in desired where !active.contains(wrapper) {
                result += wrapper.opening
                active.append(wrapper)
            }
            result += markdownContent(run)
        }
        for wrapper in active.reversed() { result += wrapper.closing }
        return result
    }

    private static func markdownContent(_ run: InlineRun) -> String {
        var value: String
        if let tag = run.tag {
            value = tag.rawText
        } else if let image = run.image {
            let title = image.title.map { " \"\(escapeTitle($0))\"" } ?? ""
            value = "![\(escapeInline(run.text))](\(escapeDestination(image.source))\(title))"
        } else if let math = run.math {
            value = math.display ? "\\[\(math.tex)\\]" : "\\(\(math.tex)\\)"
        } else if run.style.contains(.code) {
            var longest = 0
            var current = 0
            for character in run.text {
                current = character == "`" ? current + 1 : 0
                longest = max(longest, current)
            }
            let delimiter = String(repeating: "`", count: longest + 1)
            let spaced = run.text.hasPrefix(" ") && run.text.hasSuffix(" ") && run.text.contains(where: { $0 != " " })
            let padding = run.text.hasPrefix("`") || run.text.hasSuffix("`") || spaced ? " " : ""
            value = delimiter + padding + run.text + padding + delimiter
        } else {
            value = escapeInline(run.text)
        }
        return value
    }

    private static func wrappers(for run: InlineRun) -> [Wrapper] {
        var wrappers: [Wrapper] = []
        if run.tag == nil, run.style.contains(.link), let destination = run.linkURL {
            wrappers.append(.link(destination))
        }
        if run.style.contains(.bold) { wrappers.append(.bold) }
        if run.style.contains(.italic) { wrappers.append(.italic) }
        if run.style.contains(.strikethrough) { wrappers.append(.strikethrough) }
        if run.style.contains(.keyboard) { wrappers.append(.keyboard) }
        if run.style.contains(.superscript) { wrappers.append(.superscript) }
        if run.style.contains(.subscriptText) { wrappers.append(.subscriptText) }
        return wrappers
    }

    private enum Wrapper: Equatable {
        case link(String), bold, italic, strikethrough, keyboard, superscript, subscriptText

        var opening: String {
            switch self {
            case .link: "["
            case .bold: "**"
            case .italic: "*"
            case .strikethrough: "~~"
            case .keyboard: "<kbd>"
            case .superscript: "<sup>"
            case .subscriptText: "<sub>"
            }
        }

        var closing: String {
            switch self {
            case .link(let destination): "](\(PicoHostedTableMarkdown.escapeDestination(destination)))"
            case .bold: "**"
            case .italic: "*"
            case .strikethrough: "~~"
            case .keyboard: "</kbd>"
            case .superscript: "</sup>"
            case .subscriptText: "</sub>"
            }
        }
    }

    private static func escapeInline(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\\", with: "\\\\")
        for marker in ["*", "_", "[", "]", "`", "~"] {
            value = value.replacingOccurrences(of: marker, with: "\\" + marker)
        }
        return value.replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeTitle(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func escapeDestination(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
    }

    private static func escapeCell(_ text: String) -> String {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
        var result = ""
        var slashes = 0
        for character in text {
            if character == "|", slashes.isMultiple(of: 2) { result.append("\\") }
            result.append(character)
            slashes = character == "\\" ? slashes + 1 : 0
        }
        return result
    }
}
#endif
