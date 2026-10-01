# PicoMarkdownView Benchmark Results

Date format: `YYYY-MM-DD`

## How to Run

```bash
RUN_BENCHMARKS=1 swift test --filter MarkdownTokenizerBenchmarks --no-parallel
RUN_BENCHMARKS=1 swift test --filter MarkdownAssemblerBenchmarks --no-parallel
```

## Latest Results

Date: 2026-09-30

Environment: Apple Silicon, macOS 26.6.2, Xcode 27.0 (27A266a), Apple Swift
6.4 (swiftlang-6.4.0.34.1). Debug builds, benchmarks run serially with
`--skip-build --no-parallel`; test/build jobs were idle during measurement.

### Tokenizer Before / After

Baseline: `fd989de` (warning cleanup, before quoted-block and inline-math fixes).
Final: `codex/math-isolation-validation`. The baseline was built from the same
tokenizer sources in an isolated tokenizer-only SwiftPM target to avoid a
second renderer/dependency build. Both use the same benchmark harness and
compiler. These are local single-run comparisons, not statistical estimates.

| Input | Iterations | Chunks | Before total / average (s) | After total / average (s) |
| --- | ---: | ---: | ---: | ---: |
| sample1, 128-byte chunks | 50 | 27 | 0.796284 / 0.015926 | 0.820754 / 0.016415 |
| sample1, 512-byte chunks | 50 | 7 | 0.762138 / 0.015243 | 0.776323 / 0.015526 |
| sample1, 1024-byte chunks | 50 | 4 | 0.757207 / 0.015144 | 0.775012 / 0.015500 |
| sample1, example-word-stream | 50 | 530 | 1.179166 / 0.023583 | 1.110242 / 0.022205 |
| inline math, 8192 bytes in 64-byte chunks | 10 | 130 | 1.398879 / 0.139888 | 0.037300 / 0.003730 |
| inline math, 16384 bytes in 64-byte chunks | 10 | 258 | 4.115524 / 0.411552 | 0.074445 / 0.007444 |

The sample fixture differs by approximately +2-3% for fixed-size chunks and
-6% for word streaming, within local run variation. No material regression
was observed. The long-math cases are approximately 38x and 55x faster;
doubling the math body now doubles runtime instead of repeatedly scanning
the growing pending body. Opening/closing delimiter chunks are included in
the chunk counts; the byte counts describe only the TeX body.

A separate paired comparison before/after only the quoted-block change
(`fd989de` to `b647576`) measured average seconds of 0.016568 -> 0.015148
(128-byte), 0.014848 -> 0.014454 (512-byte), 0.014601 -> 0.014630 (1024-byte),
and 0.020058 -> 0.020866 (word streaming). No material regression was observed.

### Assembler (`Tests/Samples/sample1.md`)

- `chunkSize=128`: iterations=25, applies=`700`, average/apply=`0.000009 s`, totalEvents=`4550`, maxBufferedBytes=`70075`, maxOpenBlocks=`1`, maxActiveBlocks=`1400`
- `chunkSize=512`: iterations=25, applies=`200`, average/apply=`0.000023 s`, totalEvents=`4075`, maxBufferedBytes=`68450`, maxOpenBlocks=`1`, maxActiveBlocks=`1375`
- `chunkSize=1024`: iterations=25, applies=`125`, average/apply=`0.000035 s`, totalEvents=`4000`, maxBufferedBytes=`68450`, maxOpenBlocks=`1`, maxActiveBlocks=`1375`
- `example-word-stream`: iterations=25, applies=`13275`, average/apply=`0.000002 s`, totalEvents=`14850`, maxBufferedBytes=`71725`, maxOpenBlocks=`1`, maxActiveBlocks=`1400`

The assembler harness reports aggregate metrics across iterations. Event
counts can change with corrected parsing; they are not throughput alone.

## Historical Results

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

## PR 11 Review Fix (2026-09-30)

Same local toolchain and debug configuration as above; no concurrent builds.
Before and after commands:
`RUN_BENCHMARKS=1 swift test --skip-build --filter MarkdownTokenizerBenchmarks --no-parallel`.

