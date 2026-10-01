# Validation Record

Date: 2026-10-01. Local toolchain: Xcode 27.0 (27A266a), Apple Swift 6.4
(swiftlang-6.4.0.34.1), macOS 26.6.2, Apple Silicon. Package minimums remain
macOS 15 and iOS 18. The example app has its existing, higher deployment
targets (macOS 15.6 and iOS 26).

## Changes In The Stack

1. `codex/ios-warning-cleanup`: modern UIKit link actions and warning cleanup.
2. `codex/blockquote-containers`: quoted headings, lists, and fences, retaining
   native child styling and quote decorations.
3. `codex/accessibility-text-scaling`: live Dynamic Type and host zoom without
   restarting parsing; preserve continuous selection on presentation updates.
4. `codex/math-isolation-validation`: opaque inline TeX, local scan resumption,
   split-delimiter regressions, table-math/zoom example, benchmarks, and
   refreshed documentation.

The earlier local-package/WizardKit build configuration fix is already on
`main` in `d6b403c` (Update dependencies), not duplicated in this stack.

## Completed Checks

- [x] Full macOS `swift test`: 37 XCTest tests and 278 Swift Testing tests
  passed. Nine benchmark definitions also passed with measurement disabled.
- [x] Full iOS package tests on iPhone 16 Pro / iOS 18.5: xcresult reports
  316 definitions / 850 invocations passed, zero failures, skips, or runtime
  warnings. Final package builds and both example builds have no compiler warnings.
- [x] macOS example app build with signing disabled: no compiler warnings.
- [x] iOS example app build for iPhone 17 Pro / iOS 26.4.1 with signing
  disabled: no compiler warnings.
- [x] iOS example zoom controls use 44-point minimum label frames and a
  rectangular content shape inside the button style; macOS retains compact
  borderless controls. Both examples rebuild without warnings and full package
  suites still pass. Direct-touch and VoiceOver checks remain manual.
- [x] Quoted blocks and math: every two-chunk split, one-character streams,
  repeated identical event sequences, and streamed/single-shot equivalence.
- [x] Long inline math emits once on closure; TeX commands and Markdown-like
  math contents do not leak plain runs. Table cells emit exactly their math.
- [x] Review regressions: quoted tables (confirmed, malformed, interrupted,
  and EOF), split task metadata, indented quote prefixes, display-math
  delimiters, and opening fence indentation pass every chunk split. The
  updated Blockquotes example visibly renders its tasks, table/math rows,
  display math, and relative fence indentation without clipping or raw TeX.
- [x] Follow-up quote regressions: same-line math suffixes and next physical
  lines survive; nested fence marker prefixes remain pending; compact/spaced
  rules preserve source order; initial footnotes retain definition metadata.
  All 384 container/math fixtures pass every chunk split and character-at-a-time
  equivalence. Alternating whitespace reaches a bounded, permanent raw
  fallback; a later one-character feed emits only that character, without
  replaying pending history. The example's math/rule/footnote sequence was
  inspected at 100% and 200% scale at 334-point width, with correct order
  and no clipping.
- [x] Additional review regressions: unquoted same-line math also waits for
  a physical line boundary without provisional events; deferred quoted table
  candidates obey the look-behind cap; footnotes close before adjacent
  definitions/unindented text and preserve indented soft-break continuations;
  ordered/unordered list items retain ownership of indented nested quotes.
  Event structure, bounded pending state, and every-split equivalence pass.
- [x] Quoted reference definitions remain hidden across split labels, URLs,
  and titles; partial `:`/`::` extension prefixes do not leak paragraphs.
  Reference/extension/fence candidates share the capped literal fallback.
  Refreshes preserve retained children's established quote levels and
  indentation after the closed quote parent is evicted.
- [x] Verbatim quoted code retains reference-definition text without registering
  links. Partial space/tab indentation stays pending until resolved. Structured
  children (fences, tables, headings, math, footnotes, rules, and unknown blocks)
  retain their list-item parent, depth, and rendered list indentation. The local
  continuation helper distinguishes indentation columns from string offsets.
