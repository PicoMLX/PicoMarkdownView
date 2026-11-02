#if os(macOS)
import Foundation

/// An immutable presentation update, independent of Markdown source/diffs.
struct MarkdownImagePreview: Sendable {
    let result: MarkdownImageResult
    let revision = UUID()
    let isFinal: Bool

    init(result: MarkdownImageResult, isFinal: Bool = false) {
        self.result = result
        self.isFinal = isFinal
    }
}
#endif
