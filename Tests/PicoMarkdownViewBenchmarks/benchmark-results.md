# PicoMarkdownView Benchmark Results

Date format: `YYYY-MM-DD`

## How to Run

```bash
RUN_BENCHMARKS=1 swift test --filter MarkdownTokenizerBenchmarks
RUN_BENCHMARKS=1 swift test --filter MarkdownAssemblerBenchmarks
```

## Latest Results

Date: 2026-02-22

### Tokenizer (`Tests/Samples/sample1.md`)

- `chunkSize=128`: iterations=50, total=`1.086510 s`, average=`0.021730 s`, chunks=`27`
- `chunkSize=512`: iterations=50, total=`1.049722 s`, average=`0.020994 s`, chunks=`7`
- `chunkSize=1024`: iterations=50, total=`1.039730 s`, average=`0.020795 s`, chunks=`4`
- `example-word-stream`: iterations=50, total=`1.331099 s`, average=`0.026622 s`, chunks=`530`

### Assembler (`Tests/Samples/sample1.md`)

- `chunkSize=128`: iterations=25, applies=`700`, average/apply=`0.000014 s`, totalEvents=`4500`, maxBufferedBytes=`71375`, maxOpenBlocks=`1`, maxActiveBlocks=`1375`
- `chunkSize=512`: iterations=25, applies=`200`, average/apply=`0.000035 s`, totalEvents=`4025`, maxBufferedBytes=`69600`, maxOpenBlocks=`1`, maxActiveBlocks=`1350`
- `chunkSize=1024`: iterations=25, applies=`125`, average/apply=`0.000051 s`, totalEvents=`3950`, maxBufferedBytes=`69600`, maxOpenBlocks=`1`, maxActiveBlocks=`1350`
- `example-word-stream`: iterations=25, applies=`13275`, average/apply=`0.000003 s`, totalEvents=`15225`, maxBufferedBytes=`73575`, maxOpenBlocks=`1`, maxActiveBlocks=`1375`

## Notes

- `example-word-stream` uses the same whitespace-delimited chunking strategy as the example app streaming emulator in `MarkdownExample/MarkdownExample/MarkdownView.swift`.
- Record command output verbatim or summarize averages plus chunk counts for comparison over time.

## PR 9 Review Fixes (2026-09-30)

Apple Silicon, Xcode 27.0 / Apple Swift 6.4, debug build. Before and after
`RUN_BENCHMARKS=1 swift test --filter MarkdownTokenizerBenchmarks --no-parallel`,
50 iterations of `Tests/Samples/sample1.md` with no concurrent builds.

| Chunk strategy | Before average | After average |
| --- | --- | --- |
| 128 bytes (27 chunks) | 0.016371 s | 0.015720 s |
| 512 bytes (7 chunks) | 0.015300 s | 0.015568 s |
| 1024 bytes (4 chunks) | 0.015236 s | 0.015391 s |
| Example word stream (530 chunks) | 0.022420 s | 0.021944 s |

No material throughput regression. Changes buffer only ambiguous local quote,
task, math, and fence prefixes; already-emitted content is not reparsed.

### Fresh Review Follow-Up

Same toolchain and command, with serial benchmark cases and no concurrent builds.

| Case | Iterations | Before average | After average |
| --- | --- | --- | --- |
| sample1, 128-byte chunks | 50 | 0.015846 s | 0.015819 s |
| sample1, 512-byte chunks | 50 | 0.015499 s | 0.015421 s |
| sample1, 1024-byte chunks | 50 | 0.015419 s | 0.015307 s |
| sample1, example word stream | 50 | 0.022050 s | 0.021961 s |
| Quoted blank line, 1024 one-space chunks | 10 | 0.032092 s | 0.003656 s |
| Quoted blank line, 2048 one-space chunks | 10 | 0.117926 s | 0.007024 s |

These measurements describe the intermediate counted-whitespace-run fix.
It improved homogeneous padding but still retained unbounded alternating
spaces/tabs and replayed them when later text arrived. The bounded fallback
below supersedes that implementation.

### Bounded Quote Fallback and Line-Boundary Follow-Up