| Case | Iterations | Before average | After average |
| --- | --- | --- | --- |
| sample1, 128-byte chunks | 50 | 0.015610 s | 0.015326 s |
| sample1, 512-byte chunks | 50 | 0.015498 s | 0.014916 s |
| sample1, 1024-byte chunks | 50 | 0.015285 s | 0.014887 s |
| sample1, example word stream | 50 | 0.022035 s | 0.022038 s |
| Inline math, 128 chunks / 8192 bytes | 10 | 0.003750 s | 0.002771 s |
| Inline math, 256 chunks / 16384 bytes | 10 | 0.007573 s | 0.005489 s |
| InlineParser math, 512 combining-mark chunks | 20 | 0.021543 s | 0.000546 s |
| InlineParser math, 1024 combining-mark chunks | 20 | 0.082128 s | 0.000922 s |

The last two cases isolate the inline scanner from the block FSM: each new
scalar extends the same grapheme. Before the fix, conversion of the saved
UTF-8 offset to a Character boundary failed and rescanned the body. Doubling
chunks took 3.81x before and 1.69x after the fix. Byte-based math cursors keep
scan work local to new input; byte-based line emission also preserves scalar
chunks that do not increase the line's Character count. Sample1 shows no
material throughput regression.
## PR 9 Fresh Review Follow-Up (2026-09-30)

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

## Combined Stack Checkpoint 6e4def1 (2026-09-30)

Serial tokenizer benchmarks on the same toolchain, after propagating all
review fixes through PR 11. Sample averages use 50 iterations; whitespace
and long-math cases use 10; the isolated combining-mark scanner uses 20.

| Case | Average |
| --- | --- |
| sample1, 128-byte chunks | 0.015885 s |
| sample1, 512-byte chunks | 0.015714 s |
| sample1, 1024-byte chunks | 0.015687 s |
| sample1, example word stream | 0.023153 s |
| Inline math, 128 chunks / 8192 bytes | 0.003109 s |
| Inline math, 256 chunks / 16384 bytes | 0.005985 s |
| InlineParser math, 512 combining-mark chunks | 0.000535 s |
| InlineParser math, 1024 combining-mark chunks | 0.000916 s |
| Quoted blank line, 1024 one-space chunks | 0.033212 s |
| Quoted blank line, 2048 one-space chunks | 0.043448 s |
| Alternating space/tab padding, 1024 chunks then one-character text | 0.035591 s |
| Alternating space/tab padding, 2048 chunks then one-character text | 0.045672 s |

The first sample run contained a 0.018056 s outlier for 1024-byte chunks;
the immediate isolated repeat measured 0.015687 s. The table records that
repeat for all three fixed chunk sizes. Sample1 is within 0-5% of the
fresh-review baseline. Long math takes 1.93x when input doubles; the isolated
Unicode scanner takes 1.71x, and padding takes 1.28-1.31x. No material
throughput regression or renewed unbounded padding history was observed.
## PR 9 Additional Deferred Constructs and Container Boundaries

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

## Combined Stack Checkpoint f83433f (2026-09-30)

All tokenizer benchmark cases run serially with no concurrent builds, after
propagating the four additional PR9 fixes into PR11. Iteration counts match
the preceding combined-stack checkpoint.

| Case | Average |
| --- | --- |
| sample1, 128-byte chunks | 0.016627 s |
| sample1, 512-byte chunks | 0.016457 s |
| sample1, 1024-byte chunks | 0.016197 s |
| sample1, example word stream | 0.022839 s |
| Inline math, 128 chunks / 8192 bytes | 0.002923 s |
| Inline math, 256 chunks / 16384 bytes | 0.005790 s |
| InlineParser math, 512 combining-mark chunks | 0.000528 s |
| InlineParser math, 1024 combining-mark chunks | 0.000901 s |
| Quoted blank line, 1024 one-space chunks | 0.032138 s |
| Quoted blank line, 2048 one-space chunks | 0.042070 s |
| Alternating space/tab padding, 1024 chunks | 0.034189 s |
| Alternating space/tab padding, 2048 chunks | 0.044349 s |
| Deferred quoted table candidate, 1024 one-character chunks | 0.023483 s |
| Deferred quoted table candidate, 2048 one-character chunks | 0.032727 s |

