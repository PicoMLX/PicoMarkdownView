# HTML preparation benchmark: 80 cards

Identical workload: 156,689 UTF-8 bytes, 307 chunks of up to 512 bytes. Source SHA-256: `0fa35d94ee54c60042f83d1cf1b388d340f1606be051f3da60873c6fbc7a4608`.

Release builds; three passes per fresh scenario process. Pass 0 is first-in-process, not a machine-cold run; passes 1 and 2 are warm. The table uses the median warm-pass p95, with the worst warm heartbeat maximum. Percentiles use the nearest-rank convention. All raw per-pass p50/p95/max distributions and memory samples are in the JSON artifacts.

| Scenario | Revision | Feed p95 ms | UI apply/layout p95 ms | Closing chunk p95 ms | Closing heartbeat max gap ms | Stream heartbeat max gap ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| native | before | 1.642 | 3.442 | 5.924 | 16.086 | 16.086 |
| native | after | 1.692 | 3.242 | 5.095 | 14.670 | 14.670 |
| html | before | 1.695 | 1.848 | 3.597 | 35.493 | 61.046 |
| html | after | 1.732 | 1.576 | 3.397 | 33.590 | 60.395 |

The heartbeat requests a MainActor turn every 10 ms. Values are actual inter-tick gaps, including timer scheduling, benchmark observation, deferred SwiftUI/WebKit work and unrelated host load; they are not pure sanitizer CPU times. Closing heartbeat gaps overlap a closing feed/apply interval. UI apply/layout measures synchronous controller update, intrinsic sizing, layout and display; background/deferred work is reflected separately by the heartbeat and readiness metrics.

| Scenario | Revision | Max sampled host footprint MiB | Max sampled host RSS MiB | Max observed live pages | Pages after window detach | Containers 500 ms after document release |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| native | before | 270.4 | 200.6 | 0 | 0 | 0 |
| native | after | 260.6 | 200.5 | 0 | 0 | 0 |
| html | before | 278.2 | 216.3 | 80 | 0 | 80 |
| html | after | 287.0 | 227.1 | 80 | 0 | 80 |

Memory is the benchmark host process only, sampled with public task_info TASK_VM_INFO; it excludes WebKit WebContent, networking and GPU helper processes. It is not total browser memory or a system-wide peak. Framework/allocator caches may persist between warm passes. Weak instance tracking observes reachable attachment subviews, including already-created offscreen hosts; it does not install a global allocation hook. Retained containers at a fixed delay are an observation, not proof of a leak.

| HTML revision | First-in-process ready observed ms | Median warm ready observed ms | Median warm scroll layout p95 ms | Worst warm scroll heartbeat gap ms |
| --- | ---: | ---: | ---: | ---: |
| before | 365.4 | 164.8 | 10.844 | 115.385 |
| after | 292.4 | 111.1 | 13.347 | 122.324 |

Readiness is observed from the first closing chunk, sampled every eight chunks and every 10 ms while waiting; it includes WebKit startup and viewport scheduling. Source-only/native mode has the same HTML bytes but a different document height because it displays source code. This is one long message in a real NSWindow/NSScrollView, not a full chat List/LazyVStack benchmark. Window-mounted WebPages can remain live outside the viewport; inspect the counts rather than assuming scroll virtualization.