Same toolchain, serial execution, 50 sample iterations and 10 padding iterations.

| Case | Final average |
| --- | --- |
| sample1, 128-byte chunks | 0.016108 s |
| sample1, 512-byte chunks | 0.015774 s |
| sample1, 1024-byte chunks | 0.015612 s |
| sample1, example word stream | 0.022856 s |
| Quoted blank line, 1024 one-space chunks | 0.033111 s |
| Quoted blank line, 2048 one-space chunks | 0.047759 s |
| Alternating space/tab padding, 1024 chunks then one-character text | 0.035019 s |
| Alternating space/tab padding, 2048 chunks then one-character text | 0.050282 s |

The existing local buffer now permanently falls back to a raw `.unknown`
child at the configured look-behind cap (1024 UTF-8 bytes by default).
This costs more than the intermediate homogeneous-padding shortcut, but
retains neither arbitrary run history nor a delayed replay: a later `k = 1`
feed emits only that character. Doubling padding takes 1.44x for either
pattern. A regression with a 32-byte cap verifies bounded pending state
through 4096 alternating one-character chunks. Sample1 averages are 2-4%
above the fresh-review baseline, with no material throughput regression.
All 34 quoted fixtures also check every two-way split, character-at-a-time
equivalence, and repeat-sequence determinism.

### Additional Deferred Constructs and Container Boundaries

Same toolchain and serial command. The initial run had highly variable sample
averages (0.018995/0.016536/0.024117 s fixed chunks and 0.034025 s word stream);
the isolated repeat below returned to the prior range. No concurrent local
builds ran during either benchmark.

| Case | Repeat average |
| --- | --- |
| sample1, 128-byte chunks | 0.016513 s |
| sample1, 512-byte chunks | 0.016136 s |
| sample1, 1024-byte chunks | 0.016218 s |
| sample1, example word stream | 0.022391 s |
| Quoted blank line, 1024 one-space chunks | 0.032171 s |
| Quoted blank line, 2048 one-space chunks | 0.048037 s |
| Alternating space/tab padding, 1024 chunks | 0.034917 s |
| Alternating space/tab padding, 2048 chunks | 0.049970 s |
| Deferred quoted table candidate, 1024 one-character chunks | 0.024148 s |
| Deferred quoted table candidate, 2048 one-character chunks | 0.039157 s |

Sample1 is within -2% to +4% of the prior bounded-fallback checkpoint.
Doubling deferred table input takes 1.62x; homogeneous/alternating padding
takes 1.49x/1.43x. The cap applies to deferred quoted table/fence candidates
as well as ambiguous metadata and padding. Unquoted display-math opening
lines now also wait for the physical line boundary, with the same capped
fallback. Forty-three fixtures validate every chunk split, scalar-sized
feeds, repeat determinism, footnote boundaries, and list-owned nested quotes.

### Reference Definitions, Extension Prefixes, and Retention

After adding line-local reference-definition and partial `:::` buffering,
the same serial benchmark command produced these 50-iteration sample means:
128-byte chunks `0.016292 s`, 512-byte chunks `0.015889 s`, 1024-byte chunks
`0.016134 s`, and example word stream `0.022520 s`. No material regression
relative to the preceding checkpoint.

Ten-iteration means for 1024/2048 one-character chunks were `0.031940 /
0.046339 s` for spaces, `0.033908 / 0.048748 s` for alternating spaces/tabs,
and `0.023558 / 0.037978 s` for deferred table candidates. Doubling input
takes 1.44-1.61x. Capped-state regression coverage now also includes unfinished
reference labels, extension markers, and fence candidates, each with 4096
one-character feeds. Forty-eight fixtures pass every chunk split and repeat
determinism. A renderer regression evicts the quote parent and verifies that
later refreshes retain the children's quote level, attributes, and indentation.

### Verbatim Quoted Lines And Structured List Children

Reference definitions are no longer detected inside verbatim blocks. Partial
indented-code prefixes stay local until resolved, and eligible structured
children retain their list parent and content indentation. Sixty-one fixtures
now pass every chunk split and repeat determinism, including tab indentation.
Native math-attachment layout confirms the existing quote gutter is applied
even when the original attachment range has no paragraph-style attribute.

