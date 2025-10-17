# PicoMarkdownView

SwiftUI component for rendering streaming Markdown and KaTeX in chat-style apps on iOS 18+ and macOS 15+.

## Installation

Add the package in your project’s `Package.swift`:

```swift
.package(url: "https://github.com/ronaldmannak/PicoMarkdownView.git", branch: "main")
```

Then add `PicoMarkdownView` to the target dependencies that require it.

## Usage

```swift
import PicoMarkdownView

@StateObject private var stream = PicoMarkdownStream()

var body: some View {
    PicoMarkdownView(stream: stream)
}

func appendChunk(_ markdown: String) {
    Task { await stream.append(markdown: markdown) }
}
```

`PicoMarkdownStream` performs incremental parsing. Feed it new Markdown as it arrives (for example from an LLM streaming response). The view maintains continuous selection and reuses layout via a shared `NSTextStorage` / TextKit 2 host under the hood.

### Configuration

```swift
let config = PicoMarkdownViewConfiguration(
    backgroundColor: .clear,
    contentInsets: EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16),
    isSelectable: true,
    isScrollEnabled: false
)

PicoMarkdownView(stream: stream, configuration: config)
```

### Custom Theme (Fonts & Colors)

`MarkdownRenderTheme` lets you tune typography and colors across platforms using the shared `MarkdownFont` / `MarkdownColor` aliases (which map to `UIFont` on iOS and `NSFont` on macOS):

```swift
import PicoMarkdownView

let theme = MarkdownRenderTheme(
    bodyFont: MarkdownFont.preferredFont(forTextStyle: .body).withSize(18),
    codeFont: MarkdownFont.monospacedSystemFont(ofSize: 16, weight: .regular),
    blockquoteColor: MarkdownColor.secondaryLabel,
    linkColor: MarkdownColor.systemBlue,
    headingFonts: [
        1: MarkdownFont.systemFont(ofSize: 30, weight: .bold),
        2: MarkdownFont.systemFont(ofSize: 26, weight: .semibold),
        3: MarkdownFont.systemFont(ofSize: 22, weight: .semibold)
    ]
)

var body: some View {
    PicoMarkdownStackView(text: markdown, theme: theme)
    // or PicoMarkdownStackView(stream: streamFactory, theme: theme)
}
```

### Code Block Highlighting

Code fences default to a monospaced system font. To customize styling or integrate your own syntax highlighter, provide a `CodeBlockTheme` and `CodeSyntaxHighlighter` via the supplied modifiers:

```swift
import PicoMarkdownView

struct SplashHighlighter: CodeSyntaxHighlighter {
    func highlight(_ code: String, language: String?, theme: CodeBlockTheme) -> AttributedString {
        // Insert your Splash-powered implementation here.
        // Fallback example keeps the theme font/colors.
        PlainCodeSyntaxHighlighter().highlight(code, language: language, theme: theme)
    }
}

var body: some View {
    PicoMarkdownStackView(text: markdown)
        .picoCodeTheme(.monospaced())
        .picoCodeHighlighter(SplashHighlighter())
}
```

By default the view uses `PlainCodeSyntaxHighlighter`, which simply applies the theme’s monospaced font.

### Resetting Content

```swift
Task {
    await stream.reset(markdown: "")
}
```

### Benchmarking

Run the bundled tests to exercise streaming and table rendering:

```bash
swift test
```

