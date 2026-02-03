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

@State private var text = "Hello **Markdown**"

var body: some View {
    PicoMarkdownView(text)
}
```

For streaming, pass chunks or an async stream:

```swift
PicoMarkdownView(chunks: ["Hello ", "world", "\n\n"])

PicoMarkdownView(stream: {
    AsyncStream { continuation in
        continuation.yield("Hello ")
        continuation.yield("world\n\n")
        continuation.finish()
    }
})
```

The view maintains continuous selection and reuses layout via a shared `NSTextStorage` / TextKit host under the hood.

### Configuration

```swift
let config = PicoTextKitConfiguration(
    backgroundColor: .clear,
    contentInsets: EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16),
    isSelectable: true,
    isScrollEnabled: false
)

PicoMarkdownView("Hello", configuration: config)
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
    PicoMarkdownView(markdown, theme: theme)
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
            PicoMarkdownView(markdown, theme: scaledTheme)
        }
        .padding()
    }
}
```

### Code Block Highlighting

Code fences default to the theme’s monospaced font. To customize styling or plug in a syntax highlighter, set `codeBlockTheme` and `codeHighlighter` on `MarkdownRenderTheme`:

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

var themed = MarkdownRenderTheme.default()
themed.codeBlockTheme = CodeBlockTheme.monospaced()
themed.codeHighlighter = AnyCodeSyntaxHighlighter(SplashCodeHighlighter(theme: .midnight(withFont: Splash.Font(size: 14))))

var body: some View {
    PicoMarkdownView(markdown, theme: themed)
}
```

### Resetting Content

To replace content, pass a new string/chunks/stream so the view creates a fresh input:

```swift
@State private var text = "First"

var body: some View {
    PicoMarkdownView(text)
}
```

### Benchmarking

Run the bundled tests to exercise streaming and table rendering:

```bash
swift test
```