After the full platform suites, the final serial run measured sample1 means
of `0.017085 / 0.016464 / 0.016428 s` for 128/512/1024-byte chunks, and
`0.023340 s` for the example word stream. These are within 5% of the preceding
PR9 checkpoint. An initial run measured `0.018866 / 0.017375 / 0.017295 s`
and `0.024370 s`; the final code avoids redispatch checks once list content
has already been emitted.

The 1024/2048 one-character means are `0.032973 / 0.047931 s` for spaces,
`0.035200 / 0.050115 s` for alternating padding, and
`0.024794 / 0.039296 s` for deferred table candidates. Doubling input takes
1.42-1.58x. All measurements use the existing 50 sample / 10 padding iteration
counts, skip-build, and no concurrent build work.

### Fence/Heading Boundaries And Quoted Attachment Widths

After accepting longer matching fence closers, up-to-three-space ATX
indentation, and unmarked rules that interrupt lazy quotes, 72 quoted fixtures
pass every split and deterministic character streams. Native tests also cover
list-owned quote indentation and Mermaid request/attachment widths after
subtracting quote/list gutters at 160, 320, and 800 points.

The serial sample1 means are `0.016558 / 0.016348 / 0.016452 s` at
128/512/1024-byte chunks, and `0.022932 s` for the example word stream
(50 iterations). No material regression against the preceding PR9 checkpoint
was observed. The 1024/2048 one-character means are `0.033130 / 0.047848 s`
for spaces, `0.035121 / 0.049186 s` for alternating padding, and
`0.024107 / 0.038600 s` for deferred tables (10 iterations; doubling takes
1.40-1.60x). Benchmarks ran after all builds/tests, with skip-build and no
concurrent build work.

### Unmarked Quote Interrupts And Fence Indentation

After deferring unmarked definitions, terminating quotes before confirmed
display math, requiring list-content indentation for verbatim children, and
rejecting four-space/tab-indented fence closers, 88 quoted fixtures pass every
split and deterministic character streams. Unmarked definition candidates
also use the bounded raw fallback. Full suites pass: 34 XCTest + 219 Swift
Testing tests on macOS, and 254 test definitions on iOS Simulator.

The final serial sample1 means are `0.016990 / 0.016461 / 0.016272 s` at
128/512/1024-byte chunks, and `0.022946 s` for the example word stream
(50 iterations). This is within 3% of the preceding PR9 checkpoint.
The 1024/2048 one-character means are `0.033459 / 0.047753 s` for spaces,
`0.034801 / 0.049459 s` for alternating padding, and
`0.024461 / 0.039190 s` for deferred tables (10 iterations; doubling takes
1.42-1.61x). One initial alternating 2048 measurement was `0.059818 s`;
the repeat returned to the previous checkpoint's range. No material
regression was observed. Both runs used skip-build with no concurrent builds.

### Quoted Literal Content And List Source Order

Initial quoted indented code, list paragraphs after structured children, and
literal reference-definition text in unknown blocks are covered by 101
every-split fixtures. CommonMark 0.31.2 examples 250-251 confirm that reduced
markers may lazily continue a nested paragraph; that finding requires no
production change, and tests verify both continuation and blank-line exit.
Full suites pass: 34 XCTest + 221 Swift Testing tests on macOS, and 256
test definitions on iOS Simulator, including native quote-style checks.

The repeat serial sample1 means are `0.016943 / 0.016373 / 0.016510 s` for
128/512/1024-byte chunks, and `0.023405 s` for the word stream (50 iterations).
The initial run was slower (`0.025545 / 0.029444 / 0.026593 s`, word stream
`0.027793 s`); the unchanged-code repeat returned to the preceding range.
Quoted 1024/2048 means are `0.032396 / 0.046912 s` for spaces,
`0.034474 / 0.049321 s` for alternating padding, and
`0.025061 / 0.039811 s` for deferred tables (10 iterations, 1.43-1.59x).
Both runs used skip-build after full tests, with no concurrent build commands.

