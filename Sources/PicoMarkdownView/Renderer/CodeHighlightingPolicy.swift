import Foundation

/// Decides when a fenced code block is worth sending through the syntax
/// highlighter.
///
/// Code blocks re-render on every streamed chunk, so an unbounded block
/// would re-tokenize its entire accumulated text each time — O(n²) over the
/// stream. Blocks past `streamingByteThreshold` render as plain text while
/// open; the fence-close diff (`blockEnded`) refreshes the block, giving it
/// exactly one full highlight pass. Blocks past `hardByteLimit` are never
/// highlighted.
enum CodeHighlightingPolicy {
    /// While a block is still streaming, highlight only up to this size.
    /// Typical chat code blocks are a few hundred bytes; tokenizing 16 KB
    /// stays around a millisecond off the main actor.
    static let streamingByteThreshold = 16 * 1024

    /// Never highlight blocks larger than this, even after they close.
    static let hardByteLimit = 512 * 1024

    static func shouldBypassHighlighting(byteCount: Int, isClosed: Bool) -> Bool {
        if byteCount > hardByteLimit {
            return true
        }
        return !isClosed && byteCount > streamingByteThreshold
    }
}
