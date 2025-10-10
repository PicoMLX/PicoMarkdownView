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

## Phase 1 — Streaming Markdown Tokenizer (Parser Core)

Objective
Build a renderer-agnostic, incremental tokenizer for streamed Markdown that emits delta-shaped events suitable for low-latency UIs.
Target Swift 6.2 with strict concurrency; keep nearly all work off the main thread.

Scope (Phase 1 only)
    •    Input: unbounded UTF-8 chunks (LLM output), possibly splitting tokens.
    •    Dialect: CommonMark + GFM fences + GFM pipe tables; headings, lists, emphasis, links, blockquotes.
    •    Output: ordered delta events (BlockEvent) inside a ChunkResult, plus explicit openBlocks state.
    •    Non-goals: no rendering, TextKit/CoreText, attributes, syntax highlighting, math rendering.

⸻

Public API (revised)

// IDs & styles
public typealias BlockID = UInt64

public struct InlineStyle: OptionSet, Sendable {
  public let rawValue: UInt8
  public static let bold   = InlineStyle(rawValue: 1 << 0)
  public static let italic = InlineStyle(rawValue: 1 << 1)
  public static let code   = InlineStyle(rawValue: 1 << 2)
  public static let link   = InlineStyle(rawValue: 1 << 3)
}

public struct InlineRun: Sendable {
  public var text: String           // normalized LF; no CR
  public var style: InlineStyle     // flags like [.bold, .italic]
  public var linkURL: String?       // set iff style.contains(.link)
}

// Blocks & events (delta-shaped)
public enum BlockKind: Sendable {
  case paragraph
  case heading(level: Int)
  case listItem(ordered: Bool, index: Int?)
  case blockquote
  case fencedCode(language: String?)
  case table
  case unknown                       // fallback for unsupported blocks
}

public enum TableAlignment: Sendable { case left, center, right, none }

public enum BlockEvent: Sendable {
  // Start once per block
  case blockStart(id: BlockID, kind: BlockKind)

  // Append deltas while the block is open
  case blockAppendInline(id: BlockID, runs: [InlineRun])      // paragraph/heading/list/quote
  case blockAppendFencedCode(id: BlockID, textChunk: String)  // verbatim, no inline parsing

  // Table-specific deltas (GFM)
  case tableHeaderCandidate(id: BlockID, cells: [InlineRun])           // before separator
  case tableHeaderConfirmed(id: BlockID, alignments: [TableAlignment]) // after separator
  case tableAppendRow(id: BlockID, cells: [[InlineRun]])

  // Close once per block
  case blockEnd(id: BlockID)
}

// Chunk result & tokenizer protocol
public struct OpenBlockState: Sendable {
  public var id: BlockID
  public var kind: BlockKind
}

public struct ChunkResult: Sendable {
  public var events: [BlockEvent]
  public var openBlocks: [OpenBlockState]   // snapshot after this chunk
}

public protocol StreamingMarkdownTokenizer {
  mutating func feed(_ chunk: String) -> ChunkResult
  mutating func finish() -> ChunkResult
}

Rationale
    •    Delta events minimize chatter & avoid O(n) re-emits.
    •    InlineRun (ranges with style flags) is simpler for downstream than start/end markers.
    •    ChunkResult makes resumption explicit and AI-friendly.
    •    BlockID is an opaque UInt64 (monotonic counter internally).

⸻

Concurrency & threading (Swift 6.2)

Implement as an actor to isolate mutable state (rolling buffer, open block, ID counter). All work is non-MainActor.

public actor MarkdownTokenizer: StreamingMarkdownTokenizer {
  public func feed(_ chunk: String) -> ChunkResult { /* background */ }
  public func finish() -> ChunkResult { /* flush */ }
}

Do
    •    Keep parsing on the cooperative pool; avoid any UI coupling.
    •    Ensure all public types are Sendable.
    •    Write async tests; verify no main-thread hops.

Don’t
    •    Don’t block threads (no sleeps/semaphores).
    •    Don’t capture non-Sendable references.

⸻