### Successor List-Content Prefix

A following paragraph's transition into another structured child now transfers
its resolved list-content prefix locally. The second fence therefore retains
verbatim code without adding container spaces. All 102 split/determinism
fixtures and both full platform suites pass; test-definition counts are
unchanged from the preceding checkpoint.

The serial sample1 means are `0.016941 / 0.016868 / 0.016583 s` at
128/512/1024-byte chunks, and `0.023644 s` for word streaming (50 iterations),
within 3% of the preceding repeat. Quoted 1024/2048 means are
`0.033018 / 0.047702 s` for spaces, `0.034982 / 0.050326 s` for alternating
padding, and `0.025569 / 0.039978 s` for tables (10 iterations, 1.44-1.56x).
The skip-build run followed all tests with no concurrent build commands.

### Quoted List Successors And Ordinary Image Gutters (be4450f)

All 109 quoted split/determinism fixtures pass. Full platform suites pass
34 XCTest + 223 Swift Testing definitions on macOS and 258 definitions on
iOS, including native wide-image bounds for quotes, lists, and tables.

Two serial skip-build runs followed the completed suites. Initial sample1
128/512/1024 means were `0.023502 / 0.029935 / 0.028278 s`, with word streaming
`0.033658 s`; the unchanged-code repeat measured `0.026528 / 0.025564 /
0.026061 s`, word streaming `0.038726 s` (50 iterations). These are elevated
relative to the preceding checkpoint; do not treat them as evidence of no
regression. The final combined-stack comparison is still required.

Repeat quoted 1024/2048 means were `0.071198 / 0.051777 s` for spaces,
`0.037901 / 0.051063 s` for alternating padding, and
`0.025604 / 0.040591 s` for tables (10 iterations). The inverted space pair
and run-to-run variation preclude a reliable throughput inference here.
No build commands ran concurrently with either measurement.

### Non-Lazy Quote Boundaries And Bounded List Ownership (8d4bc4c)

All 116 quoted fixtures and six capped list-child variants pass every split,
character streaming, and deterministic-event checks. Full suites pass 34
XCTest + 225 Swift Testing definitions on macOS and 260 definitions on iOS.

After all tests finished, a serial skip-build sample1 measurement returned
`0.017134 / 0.016624 / 0.016467 s` at 128/512/1024 bytes and `0.023309 s`
for word streaming (50 iterations). These are within 3% of the pre-slowdown
lower-branch checkpoint. The elevated timings above are not persistent in
the latest lower-branch run, so no cause is attributed without evidence.
The previously completed combined `74d158a` repeat also returned fixed-chunk
means within 3%; its word-stream mean was 12% higher and remains recorded
on PR11. The earlier required comparison is therefore complete, not pending.

Quoted 1024/2048 means are `0.032233 / 0.047057 s` for spaces,
`0.034688 / 0.049661 s` for alternating padding, and
`0.025049 / 0.040193 s` for tables (10 iterations, 1.43-1.60x). No build
commands ran concurrently. A final combined run will include these latest
state-local boundary fixes as well.

### GFM Thematic Indentation, Table Boundaries, And Ordered Interruption

All 134 quoted fixtures pass every split, character streaming, and deterministic
event checks. Full suites pass 34 XCTest + 226 Swift Testing definitions on
macOS and 261 definitions on iOS, with no failures or runtime warnings.

The serial skip-build sample1 means are `0.017025 / 0.016791 / 0.016623 s`
at 128/512/1024-byte chunks, and `0.023465 s` for word streaming (50
iterations), within 3% of the preceding stable lower-branch checkpoint.
Quoted 1024/2048 means are `0.032956 / 0.047910 s` for spaces,
`0.035014 / 0.050049 s` for alternating padding, and
`0.025662 / 0.039660 s` for tables (10 iterations, 1.43-1.55x).
Measurements followed both completed test suites with no concurrent builds.

### Successor Nested Quote And Footnote Matrix

