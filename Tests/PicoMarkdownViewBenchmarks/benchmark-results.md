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
