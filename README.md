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

### Inline Tags (Mentions / Hashtags / Tickers / Wiki-Links)

PicoMarkdownView recognises lightweight inline tags so a host app can attach
custom interactions — Slack-style user popovers, hashtag filters, wiki
links — without forking the parser. The tokenizer emits these as
`InlineRun`s with `style` containing `.tag` and a populated `tag: Tag`
payload; the renderer (in the follow-up PR) will wire them through the
same link-routing path used for `[text](url)`.

#### Defaults

Two prefixes are registered automatically:

- `@` — user mentions
- `#` — hashtags / topics

#### Opt-in prefixes

Pass an explicit set to `MarkdownTokenizer` to add others:

```swift
let tokenizer = MarkdownTokenizer(tagPrefixes: [
    .mention,                                  // @
    .hashtag,                                  // #
    .ticker,                                   // $  (collides with TeX; see below)
    .paired(open: "[[", close: "]]")           // [[wiki-link]]
])
```

The `$` ticker is **not** in the defaults because it collides with TeX/KaTeX
inline math (`$x = mc^2$`). Enable it only when the content does not
contain math.

#### Character rules

**Left boundary** (when an opener counts as one):

A tag opener (`@`, `#`, `[[`, etc.) only fires when the character
immediately preceding it is one of: beginning of input, whitespace, a
hard-stop character (see below), or a trailing-strip character (see
below). ASCII letters, digits, `_`, `-`, and `+` *suppress* the opener,
so `john@example.com`, `v1.2+rc1`, and similar word-continuations do
not become tags. Non-ASCII characters (emoji, CJK, accented letters)
never suppress, so `🎯@user` and `张伟@user` still recognise the mention.

A practical consequence: adjacent mentions without a separator (`@beh@lool`)
emit one tag followed by plain text, not two tags — matching how Slack,
Discord, and Twitter render mentions. Use a space or punctuation between
mentions to get two tags.

Paired-delimiter tags (`[[wiki]]`) are exempt from the left-boundary
suppression — their multi-character opening already provides a natural
boundary — so `abc[[wiki]]` still matches.

**Right boundary** (where a tag ends):

A tag ends at the first of:

- **Whitespace** (any Unicode whitespace, including newline).
- **Hard-stop characters** (the character stays in the surrounding text):
  `(` `)` `[` `]` `{` `}` `<` `>` `"` `'` `/` `\` `|` `*` `_` `~` `` ` ``.
- **The opening character of any registered tag prefix**.

Six characters may appear *inside* a tag but are stripped from the trailing
edge: `.` `,` `:` `;` `!` `?`. So `@behlool!` matches identifier `"behlool"`,
and `@john.doe.` matches `"john.doe"` (only the trailing `.` is stripped).

Everything else flows in — emoji, CJK, accented letters, digits,
underscores, hyphens. The host receives the raw identifier and decides
what to do with it.

#### Markdown-link form

In addition to the bare form, the parser also recognises the markdown-link
form with a tag prefix glued on:

```
@[John Doe](u-2345)
```

This emits:

```swift
Tag(prefix: "@",
    identifier: "u-2345",
    displayText: "@John Doe",
    rawText: "@[John Doe](u-2345)")
```

This decouples the visible name from the lookup key — useful when the
identifier is an opaque ID and the display name might contain spaces.

#### Streaming guarantees

Tag recognition is local within a block and never violates the streaming
invariants:

- A tag opener that arrives without its terminator (e.g. chunk ends mid
  `@behlool` or mid `@[John Doe](`) is buffered; preceding plain text is
  emitted immediately, the opener waits for the next chunk.
- No provisional tag events are emitted that later need correction.
- Verbatim content: no further inline parsing happens *inside* a tag, so
  `@**unclosed` does not destabilise emphasis state later in the document.

### Benchmarking

Run the bundled tests to exercise streaming and table rendering:

```bash
swift test
```