Parser architecture
    •    FSM + bounded look-behind (≈256–1024 code units) to resolve ambiguous constructs (* vs literal, closing ```).
    •    Streaming guarantees: emit events only when constructs are unambiguous within the window.
    •    Tables:
    •    Header line → tableHeaderCandidate.
    •    Separator confirms → tableHeaderConfirmed(alignments:).
    •    Rows as tableAppendRow.
    •    Fallback: unsupported or malformed block → .unknown via blockStart(kind:.unknown) + blockAppendInline.

FSM diagram (overview)

[Paragraph] ──> [FenceOpen(lang?)] ──> [FenceBody] ──> [FenceClose] ──> [Paragraph]
     │
     ├──> [Heading(level)]
     ├──> [ListItem(ordered?)]
     ├──> [Blockquote]
     └──> [TableHeaderCandidate] ──> [TableConfirmed] ──> [TableRow]
                      │
                      └──> [Unknown] (fallback)

Each state defines: start trigger, end condition, allowed re-entry, emitted deltas.

⸻

Whitespace normalization
    1.    Convert \r\n → \n.
    2.    Apply block-level indent rules (per CommonMark).
    3.    Trailing spaces:
    •    ≥2 spaces at EOL ⇒ hard line break (emit a \n run).
    •    Exactly 1 trailing space ⇒ drop.
    •    Inside code spans/fenced code: preserve verbatim spacing.
    4.    Preserve whitespace for .unknown blocks.

⸻

Performance requirements
    •    Time: O(k) per chunk (k = chunk length); no O(n²) rescans.
    •    Memory: bounded look-behind; discard closed-block buffers.
    •    Allocations: reuse small buffers; avoid per-character slicing.
    •    Throughput target: ≥ 30–60 event batches/sec for ~2 KB/s streams on M-series.
    •    Determinism: same chunk sequence ⇒ identical event sequence.

⸻

Error tolerance & streaming edge cases
    •    Split tokens: **bo / ld** must yield bold “bold” once unambiguous.
    •    Unclosed fences: remain open across chunks; finish() must close with blockEnd.
    •    Malformed tables: if no separator arrives, degrade to .unknown or paragraph (choose one, document it).
    •    Backtracking cap: never reparse more than look-behind + current open block.

⸻

Golden behaviors (examples)
    •    Paragraph across chunks:
blockStart(.paragraph) → blockAppendInline("Hello ") → blockAppendInline("world") → blockEnd.
    •    Fenced code streaming:
blockStart(.fencedCode("swift")) → blockAppendFencedCode("let x=1") … → blockEnd.
    •    Table confirmation:
header candidate → alignment confirm → rows append → blockEnd.
    •    Unknown block:
blockStart(.unknown) → blockAppendInline(raw text) → blockEnd.

(Use the previously shared Golden Tests for full cases.)

⸻

Do & Don’t (Phase-1 implementation)

Do
    •    Keep tokenizer renderer-agnostic (no TextKit/CoreText imports).
    •    Emit delta-only events; never resend full block contents per chunk.
    •    Maintain stable BlockID across the life of a block.
    •    Normalize line endings and apply the hard-break rule.
    •    Document FSM transitions and look-behind policy in code comments.

Don’t
    •    Don’t expose provisional states in the public API.
    •    Don’t parse inline constructs inside fenced code.
    •    Don’t require downstream to diff text to find changes.
    •    Don’t rely on main thread in implementation or tests.

⸻

Deliverables (Phase 1)
    •    MarkdownTokenizer actor implementing StreamingMarkdownTokenizer.
    •    FSM with bounded look-behind and explicit transitions.
    •    Unit + fuzz tests (determinism, edge cases, concurrency).
    •    Lightweight benchmark (throughput/latency).
    •    Spec & comments explaining states, normalization, and error handling.

⸻

## Phase 1 Golden Tests

Conventions
    •    → means “feed returns”.
    •    Events abbreviated:
    •    BS(kind) = blockStart(id:X, kind: kind)
    •    BAI(runs:[...]) = blockAppendInline
    •    BAF(text:"...") = blockAppendFencedCode
    •    THE(align:[...]) = tableHeaderConfirmed
    •    THC(cells:[...]) = tableHeaderCandidate
    •    TAR(cells:[[...]]) = tableAppendRow
    •    BE = blockEnd
    •    runs:"text" is shorthand for [InlineRun(text:"text", style:[])]
    •    IDs are stable but unspecified in tests; compare shapes (kind/order/content), not actual ID numbers.

⸻

1) Simple paragraph across two chunks

Input
    1.    feed("Hello ")
    2.    feed("world")
    3.    feed("\n\n") (paragraph terminator)

Expected
    1.    → BS(.paragraph), BAI(runs:"Hello ")
    2.    → BAI(runs:"world")
    3.    → BE

openBlocks after #1 and #2 contains one paragraph; after #3 it’s empty.

⸻

2) Emphasis split across chunks (**bo / ld**)

Input
    1.    feed("**bo")
    2.    feed("ld** and more\n\n")

Expected
    1.    → BS(.paragraph) (no BAI yet if you buffer a few chars; or emit literal “**bo” if you don’t—pick one behavior and keep it deterministic)
    2.    → BAI(runs:[ "bold" styled(.bold), " and more" ]),
BE

Note
Either approach is acceptable:
    •    Option A (preferred): minimal look-behind turns the first chunk into nothing yet; emit only when unambiguous.
    •    Option B: emit provisional literal then correct later—not recommended in Phase 1 API since we removed provisional markers.

⸻

3) Fenced code block streaming

Input
    1.    feed("```swift\nlet x = 1")
    2.    feed("\nprint(x)\n")
    3.    feed("```\n\n")

Expected
    1.    → BS(.fencedCode(language:"swift")), BAF(text:"let x = 1")
    2.    → BAF(text:"\nprint(x)\n")
    3.    → BE

Rules
    •    Inside fences: verbatim; no inline parsing, no whitespace normalization other than CR→LF.

⸻

4) Heading then paragraph

