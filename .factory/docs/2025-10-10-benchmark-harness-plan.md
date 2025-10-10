## Goal
Create a repeatable Swift benchmark suite using `Tests/Samples/sample1.md` to measure incremental parse/ render latency, providing a baseline before further optimizations.

## Components
1. **Benchmark Target**
   - Add a new executable (e.g., `Benchmarks`) under `Package.swift` or use a dedicated test case leveraging XCTest’s measure blocks.
   - Read `sample1.md` and simulate chunked streaming (e.g., split into 64/128-byte segments).

2. **Metrics Collected**
   - End-to-end time for `StreamingMarkdownRenderer.appendMarkdown` across N iterations.
   - Optional granular timings (buffer append vs. renderer output) using `ContinuousClock` or `DispatchTime`.

3. **Reporting**
   - Print aggregate stats (total duration, per-iteration average) and optionally emit markdown/JSON summary for future comparison.

4. **Automation**
   - Hook into `swift test --filter BenchmarkTests` for easy invocation; ensure benchmarks bypass UI dependencies.

## Next Steps
- Scaffold benchmark test target, load sample data, implement measurement loop, and validate results locally.