Sample1 remains within 3-6% of the fresh-review baseline, including the extra
local opener/container checks. Long math takes 1.98x when input doubles;
the isolated Unicode scanner takes 1.71x, and quoted deferred cases take
1.30-1.39x. No material throughput regression was observed.

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

## Stack Checkpoint With Scalar-Safe Math Openers (2026-09-30)

After checkpoint `36ed036` propagates PR9 `f489f4e` and PR10 `2512a0a`,
the additional PR11 opener fix uses byte boundaries for dollar and command
markers. Seven scalar-split regressions reproduced 56 failed expectations
before the fix and pass afterward. Full macOS/iOS suites and both example
builds completed before this serial, skip-build benchmark run.

| Case | Mean Per Iteration |
| --- | ---: |
| sample1, 128-byte chunks (50 iterations) | 0.016421 s |
| sample1, 512-byte chunks (50 iterations) | 0.015986 s |
| sample1, 1024-byte chunks (50 iterations) | 0.015823 s |
| sample1, example word stream (50 iterations) | 0.022314 s |
| Long math, 8192 bytes (10 iterations) | 0.002992 s |
| Long math, 16384 bytes (10 iterations) | 0.005865 s |
| InlineParser, 512 combining-mark chunks (20 iterations) | 0.000513 s |
| InlineParser, 1024 combining-mark chunks (20 iterations) | 0.000882 s |
| Quoted padding, 1024 one-character chunks (10 iterations) | 0.031903 s |
| Quoted padding, 2048 one-character chunks (10 iterations) | 0.041804 s |
| Alternating quote padding, 1024 chunks (10 iterations) | 0.034058 s |
| Alternating quote padding, 2048 chunks (10 iterations) | 0.045284 s |
| Deferred quoted table, 1024 chunks (10 iterations) | 0.023360 s |
| Deferred quoted table, 2048 chunks (10 iterations) | 0.032340 s |

No material regression against checkpoint `f83433f`: sample1 is slightly
faster, and long-math means differ by under 3%. Doubling input takes 1.96x
for long math, 1.72x for the isolated Unicode scanner, and 1.31-1.38x for
capped/deferred quote cases. Opening-marker resolution remains local and
does not reparse already-emitted text.

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

## Combined Verbatim/List-Child Checkpoint 4a3aad1 (2026-09-30)

Serial tokenizer benchmarks after propagating PR9 `1fe467d` into the stack;
all local tests and example builds completed first. Sample1 means at
128/512/1024-byte chunks are `0.016742 / 0.016083 / 0.016247 s`, and the
example word stream is `0.022725 s` (50 iterations each). No material
regression against the scalar-safe-opener checkpoint was observed.

Ten-iteration long-math means are `0.003106 / 0.005899 s` for 8192/16384
bytes (1.90x). The 20-iteration isolated Unicode scanner means are
`0.000509 / 0.000876 s` for 512/1024 combining-mark chunks (1.72x).
Ten-iteration quote means at 1024/2048 chunks are `0.032418 / 0.041926 s`
for spaces, `0.034400 / 0.044157 s` for alternating padding, and
`0.023275 / 0.033359 s` for deferred table candidates (1.28-1.43x).

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

## Combined Boundary/Gutter Checkpoint 570090c (2026-09-30)

All full platform tests and example builds completed before the serial run.
Sample1 means for 128/512/1024-byte chunks are `0.016644 / 0.016074 /
0.016161 s`; the example word stream is `0.022679 s` (50 iterations each).
No material regression against checkpoint `4a3aad1` was observed.

Long-math means for 8192/16384 bytes are `0.003042 / 0.005872 s`
(10 iterations, 1.93x when input doubles). Isolated combining-mark scanner
means for 512/1024 chunks are `0.000527 / 0.000889 s` (20 iterations, 1.69x).
Quote means for 1024/2048 chunks are `0.032405 / 0.042790 s` for spaces,
`0.034299 / 0.044522 s` for alternating padding, and
`0.023845 / 0.033477 s` for deferred tables (10 iterations, 1.30-1.40x).

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

