## Key Decisions
- **Public API**: Expose `PicoMarkdownView(_ text: String, configuration: PicoMarkdownViewConfiguration = .default)`—no bindings, no observable objects, no streaming flag.
- **Update Detection**: SwiftUI re-invokes `body` whenever `text` changes because value types trigger a new view identity; we’ll compare against internally cached text length to detect appended ranges.
- **Internal State**: Use `@State` for the rendered `NSAttributedString` and the last processed character count. `StreamingTextBuffer` and `StreamingMarkdownRenderer` remain internal helpers; no `ObservableObject`/`@Observable` needed.
- **Rendering Pipeline**:
  1. `body` calls a dedicated `UpdateTask` (via `.task(id: text)` or `onChange(of: text)`) that runs parsing on a background `Task`.
  2. Determine whether change is append-only; if yes, feed only the suffix to renderer; else fall back to full re-render.
  3. Update `@State` with the resulting attributed string on the main actor.
- **UIKit/AppKit Host**: `PlatformTextView` holds a cached `NSTextStorage`. When SwiftUI updates the `@State` attributed string, `updateUIView`/`updateNSView` applies attributed changes with `beginEditing()/endEditing()`.

## Implementation Steps
1. Refactor `PicoMarkdownView` init and body to accept raw `String` and manage `@State` cache.
2. Enhance `StreamingMarkdownRenderer` with APIs for suffix parsing and full resets.
3. Add guard logic detecting non-append edits and trigger full re-render.
4. Update platform-specific views to accept a plain `NSAttributedString` from `@State`.
5. Adjust tests to construct the view with simple strings and simulate streaming by successively rendering new strings.
