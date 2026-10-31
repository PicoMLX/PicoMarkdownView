# HTML transcript latency and memory benchmark

The opt-in `PicoMarkdownViewHTMLBenchmarks` target exercises the production streaming pipeline, TextKit controller, hosted attachments and HTML adapter in a real macOS window. It is excluded from ordinary CI test filters and disabled unless `PICO_HTML_BENCHMARK=1`. There are no pass/fail timing thresholds.

## Reproduce

Run from the package worktree on macOS 27 with Xcode 27 selected:

```bash
BASELINE_REF=184a8a6 Scripts/benchmark-html-transcript.sh before /private/tmp/html-benchmark-results
Scripts/benchmark-html-transcript.sh after /private/tmp/html-benchmark-results
python3 Scripts/summarize-html-benchmark.py /private/tmp/html-benchmark-results 80
```

The baseline command archives the requested revision into a new temporary source directory, adds the identical benchmark target/harness, and builds it separately. It never checks out, stashes or copies unrelated local modifications. Source hashes in each artifact identify the exact adapter, policy, preparation implementation and harness.

Both commands default to 80 HTML blocks, three passes per scenario, Release optimization and 512-byte chunks. Override `PICO_HTML_BENCH_CARDS`, `PICO_HTML_BENCH_ITERATIONS`, `PICO_HTML_BENCH_SCRATCH` or `DEVELOPER_DIR` explicitly when needed. A 20-block smoke run is useful before a large experiment. Each scenario runs in a fresh process; only later passes inside that process are described as warm.

## Workload and measurements

Native-source and HTML-enabled modes receive identical generated Markdown, byte counts and chunk boundaries. Each report contains native headings, paragraphs and lists around an explicit complete HTML document with scoped CSS and a 12-row table. The full-document wrapper avoids differences in HTML4 fragment parsing and keeps the baseline and updated renderer on the same supported input.

The harness feeds chunks as a cooperative burst, waits one millisecond between chunks to allow callbacks, and applies every emitted update. This stresses streaming throughput; it does not simulate a particular LLM token rate. It lays out the complete message, scrolls an 800 × 640 viewport to every HTML attachment down and back (13 sampled positions each direction for the native control), then resizes to 480 and 800 points. Settling intervals are excluded from synchronous operation timings.

JSON artifacts contain per-pass p50/p95/max for pipeline feed, synchronous UI apply/layout/display, closing chunks, viewport scrolling, resizing, and a ten-millisecond MainActor heartbeat. Heartbeat gaps include deferred HTML preparation, SwiftUI/WebKit callbacks and scheduling noise. First-preview readiness is observed after the first closing chunk, with polling granularity recorded in the generated report.

Host physical footprint and resident size come from public Mach `task_info(TASK_VM_INFO)` samples. They exclude WebKit helper processes and therefore cannot establish total HTML browser memory. Weak references track observed containers and WebPages while mounted, after scrolling, after window detachment, and 500 milliseconds after document release. Counts can reveal retained offscreen pages, but a fixed-delay retained object is not by itself proof of a leak.

The summary script verifies matching inputs, harness hashes, build configuration and machine metadata. It rejects HTML results without a real ready WebPage, incomplete fences, source fallback, or unexpected WebKit usage in the native control. Timing values remain measurements, never CI assertions. Compare several passes and retain the native control to judge host noise.

## Recorded comparison

The [2026-10-31 report](Benchmarks/2026-10-31-html-preparation/comparison.md) includes before/after JSON artifacts, scenario logs, environment records and SHA-256 manifests. It compares revision `184a8a6` with the prepared-once/background-sanitization implementation identified by its exact source hashes. The machine ran macOS 27.0.1, Xcode 27.2 and Swift 6.4.2 with 18 logical processors and 128 GiB RAM.

For this workload, median warm HTML UI apply/layout p95 fell from **1.848 to 1.576 ms**, and observed warm first-preview readiness from **164.8 to 111.1 ms**. Warm closing-chunk p95 changed from 3.597 to 3.397 ms. The native control also varied between runs, so these are observations from three passes, not statistical guarantees or universal speedup claims.

The broader measurements show tradeoffs: worst warm stream heartbeat gaps stayed around 60 ms; scroll layout p95 rose from 10.844 to 13.347 ms; maximum sampled host footprint rose from 278.2 to 287.0 MiB. Scroll visits include initial presentation/remeasurement and revisit work, not frame-rate sampling. Both implementations retained up to **80 live WebPages while the document remained mounted**, including offscreen previews. Window detachment released the observed pages; 80 containers were still observable 500 ms after document release in the command-line host. This change does not implement viewport-based WebPage eviction or establish total browser memory savings.

All 80 attachment ranges were visited in both directions. The first updated pass observed 78 containers/79 page identities while layout settled; both warm updated passes and all baseline passes observed 80 containers and pages. Warm memory comparisons therefore reach the same observed page population. The original harness observed no preview failures or initial-readiness timeouts. It checked the initial ready preview and weakly observed failures while visiting attachment ranges; it did not require every visited preview to retain a real WebPage with matching native/attachment geometry. These observations do not establish full per-card visual validity.

The later [viewport and real lazy-chat benchmark](HTMLViewportBenchmarks.md) measures offscreen WebPage eviction and rehydration using new measurements with native controls and explicit baseline validity limits. The results above describe the earlier preparation-only implementation.