- [x] The reported attachment-only quote-gutter failure is not reproducible:
  the existing attribute enumeration covers nil-valued ranges and adds a style
  there. A successful math-attachment regression verifies the first-character
  paragraph style and native glyph position outside the quote bar on both
  AppKit and UIKit. No production change was needed for that finding.
- [x] Longer matching backtick/tilde closers end quoted fences; shorter,
  mismatched, or non-whitespace-suffixed runs remain literal code. ATX headings
  accept up to three spaces; a four-space code control retains raw `#` text.
  Unmarked compact/spaced thematic breaks end lazy quote continuation and
  retain top-level ownership. All cases pass every chunk split.
- [x] Unmarked footnote/reference prefixes after quotes remain pending until
  resolved, including capped fallback for overlong labels. Confirmed unmarked
  display math ends the quote and retains its TeX and following paragraph.
  List-owned verbatim children close before nonblank lines without complete
  list-content indentation, including ordered items and tab controls. Fence
  closer checks preserve raw indentation: four-space/tab markers stay literal,
  while three-space closers remain valid. Every-split and repeated character
  streams cover these boundaries without revising emitted events.
- [x] Initial quoted space/tab-indented code opens a native code child without
  interrupting an existing paragraph. Following indented text after list-owned
  code/headings/math/tables opens a later paragraph child, preserving source
  order; unindented following text returns to the quote. Reference definitions
  inside unknown blocks remain literal and are not registered as links.
  Transitions from following paragraphs to successor structured children carry
  the resolved list-content prefix, preserving the second fence's verbatim text.
- [x] Markers after quoted list child paragraphs use the owning item's original
  indentation: unordered/ordered siblings remain siblings, while indented
  nested items retain their parent. List-owned rules mark their owner as having
  children and consume their line without adding parent inline text; following
  text opens a later paragraph. Tables close with their list owner when a
  nonblank line lacks its content indentation, rather than absorbing a sibling
  marker as a cell. All added cases pass split/character/determinism checks.
- [x] Reduced quote markers unwind before footnote/table/math/rule/unknown
  blocks, but retain inner levels for lazy paragraphs. Rules following list
  child paragraphs retain their owner only with resolved content indentation.
  At the look-behind cap, reference/table fallbacks preserve eligible list
  parents and exact raw payloads while discarding only container indentation.
  Six capped variants pass every split, character streams, deterministic
  events, and bounded-buffer checks in addition to the 384 quote fixtures.
- [x] GFM block boundaries: four-space/tab-indented thematic markers remain
  code, while three-space controls remain rules. Confirmed tables close before
  successor block openers without rejecting ordinary non-pipe body rows.
  Only ordered markers starting at 1 interrupt quoted paragraph text; initial
  and sibling ordered items retain ordinary marker detection. Top-level,
  quoted, and nested controls pass every split and deterministic event checks.
- [x] A 26-case successor matrix covers fences/headings/math/tables followed
  by paragraphs and then nested quotes or footnotes, using ordered/unordered
  markers, space/tab indentation, and unindented exit controls. Stored paragraph
  prefixes retain only eligible list owners; native successor quote indentation
  includes the list gutter only for owned children. Tab-indented list-child
  display-math openers stay pending until their physical line resolves. All
  cases pass every split, character streams, and deterministic-event checks.
- [x] Empty first-item markers stay within existing quoted paragraphs, while
  initial empty items and checkbox-only tasks remain valid. Marker-only ATX
  headings resolve only at newline or EOF. Structured quoted children require
  the complete ordered marker/content column, including successor paragraphs;
  under-indented children become quote-level siblings. Tab-expanded fence
  prefixes remain indented code at four columns. The 124 added fixtures cover
  every split, character streams, repeated events, and single-shot equivalence.
- [x] Quoted list indentation includes complete one-to-four-space marker
  padding; task/empty-item/five-space controls retain the correct content
  column. Each child line strips its own indentation columns, preserving a
  tab's residual columns and the fence's relative indentation. All 384 quoted
  fixtures pass split/character/determinism checks. Test fixtures use explicit
  loops after CI's older compiler rejected a nested inference expression.
