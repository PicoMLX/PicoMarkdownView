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

### Adjusting Font Size (Zoom Controls)

You can provide “Actual Size”, “Zoom In”, and “Zoom Out” controls by keeping a zoom factor in state and rebuilding the theme when it changes:

```swift
import PicoMarkdownView

struct ZoomableMarkdownView: View {
    @State private var zoom: CGFloat = 1.0
    private let markdown = """
    ## Famous Formula

    Inline math: \\(E = mc^2\\)
    """

    private let baseTheme = MarkdownRenderTheme.default()

    private var scaledTheme: MarkdownRenderTheme {
        var theme = baseTheme
        theme.bodyFont = theme.bodyFont.withSize(theme.bodyFont.pointSize * zoom)
        theme.codeFont = theme.codeFont.withSize(theme.codeFont.pointSize * zoom)
        var headings: [Int: MarkdownFont] = [:]
        for (level, font) in theme.headingFonts {
            headings[level] = font.withSize(font.pointSize * zoom)
        }
        theme.headingFonts = headings
        return theme
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Button("Zoom Out") { zoom = max(0.5, zoom - 0.1) }
                Button("Actual Size") { zoom = 1.0 }
                Button("Zoom In") { zoom = min(2.0, zoom + 0.1) }
            }
            PicoMarkdownStackView(text: markdown, theme: scaledTheme)
        }
        .padding()
    }
}
```

### Code Block Highlighting

Code fences default to a monospaced system font. To customize styling or integrate your own syntax highlighter, provide a `CodeBlockTheme` and `CodeSyntaxHighlighter` via the supplied modifiers:

```swift
import PicoMarkdownView
import Splash

struct SplashCodeHighlighter: CodeSyntaxHighlighter {
    private let splash: SyntaxHighlighter<TextOutputFormat>

    init(theme: Splash.Theme) {
        self.splash = SyntaxHighlighter(format: TextOutputFormat(theme: theme))
    }

    func highlight(_ code: String, language: String?, theme: CodeBlockTheme) -> AttributedString {
        guard language != nil else {
            return PlainCodeSyntaxHighlighter().highlight(code, language: language, theme: theme)
        }

        return AttributedString(splash.highlight(code))
    }
}

var body: some View {
    PicoMarkdownStackView(text: markdown)
        .picoCodeTheme(.monospaced())
        .picoCodeHighlighter(SplashCodeHighlighter(theme: .midnight(withFont: Splash.Font(size: 14))))
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