The two additional review findings are fixed using only the current paragraph's
stored list owner/prefix and pending line. A 26-case successor matrix covers
fences, headings, math, and tables followed by paragraphs and nested quotes or
footnotes, including ordered/unordered/tab indentation and unindented controls.
It also exposed and fixed premature acceptance of tab-indented list-child math
openers. All 160 quote fixtures pass every split, character streams, and
determinism; native successor indentation passes on AppKit/UIKit. Full suites
pass 34 XCTest + 227 Swift Testing definitions on macOS and 262 on iOS.

After both suites completed, serial skip-build sample1 means were
`0.016795 / 0.016968 / 0.016759 s` at 128/512/1024 bytes and `0.023937 s`
for word streaming (50 iterations), within 3% of the preceding PR9 checkpoint.
Quoted 1024/2048 means are `0.034281 / 0.048277 s` for spaces,
`0.035655 / 0.050128 s` for alternating padding, and
`0.025425 / 0.040565 s` for tables (10 iterations, 1.41-1.60x).
The 1024-space mean is 4% higher than the preceding run; the final combined
comparison remains required. No build commands ran concurrently.

### Empty Markers And Complete Content Indentation

Four additional review findings are fixed: blank first-item markers cannot
interrupt quoted paragraphs, completed marker-only ATX headings are accepted,
quoted list children require the complete marker/content indentation, and
tab-expanded indentation distinguishes fences from indented code. All 284
quoted fixtures pass every split, character streaming, and deterministic-event
checks. Full suites pass 34 XCTest + 230 Swift Testing definitions on macOS
and 265 definitions on iOS, without failures or runtime warnings.

After both suites completed, serial skip-build sample1 means were
`0.016870 / 0.016206 / 0.015947 s` at 128/512/1024 bytes and `0.022586 s`
for word streaming (50 iterations). Quoted 1024/2048 means were
`0.033167 / 0.049245 s` for spaces, `0.035040 / 0.050650 s` for alternating
padding, and `0.024969 / 0.039950 s` for tables (10 iterations, 1.45-1.60x).
Sample and word means remain within 3% of the stable `3c00a0a` checkpoint.
The longer quoted cases are 13-18% slower than that checkpoint, although
within 3% of the preceding lower-branch run. A final combined-stack repeat
will check persistence; this run alone is not evidence of no regression.
No build commands ran concurrently.

### Marker Padding, Mixed Indentation, And Unquoted Math Closers (2026-10-01)

Three confirmed review defects are fixed using only current line/container
state. Quoted list content indentation includes complete one-to-four-space
marker padding, each continuation strips its own columns while preserving
residual tab columns, and display-math closing lines wait for newline/EOF and
reject non-whitespace suffixes. Existing top-level marker event semantics are
unchanged. All 329 quoted fixtures pass every split, character streams, and
determinism; valid/invalid dollar/command math closers have additional every-
split regressions. Full suites pass 34 XCTest + 233 Swift Testing definitions
on macOS and 268 on iOS, with no failures, skips, or runtime warnings.

The serial skip-build benchmark followed both completed suites. Sample1
128/512/1024-byte means were `0.016850 / 0.016538 / 0.016687 s`, with word
streaming `0.023722 s` (50 iterations). The 1024-byte and word means are about
5% above the preceding PR9 run; all four means are within 3% of `3c00a0a`.
Quoted 1024/2048 means were `0.033095 / 0.048016 s` for spaces,
`0.035764 / 0.050472 s` for alternating padding, and
`0.025424 / 0.039525 s` for tables (10 iterations, 1.41-1.55x), within 2%
of the preceding lower-branch run. The larger lower/combined differences
remain recorded; a final combined-stack comparison is required. No build
commands ran concurrently.

## Quote Boundaries, Physical Tab Columns, And Math Width (2026-10-01)

Six additional findings are fixed: active tables unwind on reduced quote
depth, unknown blocks retain extra markers, footnote successors preserve
eligible list ownership, wide-marker references resolve after local deindent,
quote indentation uses physical tab columns, and math attachments reserve
quote/list/table gutters and refresh on width changes. Literal code/unknown
tabs remain unchanged; only structural indentation is normalized. The table
row/list-opener finding is intentionally not changed: GFM section 4.10 and
GitHub's Markdown API both produce a separate list for `- item | value`.
Regression controls cover that report and an ordinary pipe row.