- [x] Active tables unwind on reduced quote depth; unknown blocks preserve extra
  quote markers literally. Footnote successors retain eligible list owners, and
  wide ordered-item reference definitions resolve after local content deindent.
  Quote indentation uses physical four-column tab stops: one tab after `> `
  allows a heading, while two tabs open indented code. Code/unknown body tabs
  remain verbatim. All 384 fixtures pass split/character/determinism checks.
- [x] Marker-only quoted `-`/`*`/`+` items resolve at newline/EOF without
  interrupting existing paragraphs. Direct nested quotes under `1.`/`10.`/`123.`
  items retain ownership after full deindent, including tab, under-indented exit,
  and lazy-continuation controls. Explicit Boolean test assertions allow only
  plain whitespace (including ordinary newline runs) in empty items.
- [x] Two additional review suggestions are not applied. GFM ends a table before
  `- item | value`; GitHub's own Markdown API confirms the separate list, with
  top-level/quoted regressions and an ordinary-row control. CommonMark's
  999-character limit is for reference labels, not inline link text: 1000-character
  inline link/image regressions pass every split, character streams, and repeats.
  General unclosed-link buffering predates the changed closed-bracket lookahead;
  truncating valid inline text is not an appropriate fix. Both threads explain why.
- [x] Unquoted display-math closing lines wait for newline/EOF. Dollar and
  command markers with non-whitespace suffixes remain math content rather
  than swallowing the rest of the line. Both forms pass every split, character
  streams, deterministic repeats, and valid newline/EOF controls.
- [x] Plain text after closed inline math survives unfinished emphasis/code
  delimiters. The pending UTF-8 slice was already correct; the final literal
  fallback now retains the unflushed plain start. Ten dollar/command and
  ASCII/non-ASCII/combining-mark cases reproduce the defect before the fix
  and pass direct inline parsing, every scalar split, tokenizer output, and
  deterministic event checks afterward.
- [x] Post-math punctuation context survives combining marks, variation selectors,
  spacing marks, and ZWJ scalars across chunk boundaries. A trailing underscore
  waits for its following character. Forty dollar/command inline/display variants
  pass direct parsing, every scalar split, scalar/character streams, and repeated
  tokenizer events, including the exact `p$z$` + combining-mark + `_foo_` report.
  Only local cursor state is retained; emitted runs are not reparsed or corrected.
- [x] Inline/display/table math attachments reserve quote/list/cell gutters and
  refresh their bounds on content-width changes without changing snapshots.
  Native AppKit/UIKit glyph bounds and line heights pass at 160/320/800 points
  and at a width where intrinsic math fits the container but not the quote gutter.
  Actual latest example-app appearance remains unverified while the desktop is locked.
- [x] Ordinary images reserve quote/list gutters before sizing attachments;
  list bullet columns and table cell padding/separators are also reserved.
  Native AppKit/UIKit glyph bounds at 160, 320, and 800 points stay inside the
  available width for direct quotes, list-owned paragraphs, list items, and
  one/two-column tables; image aspect ratios and retained originals survive.
- [x] The reported reduced-marker quote-depth failure is a false positive:
  CommonMark 0.31.2 examples 250-251 permit missing inner markers on lazy
  paragraph continuations. The reported two-level case and the spec's
  three-level case retain their nesting and native quote styles; a blank-line
  control exits the nested paragraph. No production change is appropriate.
- [x] List-owned nested quotes retain non-quote ancestor indentation without
  double-applying quote gutters. Quoted/list-owned Mermaid requests and
  attachment bounds reserve gutters at widths 160, 320, and 800 points;
  native AppKit/UIKit glyph bounds remain inside the available line width.
- [x] Math cursors resume at UTF-8 byte boundaries even when combining marks,
  variation selectors, or ZWJ continuations extend a prior grapheme. Scalar
  chunk tests preserve TeX, match single-shot output, and repeat identical
  events; unclosed grapheme math flushes once as literal text. The isolated
  combining-mark scanner benchmark no longer exhibits quadratic rescans.
- [x] Opening math delimiters also use UTF-8 boundaries. Seven additional
  combining-mark/variation-selector cases cover dollar and command openers,
  every scalar split, repeat determinism, and unclosed literal flushing.
  The reported `p$$` followed by a combining mark now matches single-shot
  parsing without an incorrect empty inline-math run.