## Combined Interrupt/Cancellation Checkpoint a788d43 (2026-09-30)

The combined stack passes 37 XCTest + 243 Swift Testing tests on macOS and
281 test definitions on iOS Simulator. Both example builds are warning-free.
All platform tests/builds completed before this serial, skip-build benchmark.

Sample1 means at 128/512/1024-byte chunks are `0.016916 / 0.016439 /
0.016263 s`; the example word stream is `0.023031 s` (50 iterations each).
These are within 3% of checkpoint `570090c`, with no material regression.
Long-math means for 8192/16384 bytes are `0.003067 / 0.006152 s`
(10 iterations, 2.01x when input doubles). Isolated combining-mark scanner
means for 512/1024 chunks are `0.000515 / 0.000886 s` (20 iterations, 1.72x).
Quoted 1024/2048 means are `0.032463 / 0.042441 s` for spaces,
`0.034685 / 0.044553 s` for alternating padding, and
`0.023295 / 0.033132 s` for deferred tables (10 iterations, 1.28-1.42x).

The subsequent renderer-only incremental image-retention checkpoint `f0717bc`
passes 37 XCTest + 245 Swift Testing tests on macOS and 283 test definitions
on iOS Simulator; both example builds remain warning-free. This change removes
retained-document/cache scans from image pruning, with per-block URL ownership
and shared reference counts. It changes no tokenizer or benchmark code, so
the parser measurements above remain applicable without another parser run.

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

## Combined Literal/Publication Checkpoint c8c15de (2026-09-30)

The full stack passes 37 XCTest + 248 Swift Testing tests on macOS and 286
test definitions on iOS Simulator. Both examples build without compiler
warnings. The serial skip-build run followed all tests/builds.

Sample1 means for 128/512/1024-byte chunks are `0.016987 / 0.017361 /
0.017359 s`, and the word stream is `0.023771 s` (50 iterations). These are
within 7% of checkpoint `a788d43`; the lower-branch unchanged-code repeat
above remains within its prior range.
Long math at 8192/16384 bytes measures `0.003169 / 0.005901 s`
(10 iterations, 1.86x on doubling). The isolated combining-mark scanner
at 512/1024 chunks measures `0.000511 / 0.000884 s` (20 iterations, 1.73x).
Quoted 1024/2048 means are `0.032349 / 0.042467 s` for spaces,
`0.034794 / 0.044658 s` for alternating padding, and
`0.024421 / 0.034040 s` for deferred tables (10 iterations, 1.28-1.39x).

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

## Combined Successor-Prefix Checkpoint 3c00a0a (2026-09-30)

The final stack passes 37 XCTest + 248 Swift Testing tests on macOS and 286
test definitions on iOS Simulator, including all 102 quoted split/determinism
fixtures. Both examples build without compiler warnings. All tests/builds
finished before this serial skip-build benchmark.

Sample1 means at 128/512/1024-byte chunks are `0.016693 / 0.016183 /
0.016331 s`, and word streaming is `0.023103 s` (50 iterations). These remain
within the preceding checkpoint's range, with no material regression.
Long math at 8192/16384 bytes measures `0.003109 / 0.005926 s`
(10 iterations, 1.91x when input doubles). The isolated combining-mark scanner
at 512/1024 chunks measures `0.000526 / 0.000921 s` (20 iterations, 1.75x).
Quoted 1024/2048 means are `0.032783 / 0.042847 s` for spaces,
`0.035090 / 0.044639 s` for alternating padding, and
`0.024278 / 0.033827 s` for deferred tables (10 iterations, 1.27-1.39x).

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

## Combined Successor/Width Checkpoint 74d158a (2026-09-30)

The combined stack passes 37 XCTest + 252 Swift Testing definitions on macOS
and 290 definitions on iOS Simulator. Both examples build without compiler
warnings. Two serial skip-build measurements followed all tests/builds.