Input
    1.    feed("# Title\nNext line of para")
    2.    feed("graph\n\n")

Expected
    1.    → BS(.heading(level:1)), BAI(runs:"Title"), BE,
BS(.paragraph), BAI(runs:"Next line of para")
    2.    → BAI(runs:"graph"), BE

⸻

5) Unordered list with two items over chunks

Input
    1.    feed("- First item\n- Sec")
    2.    feed("ond item\n\n")

Expected
    1.    → BS(.listItem(ordered:false, index:nil)), BAI(runs:"First item"), BE,
BS(.listItem(ordered:false, index:nil)), BAI(runs:"Sec")
    2.    → BAI(runs:"ond item"), BE

⸻

6) Table with delayed separator (GFM)

Input
    1.    feed("| Col A | Col B |\n")
    2.    feed("| --- | :---: |\n")  // confirm table + alignment
    3.    feed("| a1 | b1 |\n| a2 | b2 |\n\n")

Expected
    1.    → BS(.table), THC(cells:[ "Col A", "Col B" ])
    2.    → THE(align:[ .left, .center ])
    3.    → TAR(cells:[[ "a1","b1" ]]),
TAR(cells:[[ "a2","b2" ]]),
BE

Notes
    •    Before the separator line arrives, it’s a header candidate only.
    •    After confirmation, rows append as cells of InlineRuns with plain styles.

⸻

7) Unknown/fallback block

Input
    1.    feed(":::note\nCustom ext\n:::\n\n")

Expected
    1.    → BS(.unknown),
BAI(runs:":::note\nCustom ext\n:::\n"),
BE

Rule
Unsupported block syntaxes become .unknown with inline text appended. Preserve whitespace.

⸻

8) Hard line breaks (two trailing spaces)

Input
    1.    feed("line 1  \nline 2\n\n")

Expected
    1.    → BS(.paragraph),
BAI(runs:[ InlineRun("line 1", style:[]), InlineRun("\n", style:[]),   // represent hard break; you may emit as its own run or embed in text InlineRun("line 2", style:[]) ]),
BE

Rule
    •    Two trailing spaces at end of line produce a hard line break.
    •    Single trailing space is removed (outside code).

⸻

9) Mixed: paragraph → code fence mid-chunk → paragraph

Input
    1.    feed("Intro\n```js\nconst a=1")
    2.    feed("\n```\nOutro\n\n")

Expected
    1.    → BS(.paragraph), BAI(runs:"Intro"), BE,
BS(.fencedCode(language:"js")), BAF(text:"const a=1")
    2.    → BAF(text:"\n"), BE,
BS(.paragraph), BAI(runs:"Outro"), BE

⸻

10) finish() with open fence

Input
    1.    feed("```python\nprint(1)")
    2.    finish()

Expected
    1.    → BS(.fencedCode(language:"python")), BAF(text:"print(1)")
    2.    → BE   // close the open fence on finish

⸻

11) Link inline runs

Input
    1.    feed("See [site](https://ex.am) please\n\n")

Expected
    1.    → BS(.paragraph),
BAI(runs:[ "See ", InlineRun("site", style:[.link], linkURL:"https://ex.am"), " please" ]),
BE

⸻

12) Stress: long paragraph, incremental appends

Input
    •    100 chunks of "aaaa...a" (1,000 chars each), no newlines, then "\n\n"

Expected (shape)
    •    First chunk: BS(.paragraph), BAI(runs:"aaaa...")
    •    Chunks 2..100: only BAI(runs:"aaaa...")
    •    Final terminator: BE

Rule
    •    Never re-emit prior text; only append deltas.

⸻

Do / Don’t (test harness)

Do
    •    Run tokenizer inside an actor on background executor.
    •    Compare event sequences (shape + content), not exact BlockIDs.
    •    Fuzz chunk boundaries to ensure determinism matches single-shot parse of concatenated input.

Don’t
    •    Don’t assert rendering details (no attributes, no TextKit).
    •    Don’t rely on main thread.
    •    Don’t allow O(n²) behavior (e.g., full paragraph re-emits).

⸻


## Expected architecture
- Parser / AST builder. This can be based on existing parsers. Optimized for streaming
- Renderer. Optimized for streaming.
- Themes. Support light and dark mode, and code themes
- Interaction support. E.g. URL selections that can be handled by the main app using PicoMarkdownView
- If it makes sense, use existing libraries, but sparingly. Maybe the streaming part of cmark-gfm is a good candidate. Maybe it makes sense to create a simple incremental diff layer and only change the attributes on screen when needed. 

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