- [x] Live scaling retains block IDs and parser state, including scale updates
  overlapping incoming chunks. Code, headings, table/display math, and quotes
  scale together.
- [x] Suspended image renders cannot overlap scale/feed/refresh operations;
  scaling across the 1,000-closed-block retention boundary preserves complete
  text, unique IDs, and consistent fonts. Unsupported inline/display math
  fallbacks retain the scaled font without changing parser output.
- [x] Monotonic update versions reject stale publication on MainActor,
  including a delayed full replacement after a newer flush. Canceled and
  superseded queued scales skip rendering; committed results still publish.
  Deterministic paused-image tests exercise cancellation bursts, and canceled
  finite-input initialization still completes the initial document.
- [x] In-flight scale refreshes stage presentations without mutating the active
  cache, check cancellation/supersession between blocks, and suppress obsolete
  publication. Cancellation during the commit handoff rolls back the complete
  previous presentation. Paused-image tests verify only one obsolete block is
  rendered, same-size retries succeed, snapshots/IDs/selection survive, and
  canceling without a replacement retains the old presentation. A deterministic
  commit/rollback test verifies restoration and rejection of stale rollback.
- [x] Native controllers detect publication-version gaps and synchronize all
  cached block presentations in the latest eligible diff, without reparsing or
  whole-document replacement for presentation-only gaps. Closed-block fonts
  remain scaled when MainActor delivery is reversed or SwiftUI coalesces
  flushes; both TextKit entry points retain complete text and selection on
  AppKit/UIKit. Structural gaps use the existing backend synchronization path.
- [x] Full replacements carry the snapshot's document version through the model
  and native wrappers, including coalesced replacement/delta flushes. Tests on
  both TextKit entry points verify the next consecutive one-block update stays
  narrow while genuine gaps still repair cached presentations.
- [x] Resuming a paused replacement records the synchronized snapshot version
  in both native controller paths, including unchanged-content replacements.
  Six TextKit 1/2 scenarios reproduced the false all-block gap before the fix
  and now retain narrow consecutive diffs after pause/resume and paused feeds.
- [x] Width refreshes publish incremental diffs instead of full replacements.
  A view-model/native-controller regression reproduced truncated selection
  before the fix and now preserves whole-document and two attachment-overlap
  selections across narrowing, widening, and nil reset. Image, real Mermaid, and math
  cases pass both TextKit entry points on AppKit/UIKit, with unchanged text,
  snapshots, replacement tokens, and correctly resized attachments.
- [x] Width staging records and publishes only changed block IDs. Three 130-block
  image/Mermaid/math cases reproduce nine all-block diffs before the fix and now
  emit exactly one changed attachment per update. Ordinary blocks and snapshots
  remain unchanged; repeated widths are no-ops and subsequent feeds retain their
  consecutive diff versions. Native selection tests still cover both TextKit paths.
- [x] Queued width refreshes register request revisions before the operation
  gate. Deterministic paused-image tests queue 20 obsolete width buckets, a
  latest width or nil reset, and a feed: only the latest queued width renders,
  repeated widths do no further work, and the feed text is retained.
- [x] In-flight width refreshes stage cached block presentations, check
  supersession before/after each image or Mermaid render, and suppress obsolete
  commits. Supersession during the commit handoff restores the previous width,
  bucket, builder, and presentation. Paused-image tests cover latest-width/nil
  resets, only one obsolete render, retained fonts/IDs/snapshots/selection/feed
  text, same-width retry, previous-width restoration, and stale rollback.
- [x] Width-only staging copies the active builder's configuration while
  preserving its current image/Mermaid providers and their caches. Text-scale
  staging still creates a scaled default Mermaid provider. A real-backend test
  verifies identical cached image objects for two diagrams across widths
  48/80/128/nil, commit/rollback, and scaled-width refreshes; scaling produces
  distinct images and retains the scaled suffix font. This renderer-only fix
  does not change tokenizer behavior or benchmark inputs.
