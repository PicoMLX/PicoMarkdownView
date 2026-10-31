#!/usr/bin/env python3
"""Validate and summarize paired HTML benchmark artifacts; no pass/fail timings."""
import json
from pathlib import Path
import statistics
import sys

root = Path(sys.argv[1])
cards = int(sys.argv[2]) if len(sys.argv) > 2 else 80
results = {(revision, scenario): json.loads((root / f"{revision}-{scenario}-{cards}.json").read_text())
           for revision in ("before", "after") for scenario in ("native", "html")}
reference = results["before", "native"]
for (revision, scenario), result in results.items():
    for key in ("cards", "sourceBytes", "sourceSHA256", "chunkBytes", "chunkCount", "build", "os", "processors", "physicalMemory"):
        assert result[key] == reference[key], f"{revision}/{scenario}: mismatched {key}"
    harness = "Tests/PicoMarkdownViewHTMLBenchmarks/HTMLTranscriptBenchmark.swift"
    assert result["sourceHashes"][harness] == reference["sourceHashes"][harness], "Harness differs"
    assert result["build"] == "release"
    for run in result["passes"]:
        assert run["closedHTMLBlocks"] == cards, "Not every HTML fence closed"
        if scenario == "html":
            assert run["observedPages"] > 0 and run.get("firstPreviewReadyMS") is not None, "No real HTML preview observed"
            assert run["readinessTimeouts"] == 0, "Initial viewport readiness timed out"
            assert max(m["failedContainers"] for m in run["memory"]) == 0, "Preview fell back to source"
        else:
            assert run["observedPages"] == 0, "Native control unexpectedly used WebKit"


def warm(result):
    return result["passes"][1:] or result["passes"]


def median(result, metric, field="p95"):
    return statistics.median(p[metric][field] for p in warm(result))


def final_sample(run, name):
    return next(m for m in run["memory"] if m["phase"] == name)


print(f"# HTML preparation benchmark: {cards} cards")
print()
print(f"Identical workload: {reference['sourceBytes']:,} UTF-8 bytes, {reference['chunkCount']} chunks of up to {reference['chunkBytes']} bytes. Source SHA-256: `{reference['sourceSHA256']}`.")
print()
print("Release builds; three passes per fresh scenario process. Pass 0 is first-in-process, not a machine-cold run; passes 1 and 2 are warm. The table uses the median warm-pass p95, with the worst warm heartbeat maximum. Percentiles use the nearest-rank convention. All raw per-pass p50/p95/max distributions and memory samples are in the JSON artifacts.")
print()
print("| Scenario | Revision | Feed p95 ms | UI apply/layout p95 ms | Closing chunk p95 ms | Closing heartbeat max gap ms | Stream heartbeat max gap ms |")
print("| --- | --- | ---: | ---: | ---: | ---: | ---: |")
for scenario in ("native", "html"):
    for revision in ("before", "after"):
        r = results[revision, scenario]
        close_gap = max(p["closingHeartbeat"]["max"] for p in warm(r))
        stream_gap = max(p["streamHeartbeat"]["max"] for p in warm(r))
        print(f"| {scenario} | {revision} | {median(r, 'feed'):.3f} | {median(r, 'uiApply'):.3f} | {median(r, 'closingChunk'):.3f} | {close_gap:.3f} | {stream_gap:.3f} |")
print()
print("The heartbeat requests a MainActor turn every 10 ms. Values are actual inter-tick gaps, including timer scheduling, benchmark observation, deferred SwiftUI/WebKit work and unrelated host load; they are not pure sanitizer CPU times. Closing heartbeat gaps overlap a closing feed/apply interval. UI apply/layout measures synchronous controller update, intrinsic sizing, layout and display; background/deferred work is reflected separately by the heartbeat and readiness metrics.")
print()
print("| Scenario | Revision | Max sampled host footprint MiB | Max sampled host RSS MiB | Max observed live pages | Pages after window detach | Containers 500 ms after document release |")
print("| --- | --- | ---: | ---: | ---: | ---: | ---: |")
for scenario in ("native", "html"):
    for revision in ("before", "after"):
        r = results[revision, scenario]
        runs = warm(r)
        samples = [m for p in runs for m in p["memory"]]
        footprint = max(m["hostFootprintBytes"] for m in samples if m.get("hostFootprintBytes") is not None) / 2**20
        rss = max(m["hostResidentBytes"] for m in samples if m.get("hostResidentBytes") is not None) / 2**20
        pages = max(m["observedLivePages"] for m in samples)
        detached = max(final_sample(p, "detachedWindow")["observedLivePages"] for p in runs)
        retained = max(final_sample(p, "releasedDocument")["observedRetainedContainers"] for p in runs)
        print(f"| {scenario} | {revision} | {footprint:.1f} | {rss:.1f} | {pages} | {detached} | {retained} |")
print()
print("Memory is the benchmark host process only, sampled with public task_info TASK_VM_INFO; it excludes WebKit WebContent, networking and GPU helper processes. It is not total browser memory or a system-wide peak. Framework/allocator caches may persist between warm passes. Weak instance tracking observes reachable attachment subviews, including already-created offscreen hosts; it does not install a global allocation hook. Retained containers at a fixed delay are an observation, not proof of a leak.")
print()
print("| HTML revision | First-in-process ready observed ms | Median warm ready observed ms | Median warm scroll layout p95 ms | Worst warm scroll heartbeat gap ms |")
print("| --- | ---: | ---: | ---: | ---: |")
for revision in ("before", "after"):
    r = results[revision, "html"]
    ready = statistics.median(p["firstPreviewReadyMS"] for p in warm(r))
    print(f"| {revision} | {r['passes'][0]['firstPreviewReadyMS']:.1f} | {ready:.1f} | {median(r, 'scrollLayout'):.3f} | {max(p['scrollHeartbeat']['max'] for p in warm(r)):.3f} |")
print()
print("Readiness is observed from the first closing chunk, sampled every eight chunks and every 10 ms while waiting; it includes WebKit startup and viewport scheduling. Source-only/native mode has the same HTML bytes but a different document height because it displays source code. This is one long message in a real NSWindow/NSScrollView, not a full chat List/LazyVStack benchmark. Window-mounted WebPages can remain live outside the viewport; inspect the counts rather than assuming scroll virtualization.")
