# HTML viewport benchmark: 80 blocks / 80 chat messages

Identical generated input: 156,689 UTF-8 bytes; SHA-256 `0fa35d94ee54c60042f83d1cf1b388d340f1606be051f3da60873c6fbc7a4608`. Long-message mode delivers 307 chunks of at most 512 bytes. Lazy-chat mode uses one public PicoMarkdownView per message: 79 completed messages and one streamed in 512-byte chunks every 50 ms.

Baseline: `949f2f00fdca72d3f405e548f9e1a12363a8a1b8+common-mac-remount-fix`. After: `34f37c7431e161c0d64b1c955c6714e3f0f198e1+working-tree`. The necessary macOS native-remount fix is byte-identical in both arms (SHA-256 `46e23ae8bc68b28e2e185b607848a85bdac2c45011d372f51dcff23bbe5d277b`). All benchmark Swift files are also identical across all eight artifacts. Exact HTML production hashes are recorded per artifact.

## Baseline did not complete the full HTML workload

The faithful baseline failed the real-readiness guard before completing all 80 previews. Its HTML rows are intentionally unscored; there is no valid full-corpus baseline latency/memory result to compare. The missing preview had already fallen back inside its hosted attachment: a source-sized host remained with no native HTML container. This is evidence of a rendering failure, not a measured memory optimization. The exact failure path was not instrumented, so an initial layout/measurement race remains a hypothesis.

- long: [failure record](before-html-80.failure.json), [test log](before-html-80.log). `HTML_LONG_FIXTURE unreachable=8994 state=attachment=(800.0, 589.0) host=(0.0, 8.25, 800.0, 589.0) containers=[]`
- chat: [failure record](before-chat-html-80.failure.json), [test log](before-chat-html-80.log). `HTML_CHAT_FIXTURE unreachable=3 delivery=Snapshot(attempts: 0, chunks: 0, closingYield: nil) views=["Report 3\nNative paragraph before ite attachments=1 rawHTML=false frame=(0.0, 0.0, 744.0, 806.0) visible=(-28.0, -12.0, 800.0, 640.0) containers=[]"]`

Release; 3 pass(es) configured for each fresh scenario process; incomplete baseline failures stop before the full set finishes. Pass 0 is first-in-process, not machine-cold. Tables use the median of the 2 warm passes after pass 0, except peaks/maxima which use their worst sample. Percentiles use nearest rank; raw JSON includes every completed pass/distribution.

## Host memory and page lifetime

| Workload | Scenario | Revision | Host footprint peak MiB | Host RSS peak MiB | Live pages peak | Settled live pages | Settled visible pages | Observed loads by end |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| long | native | before | 259.1 | 200.8 | 0 | 0 | 0 | 0 |
| long | native | after | 258.9 | 200.2 | 0 | 0 | 0 | 0 |
| long | html | before | did not complete | — | — | — | — | — |
| long | html | after | 259.3 | 385.9 | 2 | 1 | 1 | 185 |
| chat | native | before | 532.8 | 2867.7 | 0 | 0 | 0 | 0 |
| chat | native | after | 532.8 | 2823.4 | 0 | 0 | 0 | 0 |
| chat | html | before | did not complete | — | — | — | — | — |
| chat | html | after | 638.2 | 1120.5 | 1 | 1 | 1 | 167 |

Memory uses public task_info TASK_VM_INFO for the benchmark host only. It excludes WebKit WebContent, network and GPU helper processes, so this is not total browser memory or a system-wide peak. Samples and weak instance tracking can miss short-lived transitions; allocator/framework caches persist between passes. Loads count observed container loadCount deltas, not a private WebKit allocation hook. Settled samples follow 500 ms at the first viewport; peak samples include offscreen visits and resize.

| Workload | HTML revision | Live pages 250 ms after detach | Containers 500 ms after release |
| --- | --- | ---: | ---: |
| long | before | did not complete | — |
| long | after | 0 | 80 |
| chat | before | did not complete | — |
| chat | after | 0 | 219 |

Fixed-delay retained containers are observations, not evidence of a leak. A container with no live WebPage can still retain prepared source and measured height.

