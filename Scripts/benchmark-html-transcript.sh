#!/bin/bash
# Opt-in Release benchmark. BASELINE_REF creates an isolated source archive;
# never checks out/stashes the user's worktree or copies unrelated dirty files.
set -euo pipefail
benchmark_root="$(cd "$(dirname "$0")/.." && pwd)"
benchmark_label="${1:-after}"
benchmark_output="${2:-/private/tmp/pico-html-benchmark-results}"
benchmark_cards="${PICO_HTML_BENCH_CARDS:-80}"
benchmark_iterations="${PICO_HTML_BENCH_ITERATIONS:-3}"
benchmark_kind="${PICO_HTML_BENCH_KIND:-long}"
case "$benchmark_kind" in long|chat|both) ;; *) echo "PICO_HTML_BENCH_KIND must be long, chat or both." >&2; exit 2 ;; esac
if [[ ! "$benchmark_cards" =~ ^[1-9][0-9]*$ || ! "$benchmark_iterations" =~ ^[1-9][0-9]*$ ]]; then
    echo "PICO_HTML_BENCH_CARDS and PICO_HTML_BENCH_ITERATIONS must be positive integers." >&2
    exit 2
fi
benchmark_source="${PICO_HTML_BENCH_SOURCE:-$benchmark_root}"
benchmark_revision="$(git -C "$benchmark_root" rev-parse HEAD)"
if [[ -n "${BASELINE_REF:-}" ]]; then
    if [[ -n "${PICO_HTML_BENCH_SOURCE:-}" ]]; then
        echo "Use either BASELINE_REF or PICO_HTML_BENCH_SOURCE, not both." >&2
        exit 2
    fi
    benchmark_revision="$(git -C "$benchmark_root" rev-parse "$BASELINE_REF")"
    benchmark_source="$(mktemp -d /private/tmp/pico-html-benchmark-before.XXXXXX)"
    git -C "$benchmark_root" archive "$benchmark_revision" | tar -x -C "$benchmark_source"
    cp -R "$benchmark_root/Tests/PicoMarkdownViewHTMLBenchmarks" "$benchmark_source/Tests/"
    python3 - "$benchmark_source/Package.swift" <<'PY'
from pathlib import Path
import re
import sys
p = Path(sys.argv[1])
s = p.read_text()
marker = '        .testTarget(\n            name: "PicoMarkdownViewHTMLTests",\n            dependencies: ["PicoMarkdownViewHTML"]\n        ),'
if re.search(r'name:\s*"PicoMarkdownViewHTMLBenchmarks"', s) is None:
    assert s.count(marker) == 1
    s = s.replace(marker, marker + '\n        .testTarget(name: "PicoMarkdownViewHTMLBenchmarks", dependencies: ["PicoMarkdownView", "PicoMarkdownViewHTML"]),')
    p.write_text(s)
PY
    if [[ "${PICO_HTML_BENCH_COMMON_REMOUNT_FIX:-0}" == "1" ]]; then
        # Keep this necessary native reattachment fix identical in both arms;
        # the viewport experiment must not compare against blank lazy rows.
        benchmark_common_core="Sources/PicoMarkdownView/Views/TextKitStreamingController.swift"
        cp "$benchmark_root/$benchmark_common_core" "$benchmark_source/$benchmark_common_core"
        cmp "$benchmark_root/$benchmark_common_core" "$benchmark_source/$benchmark_common_core"
        benchmark_revision="$benchmark_revision+common-mac-remount-fix"
    fi
elif [[ -n "${PICO_HTML_BENCH_SOURCE:-}" ]]; then
    benchmark_revision="${PICO_HTML_BENCH_REVISION_LABEL:?Set PICO_HTML_BENCH_REVISION_LABEL for a reused source archive}"
else
    if ! git -C "$benchmark_root" diff --quiet -- Sources/PicoMarkdownViewHTML; then
        benchmark_revision="$benchmark_revision+working-tree"
    fi
fi
mkdir -p "$benchmark_output"
benchmark_scratch="${PICO_HTML_BENCH_SCRATCH:-/private/tmp/pico-html-benchmark-$benchmark_label-build}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
{
    date -u '+%Y-%m-%dT%H:%M:%SZ'
    xcrun swift --version
    xcodebuild -version
    sw_vers
    sysctl -n hw.model hw.ncpu hw.memsize
    echo "source=$benchmark_source"
    echo "revision=$benchmark_revision"
    echo "cards=$benchmark_cards iterations=$benchmark_iterations kind=$benchmark_kind build=release chunks=512 viewport=800x640"
    shasum -a 256 "$benchmark_source/Sources/PicoMarkdownView/Views/TextKitStreamingController.swift"
} > "$benchmark_output/$benchmark_label-environment.txt"
# Build with both workloads disabled. Build-only/skip-build allow measurement
# after all compilation finishes, without a competing compiler process.
if [[ "${PICO_HTML_BENCH_SKIP_BUILD:-0}" != "1" ]]; then
    PICO_HTML_BENCHMARK=0 PICO_HTML_CHAT_BENCHMARK=0 swift test --package-path "$benchmark_source" --scratch-path "$benchmark_scratch" -c release --filter 'HTML(Chat)?TranscriptBenchmark' > "$benchmark_output/$benchmark_label-build.log" 2>&1
