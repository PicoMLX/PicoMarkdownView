# Validation Record

Date: 2026-09-30. Local toolchain: Xcode 27.0 (27A266a), Apple Swift 6.4
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

- [x] Full macOS `swift test`: 37 XCTest tests and 230 Swift Testing tests
  passed. Nine benchmark definitions also passed with measurement disabled.
- [x] Full iOS package tests on iPhone 16 Pro / iOS 18.5: xcresult reports
  268 tests passed, zero failures, skips, or runtime warnings. Parameterized
  test invocations are reported separately by Xcode.
- [x] macOS example app build with signing disabled: no compiler warnings.
- [x] iOS example app build for iPhone 17 Pro / iOS 26.4.1 with signing
  disabled: no compiler warnings.
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
  All 48 container/math fixtures pass every chunk split and character-at-a-time
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
footnote/continuation and list-owned nested-quote additions. Those additions
pass event/structure and native rendering tests, but their actual example-app
appearance still needs inspection. Pointer-only hover and a host's popover placement remain manual
checks: the example reports hover status but does not implement a popover.
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