## Single long message

| Scenario | Revision | Feed p95 ms | UI apply/layout p95 ms | Scroll layout p95 ms | Stream heartbeat max gap ms | Scroll heartbeat max gap ms | Ready observed ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| native | before | 1.648 | 3.240 | 7.035 | 14.4 | 28.2 | — |
| native | after | 1.656 | 3.263 | 6.459 | 14.1 | 26.7 | — |
| html | before | did not complete | — | — | — | — | — |
| html | after | 1.646 | 1.563 | 3.775 | 49.6 | 60.5 | 121.0 |

This mode uses the production pipeline/controller directly in NSWindow/NSScrollView. It cooperatively bursts chunks with 1 ms between them. Feed and synchronous UI apply/layout/display are measured separately; asynchronous page rehydration is outside the scroll-layout operation time and inside heartbeat/readiness observations. Every HTML attachment is visited down and back; readiness requires a real page and matching container/attachment/measured heights, not just an isReady flag.

## Real lazy chat

| Scenario | Revision | First message ready ms | Visit-to-ready p50 ms | Visit-to-ready p95 ms | Stream closing yield-to-ready ms | MainActor heartbeat max gap ms | Post-ready scroll drift max pt |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| native | before | 41.2 | 5.7 | 44.5 | 7.4 | 32.7 | 728.0 |
| native | after | 54.8 | 6.0 | 43.6 | 7.1 | 33.0 | 728.5 |
| html | before | did not complete | — | — | — | — | — |
| html | after | 179.1 | 104.1 | 152.1 | 87.9 | 125.5 | 0.0 |

This is an actual SwiftUI ScrollView/LazyVStack with stable ForEach message IDs and public PicoMarkdownView initializers, in an 800×640 NSWindow. Each message is requested at the top until it is actually visible and ready; all messages are visited in both directions. Public stream closing-yield latency includes delivery, parsing, publication, WebKit and sizing; it is not the direct pipeline feed measurement above. The command-line host explicitly services native layout/display. These are programmatic visits with settling, not frame-rate or human wheel-scroll measurements.

The MainActor heartbeat requests a turn every 10 ms; reported gaps include timer scheduling, deferred SwiftUI/WebKit work, benchmark observation and host noise. Native controls show how much the host varied and are not visually identical in height because they display HTML source. Native chat completeness means its full footer is stored in a visible text view; HTML additionally requires real page and height readiness. Native post-completeness drift therefore exposes later lazy-layout estimation, and cross-scenario readiness timings are not equivalent operations.

| Chat scenario | Revision | Stream factory attempts by pass | Chunks delivered by pass |
| --- | --- | --- | --- |
| native | before | 9, 9, 9 | 12, 12, 12 |
| native | after | 9, 10, 10 | 12, 13, 13 |
| html | before | did not complete | — |
| html | after | 4, 4, 5 | 10, 10, 12 |

These counts include cancelled partial replay. The existing public stream API invokes its factory again when a lazy view disappears and reappears; the fixture returns the complete source on each invocation as required. The newest message therefore need not be one uninterrupted stream. Closing-yield-to-ready is an end-to-end public-view observation, not isolated per-feed latency; direct feed/apply measurements are reported only for the long-message harness.

## Selection, source export and reflow

All completed HTML runs passed without preview fallback or readiness timeout. In a completed single long message, the selected attachment range and its original fenced HTML export survived scrolling and resize. Lazy chat reselects the returned attachment and verifies identical fenced source export; it separately records whether the native selection survived SwiftUI remount.

| HTML revision | Native selection survived lazy remount (all passes) | Source copy on return (all passes) | Initial / 320 pt / restored 800 pt height |
| --- | --- | --- | --- |
| before | did not complete | — | — |
| after | False | True | 319 / 499 / 319 pt |

The first message is kept offscreen while the window narrows, then revisited. Its HTML table must grow in height at 320 pt and return to the original height at 800 pt. This validates width remeasurement rather than a cached stale height. The baseline includes the common native reattachment fix because unmodified 949f2f0 could remount an empty native text view, making a performance comparison invalid.
