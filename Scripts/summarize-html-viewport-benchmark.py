#!/usr/bin/env python3
"""Validate paired viewport/lazy-chat artifacts; timings are never assertions."""
import json
from pathlib import Path
import statistics
import sys

root = Path(sys.argv[1])
count = int(sys.argv[2]) if len(sys.argv) > 2 else 80
results = {}
for workload, suffix in (("long", ""), ("chat", "-chat")):
    for revision in ("before", "after"):
        for scenario in ("native", "html"):
            path = root / f"{revision}{suffix}-{scenario}-{count}.json"
            if not path.exists() and revision == "before" and scenario == "html":
                path = path.with_suffix(".failure.json")
            results[workload, revision, scenario] = json.loads(path.read_text())
reference = results["long", "before", "native"]
common = "Sources/PicoMarkdownView/Views/TextKitStreamingController.swift"
harnesses = [k for k in reference["sourceHashes"] if k.startswith("Tests/")]
for (workload, revision, scenario), result in results.items():
    label = f"{workload}/{revision}/{scenario}"
    if result.get("completed") is False:
        assert revision == "before" and scenario == "html", label
        assert result["reason"] == "unreachable-preview" and result["exitStatus"] != 0 and result["diagnostics"], label
        assert result["cards"] == count, label
        for file in harnesses + [common]:
            assert result["sourceHashes"][file] == reference["sourceHashes"][file], f"{label}: different {file}"
        continue
    for key in ("sourceBytes", "sourceSHA256", "build", "os", "processors", "physicalMemory"):
        assert result[key] == reference[key], f"{label}: mismatched {key}"
    assert result["build"] == "release", label
    assert result.get("cards", result.get("messages")) == count, label
    assert len(result["passes"]) == len(reference["passes"]), label
    for file in harnesses + [common]:
        assert result["sourceHashes"][file] == reference["sourceHashes"][file], f"{label}: different {file}"
    for run in result["passes"]:
        assert max(m["failedContainers"] for m in run["memory"]) == 0, f"{label}: source fallback"
        if scenario == "native":
            assert run.get("observedPages", 0) == 0, label
            assert max(m["observedLivePages"] for m in run["memory"]) == 0, label
        if workload == "long":
            assert run["closedHTMLBlocks"] == count, f"{label}: incomplete fences"
            if scenario == "html":
                assert run["firstPreviewReadyMS"] is not None, f"{label}: no ready page"
                assert run["readinessTimeouts"] == 0, f"{label}: readiness timeout"
                assert sum(m["phase"] == "scroll" for m in run["memory"]) == count * 2, f"{label}: not all attachment visits"
                assert run["selectionPreserved"] and run["selectedSourceCopyPreserved"], f"{label}: selection/source copying"
        else:
            assert run["visitedMessages"] == count and run["visitTimeouts"] == 0, f"{label}: incomplete chat visits"
            assert run["firstMessageReadyMS"] is not None, label
            assert run["streamedClosureToReadyMS"] is not None, label
            if scenario == "html":
                assert run["sourceCopyOnReturn"], f"{label}: source copying"
                assert run["narrowPreviewHeight"] > run["initialPreviewHeight"], f"{label}: no narrow-width reflow"
                assert abs(run["restoredPreviewHeight"] - run["initialPreviewHeight"]) <= 2, f"{label}: height not restored"
assert "+common-mac-remount-fix" in reference["revision"], "Baseline must share the native remount fix"


def complete(result):
    return result.get("completed") is not False


def warm(result):
    return result["passes"][1:] or result["passes"]


def med(result, name, field=None):
    return statistics.median(p[name][field] if field else p[name] for p in warm(result))


def samples(result):
    return [m for p in warm(result) for m in p["memory"]]


def phase(run, name):
    return next(m for m in run["memory"] if m["phase"] == name)


print(f"# HTML viewport benchmark: {count} blocks / {count} chat messages\n")
print(f"Identical generated input: {reference['sourceBytes']:,} UTF-8 bytes; SHA-256 `{reference['sourceSHA256']}`. Long-message mode delivers {reference['chunkCount']} chunks of at most {reference['chunkBytes']} bytes. Lazy-chat mode uses one public PicoMarkdownView per message: {count-1} completed messages and one streamed in 512-byte chunks every 50 ms.\n")
print(f"Baseline: `{reference['revision']}`. After: `{results['long', 'after', 'html']['revision']}`. The necessary macOS native-remount fix is byte-identical in both arms (SHA-256 `{reference['sourceHashes'][common]}`). All benchmark Swift files are also identical across all eight artifacts. Exact HTML production hashes are recorded per artifact.\n")
failures = [(workload, result) for (workload, revision, scenario), result in results.items() if not complete(result)]
if failures:
    print("## Baseline did not complete the full HTML workload\n")
    print(f"The faithful baseline failed the real-readiness guard before completing all {count} previews. Its HTML rows are intentionally unscored; there is no valid full-corpus baseline latency/memory result to compare. The missing preview had already fallen back inside its hosted attachment: a source-sized host remained with no native HTML container. This is evidence of a rendering failure, not a measured memory optimization. The exact failure path was not instrumented, so an initial layout/measurement race remains a hypothesis.\n")
    for workload, result in failures:
        suffix = "" if workload == "long" else "-chat"
        print(f"- {workload}: [failure record](before{suffix}-html-{count}.failure.json), [test log](before{suffix}-html-{count}.log). `" + result["diagnostics"][0].replace("`", "'") + "`")
    print()
