import Foundation

/// An append-only text buffer optimized for streaming updates.
/// It keeps the full source string and offers helpers to determine
/// stable block boundaries so that incremental parsers can avoid
/// reparsing the entire document.
struct StreamingTextBuffer {
    private(set) var content: String = ""

    /// Appends a chunk of text to the buffer and returns the range
    /// of the newly-added characters.
    @discardableResult
    mutating func append(_ chunk: String) -> Range<String.Index> {
        let lower = content.endIndex
        content.append(chunk)
        let upper = content.endIndex
        return lower..<upper
    }

    /// Provides read-only access to the stored content.
    var text: String { content }

    /// Returns the index of the last known stable block boundary
    /// before the specified index. A stable boundary is defined as
    /// the beginning of the document or the position right after a
    /// blank line (double newline). This heuristic keeps incremental
    /// reparsing localized to the tail while remaining inexpensive.
    func lastStableBoundary(before index: String.Index) -> String.Index {
        guard !content.isEmpty else { return content.startIndex }
        let start = content.startIndex

        let prefix = content[..<index]

        if let fenceRange = lastFenceStart(in: prefix) {
            return fenceRange.lowerBound
        }

        if let blankLine = prefix.range(of: "\n\n", options: [.backwards]) {
            return blankLine.upperBound
        }

        // Fall back to the start of the preceding line to keep line-based
        // constructs (lists, block quotes) intact.
        if let lineBreak = prefix.lastIndex(of: "\n") {
            return content.index(after: lineBreak)
        }

        return start
    }

    private func lastFenceStart(in prefix: Substring) -> Range<String.Index>? {
        let fenceDelimiters = ["\n```", "\n~~~"]
        for delimiter in fenceDelimiters {
            if let range = prefix.range(of: delimiter, options: [.backwards]) {
                return range
            }
        }
        return nil
    }
}
