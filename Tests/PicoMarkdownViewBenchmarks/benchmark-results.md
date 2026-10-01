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

## Final Stack With Scalar-Safe Math Openers (2026-09-30)

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
