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