fi
if [[ "${PICO_HTML_BENCH_BUILD_ONLY:-0}" == "1" ]]; then
    echo "Built $benchmark_label: $benchmark_source"
    exit 0
fi
benchmark_kinds=("$benchmark_kind")
if [[ "$benchmark_kind" == "both" ]]; then benchmark_kinds=(long chat); fi
for benchmark_workload in "${benchmark_kinds[@]}"; do
    benchmark_filter=HTMLTranscriptBenchmark
    benchmark_suffix=""
    benchmark_long=1
    benchmark_chat=0
    if [[ "$benchmark_workload" == "chat" ]]; then
        benchmark_filter=HTMLChatTranscriptBenchmark
        benchmark_suffix="-chat"
        benchmark_long=0
        benchmark_chat=1
    fi
    for benchmark_scenario in native html; do
        benchmark_result="$benchmark_output/$benchmark_label$benchmark_suffix-$benchmark_scenario-$benchmark_cards.json"
        benchmark_log="$benchmark_output/$benchmark_label$benchmark_suffix-$benchmark_scenario-$benchmark_cards.log"
        # This exact scenario file is an intended overwrite. Clear it first so
        # an early AppKit runner exit cannot reuse a previous result.
        benchmark_failure="${benchmark_result%.json}.failure.json"
        rm -f "$benchmark_result" "$benchmark_failure"
        benchmark_status=0
        PICO_HTML_BENCHMARK="$benchmark_long" PICO_HTML_CHAT_BENCHMARK="$benchmark_chat" \
        PICO_HTML_BENCH_SCENARIO="$benchmark_scenario" \
        PICO_HTML_BENCH_CARDS="$benchmark_cards" PICO_HTML_BENCH_ITERATIONS="$benchmark_iterations" \
        PICO_HTML_BENCH_REVISION="$benchmark_revision" PICO_HTML_BENCH_OUTPUT="$benchmark_result" \
        swift test --package-path "$benchmark_source" --scratch-path "$benchmark_scratch" -c release --skip-build --filter "$benchmark_filter" > "$benchmark_log" 2>&1 || benchmark_status=$?
        if [[ "$benchmark_status" != "0" && "$benchmark_label" == "before" && "$benchmark_scenario" == "html" && "${PICO_HTML_BENCH_RECORD_BASELINE_FAILURES:-0}" == "1" ]] && grep -Eq 'HTML_(LONG|CHAT)_FIXTURE unreachable=' "$benchmark_log"; then
            # A failed baseline is evidence, not a score. Preserve its exact
            # provenance and continue native controls; never accept this for
            # an updated implementation or an unrelated runner failure.
            python3 - "$benchmark_source" "$benchmark_revision" "$benchmark_workload" "$benchmark_cards" "$benchmark_status" "$benchmark_log" "$benchmark_failure" <<'PY'
from pathlib import Path
import hashlib
import json
import sys
source, revision, workload, cards, status, log, output = sys.argv[1:]
root = Path(source)
files = [root / 'Sources/PicoMarkdownView/Views/TextKitStreamingController.swift']
for directory in ('Sources/PicoMarkdownViewHTML', 'Tests/PicoMarkdownViewHTMLBenchmarks'):
    files.extend(sorted((root / directory).glob('*.swift')))
record = {
    'revision': revision, 'workload': workload, 'scenario': 'html',
    'cards': int(cards), 'exitStatus': int(status),
    'completed': False, 'reason': 'unreachable-preview',
    'diagnostics': [line for line in Path(log).read_text().splitlines() if '_FIXTURE unreachable=' in line],
    'sourceHashes': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
}
Path(output).write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
PY
            echo "Recorded incomplete baseline: $benchmark_failure"
            continue
        fi
        if [[ "$benchmark_status" != "0" ]]; then
            echo "Benchmark failed: $benchmark_log" >&2
            exit "$benchmark_status"
        fi
        if [[ ! -s "$benchmark_result" ]] || ! grep -Eq 'Test run with [1-9][0-9]* tests?.* passed' "$benchmark_log"; then
            echo "Benchmark did not complete with a fresh JSON result: $benchmark_log" >&2
            exit 1
        fi
        echo "$benchmark_label $benchmark_workload $benchmark_scenario complete: $benchmark_result"
    done
done