pass_count = len(reference["passes"])
if pass_count > 1:
    pass_explanation = f"Tables use the median of the {pass_count - 1} warm passes after pass 0, except peaks/maxima which use their worst sample."
else:
    pass_explanation = "Only one first-in-process pass was configured; tables use it and make no warm-run claim."
print(f"Release; {pass_count} pass(es) configured for each fresh scenario process; incomplete baseline failures stop before the full set finishes. Pass 0 is first-in-process, not machine-cold. {pass_explanation} Percentiles use nearest rank; raw JSON includes every completed pass/distribution.\n")
print("## Host memory and page lifetime\n")
print("| Workload | Scenario | Revision | Host footprint peak MiB | Host RSS peak MiB | Live pages peak | Settled live pages | Settled visible pages | Observed loads by end |")
print("| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |")
for workload in ("long", "chat"):
    for scenario in ("native", "html"):
        for revision in ("before", "after"):
            result = results[workload, revision, scenario]
            if not complete(result):
                print(f"| {workload} | {scenario} | {revision} | did not complete | — | — | — | — | — |")
                continue
            data = samples(result)
            settled_name = "settledAfterVisits" if workload == "long" else "settledAtFirstMessage"
            settled = [phase(p, settled_name) for p in warm(result)]
            footprint = max(m["hostFootprintBytes"] for m in data if m.get("hostFootprintBytes") is not None) / 2**20
            rss = max(m["hostResidentBytes"] for m in data if m.get("hostResidentBytes") is not None) / 2**20
            print(f"| {workload} | {scenario} | {revision} | {footprint:.1f} | {rss:.1f} | {max(m['observedLivePages'] for m in data)} | {max(m['observedLivePages'] for m in settled)} | {max(m['visiblePages'] for m in settled)} | {max(m['observedPageLoads'] for m in data)} |")
print("\nMemory uses public task_info TASK_VM_INFO for the benchmark host only. It excludes WebKit WebContent, network and GPU helper processes, so this is not total browser memory or a system-wide peak. Samples and weak instance tracking can miss short-lived transitions; allocator/framework caches persist between passes. Loads count observed container loadCount deltas, not a private WebKit allocation hook. Settled samples follow 500 ms at the first viewport; peak samples include offscreen visits and resize.\n")
print("| Workload | HTML revision | Live pages 250 ms after detach | Containers 500 ms after release |")
print("| --- | --- | ---: | ---: |")
for workload in ("long", "chat"):
    for revision in ("before", "after"):
        result = results[workload, revision, "html"]
        if not complete(result):
            print(f"| {workload} | {revision} | did not complete | — |")
            continue
        runs = warm(result)
        print(f"| {workload} | {revision} | {max(phase(p,'detachedWindow')['observedLivePages'] for p in runs)} | {max(phase(p,'releasedDocument')['observedRetainedContainers'] for p in runs)} |")
print("\nFixed-delay retained containers are observations, not evidence of a leak. A container with no live WebPage can still retain prepared source and measured height.\n")
print("## Single long message\n")
print("| Scenario | Revision | Feed p95 ms | UI apply/layout p95 ms | Scroll layout p95 ms | Stream heartbeat max gap ms | Scroll heartbeat max gap ms | Ready observed ms |")
print("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |")
for scenario in ("native", "html"):
    for revision in ("before", "after"):
        r = results["long", revision, scenario]
        if not complete(r):
            print(f"| {scenario} | {revision} | did not complete | — | — | — | — | — |")
            continue
        ready = f"{med(r, 'firstPreviewReadyMS'):.1f}" if scenario == "html" else "—"
        print(f"| {scenario} | {revision} | {med(r,'feed','p95'):.3f} | {med(r,'uiApply','p95'):.3f} | {med(r,'scrollLayout','p95'):.3f} | {max(p['streamHeartbeat']['max'] for p in warm(r)):.1f} | {max(p['scrollHeartbeat']['max'] for p in warm(r)):.1f} | {ready} |")
