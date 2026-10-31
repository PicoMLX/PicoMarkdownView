#!/bin/bash
# Opt-in Release benchmark. BASELINE_REF creates an isolated source archive;
# never checks out/stashes the user's worktree or copies unrelated dirty files.
set -euo pipefail
benchmark_root="$(cd "$(dirname "$0")/.." && pwd)"
benchmark_label="${1:-after}"
benchmark_output="${2:-/private/tmp/pico-html-benchmark-results}"
benchmark_cards="${PICO_HTML_BENCH_CARDS:-80}"
benchmark_iterations="${PICO_HTML_BENCH_ITERATIONS:-3}"
if [[ ! "$benchmark_cards" =~ ^[1-9][0-9]*$ || ! "$benchmark_iterations" =~ ^[1-9][0-9]*$ ]]; then
    echo "PICO_HTML_BENCH_CARDS and PICO_HTML_BENCH_ITERATIONS must be positive integers." >&2
    exit 2
fi
benchmark_source="$benchmark_root"
benchmark_revision="$(git -C "$benchmark_root" rev-parse HEAD)"
if [[ -n "${BASELINE_REF:-}" ]]; then
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
    echo "cards=$benchmark_cards iterations=$benchmark_iterations build=release chunks=512 viewport=800x640"
} > "$benchmark_output/$benchmark_label-environment.txt"
# Build once with the workload disabled; then each scenario gets a fresh process.
PICO_HTML_BENCHMARK=0 swift test --package-path "$benchmark_source" --scratch-path "$benchmark_scratch" -c release --filter HTMLTranscriptBenchmark > "$benchmark_output/$benchmark_label-build.log" 2>&1
for benchmark_scenario in native html; do
    benchmark_result="$benchmark_output/$benchmark_label-$benchmark_scenario-$benchmark_cards.json"
    benchmark_log="$benchmark_output/$benchmark_label-$benchmark_scenario-$benchmark_cards.log"
    # This exact scenario file is already an intended overwrite. Removing it
    # prevents an early AppKit runner exit from reusing a previous result.
    rm -f "$benchmark_result"
    PICO_HTML_BENCHMARK=1 PICO_HTML_BENCH_SCENARIO="$benchmark_scenario" \
    PICO_HTML_BENCH_CARDS="$benchmark_cards" PICO_HTML_BENCH_ITERATIONS="$benchmark_iterations" \
    PICO_HTML_BENCH_REVISION="$benchmark_revision" \
    PICO_HTML_BENCH_OUTPUT="$benchmark_result" \
    swift test --package-path "$benchmark_source" --scratch-path "$benchmark_scratch" -c release --skip-build --filter HTMLTranscriptBenchmark > "$benchmark_log" 2>&1
    if [[ ! -s "$benchmark_result" ]] || ! grep -Eq 'Test run with [1-9][0-9]* tests?.* passed' "$benchmark_log"; then
        echo "Benchmark did not complete with a fresh JSON result: $benchmark_log" >&2
        exit 1
    fi
    echo "$benchmark_label $benchmark_scenario complete: $benchmark_output/$benchmark_label-$benchmark_scenario-$benchmark_cards.json"
done
