# PicoMarkdownView

[![CI](https://github.com/PicoMLX/PicoMarkdownView/actions/workflows/ci.yml/badge.svg)](https://github.com/PicoMLX/PicoMarkdownView/actions/workflows/ci.yml)

SwiftUI component for rendering streaming Markdown and KaTeX in chat-style apps on iOS 18+ and macOS 27+.

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

For live streaming, pass an async stream — chunks are fed to the parser
incrementally as they arrive:

```swift
PicoMarkdownView(stream: {
    AsyncStream { continuation in
        continuation.yield("Hello ")
        continuation.yield("world\n\n")
        continuation.finish()
    }
})
```

To replay an already collected sequence of chunks (e.g. a finished
response) in one shot, pass the array directly. Note that each delivery is
parsed as a complete document, so this is not intended for feeding a
growing array during live streaming — use `stream:` for that:

```swift
PicoMarkdownView(chunks: ["Hello ", "world", "\n\n"])
```

The view maintains continuous selection in a single TextKit document. On macOS 27 it uses TextKit 2 with hosted table attachments; iOS retains its existing UIKit rendering path. Streaming rows update the hosted table model without replacing its attachment character, and mixed selections copy the selected table as Markdown.

### Hosted macOS content

On macOS 27, tables occupy one attachment character. Dragging through a table
selects it as a whole; copying expands it to Markdown. Row appends keep the
attachment and row identities, while changes in height invalidate only the
attachment's text range. The tokenizer and assembler remain incremental and
run off the main actor.

`PicoHostedAttachment` is the same reusable hosting primitive for additional
macOS renderer blocks, such as charts or tool controls:

```swift
let attachment = PicoHostedAttachment(
    interaction: .interactive,
    markdown: { "[Run tool](tool://run)" }
) { context in
    Button("Run tool", action: runTool)
        .frame(maxWidth: .infinity, alignment: .leading)
}
```

A renderer inserts it with `NSAttributedString(attachment: attachment)`.
The host proposes `context.availableWidth`, exposes `context.isSelected`, and
measures its content as that content changes. Use `.selectableBlock` for
noninteractive content that participates in the outer text selection, or
`.interactive` for native controls. Supply a Markdown representation for copy.
This primitive does not change the parser's supported Markdown syntax. Hosted
content must provide a finite intrinsic height at its proposed width.

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

### Adjusting Font Size (Zoom and Dynamic Type)

The view follows the system Dynamic Type setting on its own, including changes made while it is on screen. For your own “Zoom In” / “Zoom Out” controls, set a scale on the environment with `markdownTextScale`; it multiplies with Dynamic Type and applies live — the parse and a stream in progress are kept, only the fonts are rebuilt, and the selection survives:

```swift
import PicoMarkdownView

struct ZoomableMarkdownView: View {
    @State private var zoom: CGFloat = 1.0
    private let markdown = """
    ## Famous Formula

    Inline math: \\(E = mc^2\\)
    """

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Button("Zoom Out") { zoom = max(0.5, zoom - 0.1) }
                Button("Actual Size") { zoom = 1.0 }
                Button("Zoom In") { zoom = min(2.0, zoom + 0.1) }
            }
            PicoMarkdownView(markdown)
                .markdownTextScale(zoom)
        }
        .padding()
    }
}
```

To bake a scale into a theme instead, `MarkdownRenderTheme.scaled(by:)` returns a copy with every font size multiplied.

### Code Block Highlighting

Syntax highlighting is **on by default**. Fenced code blocks are tokenized by a bundled [Prism.js](https://prismjs.com) build running in JavaScriptCore (no WebView) and colored with a GitHub-flavored palette that adapts to light/dark mode. Roughly 65 languages are bundled — including Swift, Python, JavaScript/TypeScript, C/C++, C#, Java, Kotlin, Go, Rust, Ruby, PHP, SQL, YAML, Bash, and classics like BASIC and Pascal — and fence info strings are normalized before lookup, so `C++`, `objective-c`, `golang`, `vb.net`, and `swift title=example.swift` all resolve. Unknown languages render as plain monospaced text.

While a block streams, it re-highlights live; blocks larger than 16 KB render plain until the closing fence arrives, then get a single full highlight pass.

Built-in `CodeBlockTheme` presets:

- `.gitHub()` — GitHub Primer colors, light + dark (default)
- `.prismDefault()` — the previous Prism-flavored palette
- `.monospaced()` — no token coloring

On macOS, native code blocks have a Liquid Glass Copy button in a reserved header. It appears when the pointer is over the block or the control receives keyboard or accessibility focus. Copy exports the current code body as plain text, preserving whitespace and omitting Markdown fences; it also works while code is streaming. Right-click anywhere in a code block for **Copy code**. The code remains native selectable TextKit 2 text. The iOS rendering path is unchanged.

To swap palettes, disable highlighting, or plug in a different engine entirely, use `withCodeHighlighting` on the theme. `CodeSyntaxHighlighter` is the extension point — any engine that can turn `(code, language)` into an `AttributedString` works (Splash, tree-sitter, a native highlighter, …):

```swift
import PicoMarkdownView
import Splash

struct SplashCodeHighlighter: CodeSyntaxHighlighter {
    private let splash: SyntaxHighlighter<TextOutputFormat>

    init(theme: Splash.Theme) {
        self.splash = SyntaxHighlighter(format: TextOutputFormat(theme: theme))
    }

    func highlight(_ code: String, language: String?, theme: CodeBlockTheme) async -> AttributedString {
        guard language != nil else {
            return await PlainCodeSyntaxHighlighter().highlight(code, language: language, theme: theme)
        }

        return AttributedString(splash.highlight(code))
    }
}

let themed = MarkdownRenderTheme.default().withCodeHighlighting(
    codeBlockTheme: .monospaced(),
    codeHighlighter: AnyCodeSyntaxHighlighter(SplashCodeHighlighter(theme: .midnight(withFont: Splash.Font(size: 14))))
)

var body: some View {
    PicoMarkdownView(markdown, theme: themed)
}
```

Conformances must be `Sendable`; `highlight` is called off the main actor while blocks render.

The bundled grammar set is regenerated with `Scripts/bundle-prism.sh` (pins the Prism version, resolves component dependencies, and smoke-tests the output before writing). Never edit `Sources/PicoMarkdownView/Resources/prism-bundle.js` by hand — change the language list in `Scripts/bundle-prism.js` and rerun the script.

### Images

On macOS 27, a closed paragraph containing just one loaded image uses a TextKit 2 hosted attachment, including standalone images in lists and blockquotes. Images retain their aspect ratio and existing `imageMaxWidth` limit without initial upscaling. There are no inline image zoom controls; ordinary wheel scrolling and selection remain part of the document.

Use `onImageTap` to present an app-owned viewer. The callback receives the loaded source image, source URL, alternative text and optional title, so the app can implement its own lightbox, zoom, copying and export without fetching the image again:

```swift
#if os(macOS)
PicoMarkdownView(markdown)
    .onImageTap { activation in
        selectedImage = activation
    }
    .padding()
#endif
```

The callback is available on `PicoMarkdownView` on macOS. Apply it before general SwiftUI view modifiers such as `padding`. A plain click, keyboard activation or VoiceOver press requests the viewer; dragging still selects Markdown across the image. Without a callback, the image stays static. Pass `nil` to remove a callback without replacing the view. Document selection and the image context menu copy image Markdown, including URL, alternative text and title. Reference-style image syntax is normalized to an inline destination.

Images mixed with prose, multiple images in one paragraph, heading images, and table-cell images keep their existing rendering and do not invoke this callback. An open image paragraph keeps its native attachment until closure, since more streamed prose may still follow. Existing asynchronous image loading and block-local refreshes are reused. iOS image rendering is unchanged.

The macOS example owns a lightbox over its whole window content, with zoom, pan, Copy Image, Save and Escape dismissal. Mermaid and SVG retain their inline controls.

### Diagrams (Mermaid)

Fenced ```` ```mermaid ```` blocks are drawn as diagrams, **on by default**. Layout is done by a bundled build of [Pele](https://pele.run) — the Mermaid-compatible renderer written for Obsidian — running in JavaScriptCore like the Prism bundle. On macOS 27, a TextKit 2 hosted attachment draws the SVG paths and text directly with CoreGraphics; zoom redraws vectors at the new scale. iOS keeps its existing native bitmap attachments. Neither path uses a WebView or an SVG library. Every diagram type of Mermaid 12.1 is supported: flowcharts, sequence, class, state, ER, gantt, pie, git graphs, mindmaps, timelines, sankey, XY charts, quadrants, C4, block, and more.

A diagram renders once its closing fence arrives; while the block is still streaming it shows as a highlighted code block, so streaming cost is unchanged. Colors follow the `MarkdownRenderTheme` (code block foreground/background for text and node surfaces, `linkColor` for accents) in light and dark mode, labels are measured and drawn in the system font, and a flowchart that is too wide for the view is laid out vertically instead of being scaled down. Sources Pele cannot parse stay as code blocks.

On macOS, a connected Liquid Glass zoom pair and a separate Copy Mermaid button float in the top-right corner. They appear on pointer hover or keyboard focus and leave document selection available when hidden. The transparent host preserves the diagram’s own fills and borders. Zoom uses a short ease-out animation that respects Reduce Motion; zoom and pan stay inside a bounded viewport, respecting quote/list indentation. Normal wheel scrolling goes to the transcript until diagram navigation is activated and the drawing overflows its viewport. Escape resets navigation. Document selection includes the diagram atomically and copies its fenced Mermaid source. Math keeps its existing renderer.

To show a growing diagram while source streams on macOS:

```swift
let theme = MarkdownRenderTheme.default()
    .withMermaidRendering(.bestEffortDebounced(milliseconds: 200))

PicoMarkdownView(stream: makeStream, theme: theme)
```

Previews try completed source lines periodically and retain the last valid drawing while a statement is incomplete. Pele lays out each accepted prefix as a whole, so nodes can move as the graph grows. This does not reparse surrounding Markdown. Open previews stop beyond 8 KiB or 256 lines to bound layout work; the complete source is still rendered when the fence ends. The final render always runs regardless of the preview interval, and invalid final source falls back to code. The default `.onFenceClose` behavior and the iOS path are unchanged. The macOS example app enables progressive previews.

To keep mermaid fences as plain code:

```swift
let theme = MarkdownRenderTheme.default().withMermaidRendering(.disabled)
```

Diagram coverage runs in the normal unit tests and both CI jobs. `PeleSkillExamplesTests` covers all 32 bundled diagram families; `PeleDemoExamplesTests` renders the 58 published examples shown in the demo through the real Pele bundle and native SVG drawing, including the macOS vector stroke path. These regression samples do not prove 100% syntax, configuration or visual fidelity. The native SVG drawer deliberately skips unsupported browser features such as embedded images, filters, masks and `foreignObject`. Performance benchmarks live in `PicoMarkdownViewBenchmarks` and are excluded from CI; they measure tokenizer/assembler throughput, not diagram feature coverage.

The Pele bundle is regenerated with `Scripts/bundle-pele.sh` (pins the Pele version, verifies the npm tarball checksum, and smoke-tests the output before writing). Never edit `Sources/PicoMarkdownView/Resources/pele-bundle.js` by hand — bump the version in the script and rerun it.

#### Teaching your model to draw

Models already write standard Mermaid, but they do not know that diagrams render in your app, which newer types exist (swimlane, architecture, kanban, radar, treemap, venn, wardley, railroad, …), or which Mermaid features the native renderer leaves out. `Skills/pele-diagrams` is an optional [agent skill](https://agentskills.io) that covers exactly that: a short `SKILL.md` with trigger conditions, fence rules and a type picker, plus `references/diagram-types.md` with one verified example per type, loaded only when the model needs syntax. Copy the folder into your app's skills directory (PicoCore discovers it and injects the one-line description into the system prompt), into `.claude/skills/` for Claude Code, or feed `SKILL.md` into any system prompt. Every example in it is rendered through the bundled Pele by the test suite, so the skill cannot drift from the renderer.

### SVG graphics (macOS, opt-in)

To display a fenced `svg` block as a graphic on macOS 27, enable SVG rendering on the theme:

```swift
let theme = MarkdownRenderTheme.default().withSVGRendering()
PicoMarkdownView(markdown, theme: theme)
```

````markdown
A native Markdown paragraph before the graphic.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 120">
  <title>Two overlapping circles</title>
  <circle cx="95" cy="60" r="44" fill="#4f46e5"/>
  <circle cx="145" cy="60" r="44" fill="#06b6d4" opacity="0.75"/>
</svg>
```

A native Markdown paragraph after the graphic.
````

SVG rendering is off by default. Only `svg` fences opt into this presentation; raw HTML and ordinary code fences keep their existing behavior. iOS continues to display SVG fences as code, and math keeps its current renderer.

An open SVG fence remains source code while it streams. When the block closes, a valid, supported SVG becomes one TextKit 2 hosted attachment. Surrounding Markdown stays in the same text view; the tokenizer and assembler remain incremental. Resizing and zooming redraw the existing native image without reparsing the SVG source.

SVG uses the same bounded viewport, hover/focus Liquid Glass zoom pair, pan behavior and whole-block selection as Mermaid. **Copy SVG** copies its fenced Markdown; **Copy source** copies only the SVG body. A document selection spanning prose and a graphic expands the attachment to its fenced source. The SVG’s own colors and transparency are retained, so authors should choose colors that work against the page background and supply a descriptive `<title>` or `<desc>`.

The renderer uses AppKit’s native SVG image decoder, without a WebView or another package dependency. It supports static shapes and text, CSS styles, gradients, clipping, masks and internal references. It does not claim full browser SVG support: malformed content and unsupported features such as filters, `foreignObject`, scripts, animation and external resources stay visible as source code. The example app’s **SVG** page enables this option only for that page and includes supported graphics plus a source-fallback example.

### HTML previews (macOS, opt-in)

The optional `PicoMarkdownViewHTML` product displays closed raw HTML blocks and explicit `html-preview` fences as static HTML/CSS views inside the macOS TextKit 2 document. Ordinary `html` fences remain code; surrounding Markdown and math keep their existing renderers.

Add the additional product to your macOS target, then opt in:

```swift
import PicoMarkdownView
import PicoMarkdownViewHTML

PicoMarkdownView(stream: makeStream, embeddedBlockRenderers: [.htmlPreview])
```

Previews appear after the block closes, preserve source copying as a single selection unit, and reflow with the available width. Scripts, navigation, forms and network resources are disabled; images become alternative text. The core product remains WebKit-free, and iOS rendering is unchanged. See [HTML preview setup and behavior](Documentation/HTMLPreviews.md) for conditional dependencies, raw HTML boundaries, and examples. The macOS example app's **HTMLPreviews** document opts in separately from the other samples.

Opt-in [long-message performance](Documentation/HTMLPerformanceBenchmarks.md) and [viewport/lazy-chat benchmarks](Documentation/HTMLViewportBenchmarks.md) record streaming latency, readiness, page lifetime and host-process memory. They are not CI timing gates.

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
links — without forking the parser. Tags are rendered as tappable links and,
on tap, routed to your handler as a `TagReference` — the tag's `prefix` and
`identifier` (record ID). This mirrors how `[display](url)` links work: you get
the routable key, and own the lookup/display side. For `@[John Doe](u-2345)`
the reference is `prefix: "@", identifier: "u-2345"`; for the bare `@behlool`
it is `prefix: "@", identifier: "behlool"`.

```swift
PicoMarkdownView(markdown, tagPrefixes: [.mention, .hashtag])
    .onTagTap { tag in
        // tag.prefix == "@", tag.identifier == "behlool"
        showProfilePopover(for: tag.identifier)
    }
    .onOpenLink { url in
        openURL(url)            // ordinary [text](url) links still come here
    }
```

#### Defaults

Two prefixes are registered automatically:

- `@` — user mentions
- `#` — hashtags / topics

#### Opt-in prefixes

Pass an explicit set via the `tagPrefixes:` initializer parameter (forwarded to
the internal `MarkdownTokenizer`):

```swift
PicoMarkdownView(markdown, tagPrefixes: [
    .mention,                                  // @
    .hashtag,                                  // #
    .ticker,                                   // $  (collides with TeX; see below)
    .paired(open: "[[", close: "]]")           // [[wiki-link]]
])
```

Pass `tagPrefixes: []` to disable inline-tag recognition entirely.

#### Interaction callbacks

| Modifier | Fires when | Payload |
|---|---|---|
| `.onTagTap { TagReference in }` | a tag is tapped/clicked | `TagReference` (`prefix` + `identifier`) |
| `.onOpenLink { URL in }` | a regular link is tapped (and tags, if no `onTagTap` is set — they arrive as a `pico-tag://` URL) | `URL` |
| `.onTagHover { (TagReference?, CGRect?) in }` | **macOS only** — hover enters/exits a tag | `TagReference` + bounding rect on enter, `(nil, nil)` on exit |
| `.onLinkHover { (URL?, CGRect?) in }` | **macOS only** — hover enters/exits a regular link | `URL` + bounding rect on enter, `(nil, nil)` on exit |
| `.onContentSize { CGSize in }` | rendered content size changes (e.g. streaming adds a line) | content `CGSize` |

The hover rect is in the text view's coordinate space — anchor a popover
against it. On iOS the hover modifiers are no-ops (iOS has no hover).

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

### CommonMark conformance

The `PicoMarkdownViewConformance` test target parses every example of the
[CommonMark 0.31.2 spec](https://spec.commonmark.org/0.31.2/) twice, with
PicoMarkdownView and with cmark-gfm (through
[swift-markdown](https://github.com/swiftlang/swift-markdown), a test-only
dependency), and compares the block structure: kinds, nesting, heading levels,
code languages and plain text. The spec examples live in
`Conformance/Fixtures/commonmark-spec-0.31.2.json` (CC-BY-SA 4.0, see the
license file beside it).

```bash
swift test --filter PicoMarkdownViewConformance
```

The suite prints the score per spec section and acts as a ratchet:
`Conformance/Fixtures/commonmark-known-failures.txt` lists the examples that
currently differ. An example that stops matching fails the suite; so does one
that starts matching, until it is removed from the list. Deliberate deviations
(setext headings) are listed there like any other.

HTML blocks follow CommonMark: a line that starts with raw HTML (`<div>`,
`<details>`, a comment, a lone tag, …) begins a `BlockKind.htmlBlock` whose
lines are kept verbatim, Markdown included, until its end condition (for most
tags, a blank line). Its text arrives like code, in `BlockSnapshot.codeText`,
and PicoMarkdownView shows it as plain text in the body font by default.
The optional macOS [HTML preview adapter](Documentation/HTMLPreviews.md) can
render closed blocks when explicitly enabled.
