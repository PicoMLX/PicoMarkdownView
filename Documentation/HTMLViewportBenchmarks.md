# HTML viewport lifetime and real chat benchmark

This opt-in experiment measures WebPage eviction separately from the earlier [HTML preparation benchmark](HTMLPerformanceBenchmarks.md). It exercises both an 80-attachment message and the intended chat layout: one public `PicoMarkdownView` per message inside SwiftUI `ScrollView`/`LazyVStack`/`ForEach`. Ordinary unit tests keep both workloads disabled; there are no timing thresholds.

## Reproduce

On macOS 27 with Xcode 27 selected, run from the package worktree:

```bash
BASELINE_REF=949f2f0 PICO_HTML_BENCH_COMMON_REMOUNT_FIX=1 PICO_HTML_BENCH_KIND=both \
  PICO_HTML_BENCH_RECORD_BASELINE_FAILURES=1 \
  Scripts/benchmark-html-transcript.sh before /private/tmp/html-viewport-results
PICO_HTML_BENCH_KIND=both \
  Scripts/benchmark-html-transcript.sh after /private/tmp/html-viewport-results
python3 Scripts/summarize-html-viewport-benchmark.py /private/tmp/html-viewport-results 80
```

The baseline is an isolated archive; unrelated worktree changes are never copied, stashed or checked out. The common-remount option copies only the current macOS TextKit controller into the archive. The report requires this file's hash to match in both arms: original `949f2f0` can reconnect a retained controller to empty text storage when a lazy row remounts, which invalidates the chat workload. This native fix is a separate commit from HTML viewport eviction; iOS behavior is unchanged.

The default remains `PICO_HTML_BENCH_KIND=long` for the historical preparation experiment. Use `chat` for only the public lazy layout or `both` for all four scenarios. `PICO_HTML_BENCH_CARDS` defaults to 80 and `PICO_HTML_BENCH_ITERATIONS` to three. For a functional smoke run, choose six messages and one iteration. Each scenario starts a fresh process; pass 0 is first-in-process, and passes 1 and 2 are warm in that process, not independent machine-cold launches.

To separate compilation from scoring, set `PICO_HTML_BENCH_BUILD_ONLY=1` first, then `PICO_HTML_BENCH_SKIP_BUILD=1`. Reuse an archived source directory with `PICO_HTML_BENCH_SOURCE`, its exact `PICO_HTML_BENCH_REVISION_LABEL`, and the same `PICO_HTML_BENCH_SCRATCH`. Do not reuse a build after changing its production source or harness. Avoid concurrent Xcode builds, tests or app interactions during scored runs. The runner removes the exact scenario JSON before each intended overwrite and requires a fresh nonempty result plus the completed Swift Testing summary.

## Workloads and validity

Both modes receive the same generated 156,689-byte Markdown input for 80 reports, including native headings, paragraphs and lists around complete `html-preview` documents with CSS and 12-row tables. Native controls display those same HTML bytes as native code. Their document heights differ from the HTML presentation, so their timing is a host-noise control rather than a pixel-identical alternative. Native chat completeness means its full footer exists in a visible text view; HTML additionally requires real page and matching-height readiness. Post-completeness native drift captures later lazy-layout estimation; these cross-scenario readiness times are not equivalent operations.

The long-message mode uses the production pipeline, TextKit controller and actual attachments in a real `NSWindow`/`NSScrollView`. It bursts 512-byte chunks with one millisecond between chunks, measures pipeline feed and synchronous UI apply/layout separately, and visits every attachment down and back. It verifies the native selected attachment range and original fenced source survive scrolling and resize in that same native text view.

The lazy-chat mode builds actual public `PicoMarkdownView` instances in SwiftUI's lazy layout, with stable message identities. Historical messages use completed source; the newest message streams 512-byte chunks every 50 ms. Programmatic visits wait for the requested message to become visible, retain its native footer, and present a real ready WebPage whose bounds and attachment height match the HTML measurement. This guard prevents a one-point native container with a stale `isReady` flag from being counted as a successful preview. All messages are visited in both directions. The command-line host services native layout/display explicitly; it does not measure human wheel scrolling or compositor frame rate. The existing public stream contract restarts its factory when a lazy view reappears. The fixture returns the complete message on each invocation, and the report includes factory-attempt and delivered-chunk counts, including cancelled partial replay. Public readiness latency must not be read as one isolated feed or a single uninterrupted stream.

After visiting the transcript, message 0 remains offscreen while the window narrows from 800 to 320 points. Revisit must increase the table height, then restore it when the width returns to 800. The transcript reselects the attachment and compares its fenced source export after the return. Native selection persistence across SwiftUI remount is recorded separately; source-copy success does not imply an AppKit selection survived a newly created text view.

The reporter rejects mismatched input/machine/harness/common-controller hashes and invalid candidate results: incomplete visits/fences, preview fallback, missing real readiness, stale-width reflow or changed source export. The faithful baseline can explicitly record an unreachable-preview failure with its exit status, diagnostic log and source hashes when `PICO_HTML_BENCH_RECORD_BASELINE_FAILURES=1`. Such a baseline is unscored, and the report presents that validity limit instead of a latency or memory comparison. Unrelated runner failures still stop the script. Timing values have no magnitude assertions.

## Measurements and limits

JSON retains p50/p95/max distributions per pass, source hashes, load counters, memory samples and functional observations. The ten-millisecond MainActor heartbeat measures actual scheduling gaps including deferred SwiftUI/WebKit work, observation overhead and unrelated host load. It is not a sanitizer CPU timer. Public chat closing-yield-to-ready includes delivery, parsing, publication and page sizing; it is distinct from direct pipeline feed latency.

Host physical footprint and RSS use public Mach `task_info(TASK_VM_INFO)`. They exclude WebKit's WebContent, networking and GPU helper processes and therefore do not establish total browser-memory savings. Weak references observe known containers/pages; sampled peaks can miss short transitions and are not global allocation counts. Page loads sum observed public-internal container load counters. Keeping cached prepared HTML and height after releasing a page is expected. Fixed-delay retained container counts alone do not establish a leak.

The [recorded viewport comparison](Benchmarks/2026-10-31-html-viewport/comparison.md) contains the observed measurements, paired native controls, baseline validity limits and the exact production hashes used. The stricter real-readiness guards also expose failures that the historical first-preview-only harness could not rule out. Historical [preparation artifacts](Benchmarks/2026-10-31-html-preparation/comparison.md) remain unchanged.

## Recorded observations

The candidate completed all three passes for both 80-preview workloads. The long document sampled at most two live WebPages and settled at one, despite retaining 80 mounted containers. Real lazy chat sampled one live page and settled at one. Window detachment released the observed pages. The same native selection and fenced source export survived the single-document visits; after lazy remount, source export recovered correctly but the old native selection did not persist.

The faithful baseline could not complete either full HTML workload under the stronger per-preview readiness guard, so the report does not claim a paired HTML speedup or memory reduction. Paired native controls stayed close. Candidate warm median long-message UI apply/layout p95 was 1.563 ms; real chat visit-to-ready p95 was 152.1 ms, including page rehydration. These are different operations and source presentations, not comparative frame-rate results.

Maximum warm sampled host footprint was 259.3 MiB for the long HTML message and 638.2 MiB for real HTML chat, excluding WebKit helpers. Retained view/container caches still contribute to host memory; page eviction alone does not establish a complete memory budget for an app. The exact distributions, public stream replay counts and validity limits are in the recorded report.
