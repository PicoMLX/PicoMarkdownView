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

Unresolved quote padding is kept as counted whitespace runs after a bounded
prefix. New padding is visited once; blank lines discard it without building
or trimming a growing line string. When text follows, the pending literal
padding is materialized once, preserving spaces and tabs. Doubling the blank
line takes 1.92x rather than 3.67x. Sample1 shows no throughput regression.