Full suites pass 34 XCTest + 238 Swift Testing definitions on macOS and 273
definitions / 688 invocations on iOS, with no failures, skips, or runtime
warnings. All 354 quoted fixtures pass every split, character streams, and
deterministic repeats. Native math glyph bounds and line heights pass at
160/320/800 points and a width where intrinsic math fits the full container
but would overflow after the quote gutter. Actual example inspection remains
blocked by the locked desktop.

An initial Character-based indentation normalization materially regressed
unresolved padding: spaces measured `0.111963 / 0.183902 s` and alternating
padding `0.178394 / 0.138520 s`. ASCII-byte prefix scanning and deferred tab
mapping removed that regression before committing. The final serial means
are sample1 `0.019084 / 0.016788 / 0.016640 s`, word streaming `0.023725 s`
(50 iterations), quoted spaces `0.027917 / 0.042493 s`, alternating padding
`0.027780 / 0.044525 s`, and deferred tables `0.025639 / 0.040096 s`
(10 iterations). Quoted padding is faster than the preceding lower-branch
checkpoint and table means are within 2%; the 128-byte sample is 13% higher,
while an earlier byte-scanning repeat measured `0.016923 s`. This variation
is recorded without attributing a cause. A final combined-stack repeat is
required after the remaining inline-parser fix. No local builds/tests ran
concurrently with these measurements.

## Marker-Only Items And Direct Wide-List Quotes (2026-10-01)

Initial and sibling `-`/`*`/`+` markers resolve as empty items only at newline
or EOF, while existing paragraphs retain empty-marker text. Nested quotes
strip their ordered owner's complete indentation before marker detection,
preserving physical tab alignment, ownership, and lazy continuations. All 384
quoted fixtures pass every split, character streams, and deterministic repeats.
Full suites pass 34 XCTest + 241 Swift Testing definitions on macOS and 276
definitions / 722 invocations on iOS, without failures, skips, or runtime warnings.

The suggested generic link-label cap was not applied: CommonMark's 999-character
limit is for reference labels, not inline link text. A 1000-character link/image
regression passes every split, character streams, and deterministic repeats.
Closed-bracket lookahead resolves after the next character; unclosed bracket or
destination buffering predates this change and is not fixed by truncating valid
inline text. This distinction is explained on the review thread.

Serial means after both completed suites were sample1
`0.016820 / 0.016387 / 0.016591 s`, word streaming `0.023856 s`
(50 iterations), quoted spaces `0.027284 / 0.042642 s`, alternating padding
`0.028011 / 0.044304 s`, and tables `0.025290 / 0.039974 s`
(10 iterations). All means are no more than 1% above the preceding final PR9
checkpoint, with the 128-byte sample faster. An overlapping benchmark attempt
was discarded and rerun after the iOS process completed; only this serial run
is used. The final combined stack still requires its own comparison.

The final empty-item assertion uses explicit Boolean locals to avoid a Swift
Testing optional-property macro warning. It accepts the parser's ordinary
plain newline run while rejecting non-whitespace/formatting in empty items.
Both complete suites were rerun successfully after that test-only correction;
parser code and the serial measurements above are unchanged.

## Sparse Width-Refresh Diff Checkpoint (2026-10-01)

Width staging records only block IDs with changed attributed presentations,
and the pipeline publishes those IDs rather than all retained blocks. Three
image/Mermaid/math cases reproduce nine all-block diffs before the fix; after
the fix each narrow/wide/reset update changes only its one attachment among
130 blocks. Snapshots, ordinary text, consecutive streaming, repeated-width
no-ops, and the six native TextKit selection scenarios still pass.

Full lower-branch suites pass 37 XCTest + 269 Swift Testing definitions on
macOS and 307 definitions / 776 invocations on iOS, with no failures, skips,
or runtime warnings. The fix is renderer/pipeline-only; tokenizer code and
inputs match the preceding serial PR9 benchmark checkpoint.