Initial sample1 means at 128/512/1024 bytes were `0.019490 / 0.019051 /
0.017712 s`, with word streaming `0.026668 s`. An unchanged-code repeat gives
`0.016615 / 0.016100 / 0.016711 s`, word streaming `0.025814 s` (50 iterations).
The sample1 means return within 3% of `3c00a0a`; word streaming is 12% above
that checkpoint, but below both elevated lower-branch measurements. These
measurements do not reproduce a sustained lower-branch 50%+ slowdown; retain
the earlier noisy results rather than attributing their cause without evidence.

Repeat long math at 8192/16384 bytes measures `0.002985 / 0.006027 s`
(10 iterations, 2.02x). The isolated combining-mark scanner at 512/1024 chunks
measures `0.000531 / 0.000897 s` (20 iterations, 1.69x). Quoted 1024/2048
means are `0.032444 / 0.042284 s` for spaces, `0.035804 / 0.045249 s` for
alternating padding, and `0.024601 / 0.034467 s` for tables
(10 iterations, 1.26-1.40x). Their means remain within 3% of `3c00a0a`.

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

## Final Boundary Stack Checkpoint 61f1a6e (2026-09-30)

Full suites pass 37 XCTest + 254 Swift Testing definitions on macOS and 292
definitions on iOS Simulator. Both example builds are compiler-warning-free.
The serial skip-build benchmark ran after every test/build command completed.

Sample1 means at 128/512/1024 bytes are `0.017044 / 0.016463 / 0.016550 s`,
word streaming `0.023203 s` (50 iterations). These are within 3% of the stable
`3c00a0a` checkpoint, including word streaming; the earlier elevated lower
and combined timings are not persistent in this final run. No material
throughput regression is observed in the final stack.

Long math at 8192/16384 bytes measures `0.003090 / 0.006122 s`
(10 iterations, 1.98x). The isolated combining-mark scanner at 512/1024 chunks
measures `0.000538 / 0.000899 s` (20 iterations, 1.67x). Quoted 1024/2048
means are `0.032933 / 0.042642 s` for spaces, `0.035081 / 0.044632 s` for
alternating padding, and `0.024399 / 0.034175 s` for tables
(10 iterations, 1.27-1.40x), also within 3% of `3c00a0a`.

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

## GFM And Atomic Width Stack Checkpoint 0bbe2dc (2026-09-30)

Full combined suites pass 37 XCTest + 257 Swift Testing definitions on macOS
and 295 definitions on iOS Simulator (518 parameterized invocations reported
separately), with zero failures, skips, or runtime warnings. Both examples
build without compiler warnings. All 134 quote fixtures and the paused-image
in-flight width supersession/rollback regressions pass on both platforms.

The serial skip-build benchmark followed all completed tests and builds.
Sample1 means at 128/512/1024 bytes are `0.016927 / 0.016351 / 0.016247 s`,
with word streaming `0.023045 s` (50 iterations). Long math at 8192/16384
bytes measures `0.003140 / 0.006154 s` (10 iterations, 1.96x), and the
isolated combining-mark scanner at 512/1024 chunks measures
`0.000535 / 0.000897 s` (20 iterations, 1.68x).

Quoted 1024/2048 means are `0.032858 / 0.043210 s` for spaces,
`0.035848 / 0.045555 s` for alternating padding, and
`0.024921 / 0.034731 s` for deferred tables (10 iterations, 1.27-1.39x).
Sample1, word-stream, and quoted-case means remain within 3% of the stable
`3c00a0a` checkpoint. No material throughput regression is observed; earlier
elevated measurements remain preserved above.

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

## Final Successor Stack Checkpoint 10f47e8 (2026-09-30)

Full combined suites pass 37 XCTest + 258 Swift Testing definitions on macOS
and 296 definitions on iOS Simulator (545 invocations including parameterized
cases), with zero failures, skips, or runtime warnings. Both examples build
without compiler warnings. All 160 quote fixtures and native successor
indentation controls pass on both platforms.

The serial skip-build benchmark followed all completed tests/builds. Sample1
128/512/1024-byte means are `0.016734 / 0.016492 / 0.016406 s`, with word
streaming `0.022874 s` (50 iterations). Long math at 8192/16384 bytes measures
`0.003071 / 0.005947 s` (10 iterations, 1.94x); the isolated combining-mark
scanner at 512/1024 chunks measures `0.000511 / 0.000882 s`
(20 iterations, 1.73x).

