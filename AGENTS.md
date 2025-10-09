# PicoMarkdownView

This goal of this project is to create a SwiftUI view that displays plain text, markdown and KaTeX (a LaTeX subset). It is to be used by SwiftUI chat client apps.

## Non negotiable:

- Written for SwiftUI on both macOS 15 Sequoia and iOS 18 and newer
- Optimize speed and performance for streaming. Minimize the work done by the view and parser/tokenizer so there is no need to parse or repaint the view every time a new chunk is added. Ideas to consider:
    - Incremental tokenizer & parser (append-only): maintain a rolling buffer (rope/piece-table) and resume parsing from the last stable block boundary. No full reparse on each chunk.
    - AST → AttributedString translator that patches only changed ranges (use NSTextStorage edits in a single textContainer).
    - Deferred layout: coalesce edits on the main thread; batch apply with beginEditing()/endEditing() to avoid repeated layout.
- Continuous selection. Some SwiftUI Markdown libraries only allow the user to select up to one paragraph, because every paragraph is a separate view. That's suboptimal. Make sure the user can select all the text in the PicoMarkdownView
- If you need to go down to the level of UIKit or AppKit (or lower) for feature or performance reasons, do so, but keep in mind that the project should compile on both macOS and iOS and run in a SwiftUI environment
- Do not add text editing capabilities. This library is purely for displaying text, markdown and KaTeX
- Keep the architecture it simple. If you propose an MVVM architecture, I will turn you into a can opener

## Other rules:

- Don't overdo it. PicoMarkdownView should be compatible with OpenAI's ChatGPT. If a Markdown or KaTeX feature isn't supported by ChatGPT, don't support it in PicoMarkdownView.
- Make it extendable so if we want to show other data (e.g. images, flow charts, SVG, etc.) we can add that in a future version
- Keep in mind that apps using PicoMarkdownView will be showing a list of PicoMarkdownViews in a List or LazyVStack. We'll be using one single PicoMarkdownView per message.
- The text size should be adjustable programmatically and adjust to the user's accessibility setting if available

## Expected architecture
- Parser / AST builder. This can be based on existing parsers. Optimized for streaming
- Renderer. Optimized for streaming.
- Themes. Support light and dark mode, and code themes
- Interaction support. E.g. URL selections that can be handled by the main app using PicoMarkdownView
- If it makes sense, use existing libraries, but sparingly. Maybe cmark-gfm is a good candidate.

## Supported standards

- Markdown
    - Use CommonMark with GitHub Flavored Markdown (GFM) extensions variant (headings, emphasis, links, images, code fences, blockquotes, hr, tables, task lists, strikethrough, autolinks, footnotes)
    - Ignore potentially unsafe or nonportable features:
        - Raw HTML (especially scripts, <style>, JS) — usually sanitized or disallowed
        - Arbitrary attribute syntax (e.g. {: .class} or id= in Markdown Extra / Pandoc) — many renderers drop them
        - Embedded scripting / dynamic JS / widgets
- KaTeX
    - Limit support to the math mode
        - Thought: can we treat math as inline/block attachments in the attributed string?
        - Support Standard math functions: \frac, \sqrt, \sum, \int, etc.
        - Support Greek letters and symbols.
        - Support Environments like \begin{aligned} and \begin{matrix}.
        - Support \text{} for inline text inside equations.
        - Do not support \usepackage, \def, \newcommand, \input, or anything that requires LaTeX macro expansion.
        - Do not support TikZ, pgfplots, or text-mode typesetting.
        - Full  specifications: https://katex.org/docs/supported.html
    
    
## Benchmarking
- Performance of the parser and tokenizer is critical. Use Swift test to benchmark changes to the parser.
- Use Tests/Samples/sample1.md to benchmark
- Keep track of the benchmarks in a file so we can compare them before and after changes.
- For reference, one of the faster Markdown parsers (MD4C) got these results in seven years ago. You should be able to beat these results by a wide margin
```
1000 iterations =   0.010s
 10000 iterations =   0.112s
100000 iterations =   1.088s
```
 
## Development Patterns & Constraints

Coding style
- If you ever suggest using MVVM, you're going through the emergency airlock

## Git Workflow Essentials

1. Branch from `main` with a descriptive name: `feature/<slug>` or `bugfix/<slug>`.
2. Force pushes **allowed only** on your feature branch using
   `git push --force-with-lease`. Never force-push `main`.
3. Keep commits atomic; prefer checkpoints (`feat: …`, `test: …`).

## Evidence Required for Every PR

- Swift code compiles
- All tests are completed

## What not to do
- No editing.
- No raw HTML passthrough beyond a tiny safe subset (<br>, <kbd>, maybe <sup>/<sub> mapped to attributes).
- No WebView dependency
- No MVVM (seriously)


## References
Libraries that may be relevant. Feel free to use the libraries or code if that makes sense:
    - https://github.com/swiftlang/swift-markdown
    - https://github.com/gonzalezreal/swift-markdown-ui
    - https://github.com/commonmark/cmark
    - https://github.com/1Password/markdown-benchmarks