print("\nThis mode uses the production pipeline/controller directly in NSWindow/NSScrollView. It cooperatively bursts chunks with 1 ms between them. Feed and synchronous UI apply/layout/display are measured separately; asynchronous page rehydration is outside the scroll-layout operation time and inside heartbeat/readiness observations. Every HTML attachment is visited down and back; readiness requires a real page and matching container/attachment/measured heights, not just an isReady flag.\n")
print("## Real lazy chat\n")
print("| Scenario | Revision | First message ready ms | Visit-to-ready p50 ms | Visit-to-ready p95 ms | Stream closing yield-to-ready ms | MainActor heartbeat max gap ms | Post-ready scroll drift max pt |")
print("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |")
for scenario in ("native", "html"):
    for revision in ("before", "after"):
        r = results["chat", revision, scenario]
        if not complete(r):
            print(f"| {scenario} | {revision} | did not complete | — | — | — | — | — |")
            continue
        print(f"| {scenario} | {revision} | {med(r,'firstMessageReadyMS'):.1f} | {med(r,'visitToReady','p50'):.1f} | {med(r,'visitToReady','p95'):.1f} | {med(r,'streamedClosureToReadyMS'):.1f} | {max(p['mainActorHeartbeat']['max'] for p in warm(r)):.1f} | {max(p['maximumPostReadyScrollDriftPoints'] for p in warm(r)):.1f} |")
print("\nThis is an actual SwiftUI ScrollView/LazyVStack with stable ForEach message IDs and public PicoMarkdownView initializers, in an 800×640 NSWindow. Each message is requested at the top until it is actually visible and ready; all messages are visited in both directions. Public stream closing-yield latency includes delivery, parsing, publication, WebKit and sizing; it is not the direct pipeline feed measurement above. The command-line host explicitly services native layout/display. These are programmatic visits with settling, not frame-rate or human wheel-scroll measurements.\n")
print("The MainActor heartbeat requests a turn every 10 ms; reported gaps include timer scheduling, deferred SwiftUI/WebKit work, benchmark observation and host noise. Native controls show how much the host varied and are not visually identical in height because they display HTML source. Native chat completeness means its full footer is stored in a visible text view; HTML additionally requires real page and height readiness. Native post-completeness drift therefore exposes later lazy-layout estimation, and cross-scenario readiness timings are not equivalent operations.\n")
print("| Chat scenario | Revision | Stream factory attempts by pass | Chunks delivered by pass |")
print("| --- | --- | --- | --- |")
for scenario in ("native", "html"):
    for revision in ("before", "after"):
        result = results["chat", revision, scenario]
        if not complete(result):
            print(f"| {scenario} | {revision} | did not complete | — |")
            continue
        attempts = ", ".join(str(p["streamingAttempts"]) for p in result["passes"])
        chunks = ", ".join(str(p["streamingChunksDelivered"]) for p in result["passes"])
        print(f"| {scenario} | {revision} | {attempts} | {chunks} |")
print("\nThese counts include cancelled partial replay. The existing public stream API invokes its factory again when a lazy view disappears and reappears; the fixture returns the complete source on each invocation as required. The newest message therefore need not be one uninterrupted stream. Closing-yield-to-ready is an end-to-end public-view observation, not isolated per-feed latency; direct feed/apply measurements are reported only for the long-message harness.\n")

print("## Selection, source export and reflow\n")
print("All completed HTML runs passed without preview fallback or readiness timeout. In a completed single long message, the selected attachment range and its original fenced HTML export survived scrolling and resize. Lazy chat reselects the returned attachment and verifies identical fenced source export; it separately records whether the native selection survived SwiftUI remount.\n")
print("| HTML revision | Native selection survived lazy remount (all passes) | Source copy on return (all passes) | Initial / 320 pt / restored 800 pt height |")
print("| --- | --- | --- | --- |")
for revision in ("before", "after"):
    r = results["chat", revision, "html"]
    if not complete(r):
        print(f"| {revision} | did not complete | — | — |")
        continue
    p = warm(r)[0]
    selection = all(x['nativeSelectionOnReturn'] for x in r['passes'])
    copying = all(x['sourceCopyOnReturn'] for x in r['passes'])
    print(f"| {revision} | {selection} | {copying} | {p['initialPreviewHeight']:.0f} / {p['narrowPreviewHeight']:.0f} / {p['restoredPreviewHeight']:.0f} pt |")
print("\nThe first message is kept offscreen while the window narrows, then revisited. Its HTML table must grow in height at 320 pt and return to the original height at 800 pt. This validates width remeasurement rather than a cached stale height. The baseline includes the common native reattachment fix because unmodified 949f2f0 could remount an empty native text view, making a performance comparison invalid.")