- [x] Successfully rendered paragraph/quote/table images survive shared-cache
  eviction across repeated scales and narrow/wide content-width updates.
  The renderer retains original image results only while their blocks survive;
  a discarded-block regression verifies old results are released. The image
  retention fix does not change tokenizer code or benchmark inputs/results.
- [x] Image retention updates URL reference counts per affected block instead
  of scanning all retained blocks/cache entries on every eviction. The
  nil-provider path creates no URL sets. Shared URLs survive until their last
  referencing block is discarded; refreshed blocks release obsolete image
  references. Both additional lifecycle regressions pass on AppKit and UIKit.
- [x] Theme/code baselines are independent of ambient accessibility scaling:
  the macOS body baseline is 13 points; UIKit uses the large-category baseline.
  Initial effective scale is installed before finite, chunked, or streamed
  input is rendered. Hosted UIKit tests verify that every first nonempty
  publication already has the requested scale; image work is not duplicated.
- [x] Hosted SwiftUI iOS view: Dynamic Type changes the existing native view's
  font, reports content sizing, and preserves selection across paragraphs.
- [x] Both macOS text-view entry points: native link/tag click routing, hover
  glyph rectangles in view coordinates, hover deduplication/exit, continuous
  selection, and display-only configuration.
- [x] UIKit primary actions: custom callbacks run on action invocation; the
  default action is preserved without a custom handler.
- [x] Native table/math layout: widths 320 and 800 points, scales 1 and 2,
  both text-view entry points. Attachment line heights cover attachment bounds.
  Exported narrow/large-text and wide/default-text snapshots were inspected:
  no raw TeX duplication, clipped equations, or overlapping quote children.
- [x] Tokenizer and assembler benchmarks refreshed; see
  `Tests/PicoMarkdownViewBenchmarks/benchmark-results.md` for method and results.
- [x] Actual macOS example app: clicking `@rocket` reports identifier `rocket`;
  clicking the formatted `@Jane Roe` tag reports identifier `u-9`. Select-all
  covers the entire Tags document, including headings, lists, and quotes.
- [x] Actual macOS TableMath example at 334-point content width: 100% and 200%
  zoom show complete, unclipped fractions, sums, integrals, and Greek symbols,
  without raw TeX duplication. Content-size callbacks update after zoom. Drag
  selection crosses from the heading through both table rows.

## Remaining Manual Check

The desktop was initially locked, then became available for the interaction
checks above. It locked again before visual inspection of the latest adjacent
footnote/continuation, verbatim-code, unmarked definition/math interruption,
fence-boundary, initial-code, source-order, structured list-child/Mermaid,
empty-heading/marker, wide-marker/tab-indentation, mixed list-padding,
direct wide-list quotes, physical quote tab stops, and constrained math-width
additions. Those additions
pass event/structure and native rendering tests, but their actual example-app
appearance still needs inspection. Pointer-only hover and a host's popover placement remain manual
checks: the example reports hover status but does not implement a popover.
The iOS zoom-control touch area and VoiceOver interaction also need a device
or Accessibility Inspector check; their minimum frames are verified in source.
Native tests exercise the hover callbacks and glyph geometry, not a consuming
app's coordinate conversion or popover anchoring.

Minimum-OS macOS 15 runtime behavior and physical-device interaction were not
tested locally. iOS 18.5 package tests cover the older supported iOS generation.

## Reproduction

```sh
swift test
RUN_BENCHMARKS=1 swift test --filter MarkdownTokenizerBenchmarks --no-parallel
RUN_BENCHMARKS=1 swift test --filter MarkdownAssemblerBenchmarks --no-parallel
xcodebuild test -scheme PicoMarkdownView \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.5' \
  -only-testing:PicoMarkdownViewTests -parallel-testing-enabled NO \
  -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO
xcodebuild -project MarkdownExample/MarkdownExample.xcodeproj \
  -scheme MarkdownExample -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MarkdownExample/MarkdownExample.xcodeproj \
  -scheme MarkdownExample -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

To export native AppKit layout snapshots, create an output directory and set
`PICO_LAYOUT_SNAPSHOT_DIR` when running
`swift test --filter TextKitInteractionTests.testMathAttachmentsFitTableRowsAtBothWidthsAndScales`.