Quoted 1024/2048 means are `0.032248 / 0.042067 s` for spaces,
`0.034518 / 0.044223 s` for alternating padding, and
`0.024047 / 0.033589 s` for deferred tables (10 iterations, 1.28-1.40x).
Sample1, word-stream, and quoted-case means remain within 3% of `3c00a0a`.
The earlier required combined comparison is complete; no material throughput
regression is observed, and all earlier measurements remain preserved.

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

## Empty-Marker And Pause/Resume Stack Checkpoint 2867602 (2026-09-30)

The final combined stack passes 37 XCTest + 263 Swift Testing definitions on
macOS and 301 definitions on iOS Simulator (679 invocations including dynamic
parameters), with zero failures, skips, or runtime warnings. Both examples
build without compiler warnings. All 284 quoted fixtures and the six native
paused-replacement version regressions pass. Both serial skip-build benchmark
runs followed all completed tests/builds, with no concurrent build commands.

Initial sample1 128/512/1024-byte means were `0.016634 / 0.016373 / 0.016122 s`,
word streaming `0.022816 s` (50 iterations). Quoted 1024/2048 means were
`0.032703 / 0.043339 s` for spaces, `0.034544 / 0.043985 s` for alternating
padding, and `0.024393 / 0.037816 s` for tables (10 iterations). The longest
table case was 12% above `3c00a0a`; the unchanged-code repeat below checks it.

Repeat sample1 means were `0.016721 / 0.016437 / 0.016261 s`, with word
streaming `0.022983 s`. Long math at 8192/16384 bytes measured
`0.003199 / 0.006147 s` (10 iterations, 1.92x); the isolated combining-mark
scanner at 512/1024 chunks measured `0.000513 / 0.000910 s`
(20 iterations, 1.77x). Quoted means were `0.032364 / 0.042818 s` for spaces,
`0.035180 / 0.045313 s` for alternating padding, and
`0.024727 / 0.035103 s` for tables (10 iterations, 1.29-1.42x).

Repeat sample1, word-stream, and quoted-case means are within 3% of `3c00a0a`
except the longest table case, which is 4% higher (5% above `10f47e8`). The
larger lower-branch elevations are not persistent in the combined repeat;
all measurements remain recorded rather than attributing variation without
evidence. The required final combined comparison is complete.

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
`0.025424 / 0.039525 s` for tables (10 iterations, 1.41-1.55x), about 2%
of the preceding lower-branch run. The larger lower/combined differences
remain recorded; a final combined-stack comparison is required. No build
commands ran concurrently.

## Padding And Inline Suffix Stack Checkpoint 5270cd4 (2026-10-01)

All four new review findings were independently reproduced and fixed; none
was dismissed. The combined stack passes 37 XCTest + 267 Swift Testing
definitions on macOS and 305 definitions / 737 parameterized invocations on
iOS, with no failures, skips, or runtime warnings. Both examples build without
compiler warnings. The 329 quoted fixtures and ten inline-suffix variants
cover split/character/scalar streams and deterministic repeats. Initial CI
failed only to type-check a nested fixture expression; explicit typed loops
preserve the same cases and remove that compiler compatibility issue.

The serial skip-build benchmark followed all completed local test/build
commands. Sample1 128/512/1024-byte means were
`0.017125 / 0.016468 / 0.016274 s`, with word streaming `0.023245 s`
(50 iterations). Long math at 8192/16384 bytes measured
`0.003147 / 0.006147 s` (10 iterations, 1.95x); the combining-mark scanner
at 512/1024 chunks measured `0.000513 / 0.000881 s`
(20 iterations, 1.72x). Quoted 1024/2048 means were
`0.032251 / 0.041865 s` for spaces, `0.034247 / 0.043992 s` for alternating
padding, and `0.024674 / 0.034166 s` for tables
(10 iterations, 1.28-1.39x).

All sample1, word-stream, and quoted-case means are within 3% of `3c00a0a`.
The required combined comparison is complete; no material throughput
regression is observed in this final measurement. Earlier elevations and
failed compilation evidence remain recorded rather than being discarded.
