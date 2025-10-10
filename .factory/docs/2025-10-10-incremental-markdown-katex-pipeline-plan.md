## Library Assessment
- **Markdown:** Start with `cmark-gfm` via Swift package wrapper; it already exposes an incremental `cmark_parser_feed`, but final block closure requires us to snapshot parser state. We can maintain a rope-backed buffer and, on each chunk, feed only the appended slice; when a block terminator arrives (newline/new fence), finalize the previous block and emit AST nodes without reparsing earlier text. Capture source ranges per node to enable targeted updates.
- **KaTeX:** There is no native C KaTeX port; best options are Objective-C `iosMath` (MathJax-derived) or SwiftMath. They parse a LaTeX subset compatible with KaTeX math mode and render to CoreText/Metal, so we can wrap them as inline/block attachments. For features missing in `iosMath`, consider embedding the KaTeX JS core through JavaScriptCore (costly) but only for expressions the native path cannot handle.

## Incremental Diff Wrapper
- Maintain an append-only piece-table that records stable block boundaries and maps them to AST node identifiers. When new text arrives, determine the affected block span (usually the tail), wipe any partially complete block nodes, and resume parsing from the last confirmed boundary. Recycle prior AST nodes for untouched regions to avoid allocations.
- Generate a lightweight diff between previous and current node lists (e.g., by node IDs + ranges). This diff drives renderer updates, so only changed ranges touch the attributed text.

## Incremental Formatting Strategy
- Store content inside a shared `NSTextStorage`/`TextLayoutManager` pair wrapped by `TextKit 2` bridges (`UITextView`/`NSTextView`) to ensure continuous selection. Apply updates with `beginEditing`/`endEditing`, mutating only ranges flagged by the diff and rewriting the corresponding attributes/attachments. SwiftUI hosts the text view via `UIViewRepresentable`/`NSViewRepresentable`, so upstream redraws merely invalidate the snapshot without rebuilding the attributed string.
- Theme changes or dynamic type updates trigger a targeted attribute pass leveraging the same node metadata, keeping streaming additions cheap.

## Next Experiments
1. Prototype parser wrapper proving we can append 10k chunks without full reparse (benchmark vs. cmark full parse).
2. Evaluate `iosMath` rendering performance with sample KaTeX snippets and measure attachment cost.
3. Build attributed-string diff applier and validate that selection remains continuous in a SwiftUI `ScrollView` hosting multiple historical messages.
