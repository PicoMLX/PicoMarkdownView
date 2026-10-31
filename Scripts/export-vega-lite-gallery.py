#!/usr/bin/env python3
"""Reproduce the complete official Vega-Lite 6.5.0 gallery as offline Markdown.

Only dataset URLs are replaced: JSON values are copied, and CSV/TSV fields
remain strings exactly as in d3-dsv. No rows, transforms, expressions,
selections, marks, or views are removed. Image references are retained and
reported because this renderer's static profile does not load images.

The default output is compressed storage for the example app. Use --output
to also write a standalone, uncompressed Markdown file. --offline requires
the two pinned archives to be present in --cache. --rendering-report also
creates a UI preview retaining exact successful chart fences and replacing
unsupported fences with short notices; the full corpus is unchanged.
"""

from __future__ import annotations

import argparse
import base64
import collections
import csv
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import urllib.request
import zlib

VEGA_LITE_VERSION = "6.5.0"
VEGA_LITE_COMMIT = "e415f441845e198629f2049b46849ddcfdbf6596"
SOURCE_URL = "https://codeload.github.com/vega/vega-lite/tar.gz/refs/tags/v6.5.0"
SOURCE_SHA256 = "063de9ac9f99e21da86958c82525680c041e654d9be0a7298ca431452ef2647f"
DATASETS_VERSION = "3.2.1"
DATASETS_URL = "https://registry.npmjs.org/vega-datasets/-/vega-datasets-3.2.1.tgz"
DATASETS_INTEGRITY = "sha512-lTSwZA6yq6qSU2YZm+6bqILiIvTPPxn4itir7jPGFmHIdPvUfQ9pCzzcrklYywMJgLUbaIeSkZQdiJd6wBxPug=="
LEGACY_CARS_URL = "https://cdn.jsdelivr.net/npm/vega-datasets@v1.29.0/data/cars.json"
LEGACY_CARS_SHA256 = "f686a53678b21f4231e2f6a5ba7ce5761d9d39204fccdea1caa29fb8c460e319"
GALLERY_URL = "https://vega.github.io/vega-lite/examples/"
SOURCE_ROOT = f"https://github.com/vega/vega-lite/blob/{VEGA_LITE_COMMIT}"


def json_bytes(value: object, *, pretty: bool = False) -> bytes:
    options = {"indent": 2} if pretty else {"separators": (",", ":")}
    return (json.dumps(value, ensure_ascii=False, allow_nan=False, **options) + "\n").encode("utf-8")


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def pinned_archive(cache: Path, filename: str, url: str, *, offline: bool,
                   expected_sha256: str | None = None, integrity: str | None = None) -> bytes:
    path = cache / filename
    if not path.exists():
        if offline:
            raise SystemExit(f"Missing pinned archive in offline mode: {path}")
        print(f"Downloading {url}", flush=True)
        with urllib.request.urlopen(url, timeout=90) as response:
            data = response.read()
        # A corrupt or untrusted download is never cached.
        verify_archive(data, filename, expected_sha256, integrity)
        cache.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    data = path.read_bytes()
    verify_archive(data, filename, expected_sha256, integrity)
    return data


def verify_archive(data: bytes, filename: str, expected_sha256: str | None,
                   integrity: str | None) -> None:
    if expected_sha256 and sha256(data) != expected_sha256:
        raise SystemExit(f"SHA-256 mismatch: {filename}")
    if integrity:
        actual = "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode("ascii")
        if actual != integrity:
            raise SystemExit(f"npm integrity mismatch: {filename}")


class Archive:
    """Read selected members without extracting archive paths to disk."""

    def __init__(self, data: bytes, prefix: str):
        self.tar = tarfile.open(fileobj=io.BytesIO(data), mode="r:gz")
        self.prefix = prefix

    def read(self, path: str) -> bytes:
        member = self.tar.getmember(self.prefix + path)
        if not member.isfile():
            raise ValueError(f"Expected an archive file: {path}")
        with self.tar.extractfile(member) as stream:
            return stream.read()

    def json(self, path: str) -> object:
        return json.loads(self.read(path))


class Inliner:
    def __init__(self, datasets: Archive, metadata: dict[str, dict]):
        self.datasets = datasets
        self.metadata = metadata
        self.used: dict[str, dict] = {}

    def asset(self, url: str, *, embedded: bool) -> tuple[str, bytes]:
        if url == LEGACY_CARS_URL:
            name = "cars.json"
        elif url.startswith("data/") and "/" not in url[5:]:
            name = url[5:]
        else:
            raise ValueError(f"Unrecognized data dependency; add an explicit pin: {url}")
        content = self.datasets.read("data/" + name)
        if url == LEGACY_CARS_URL and sha256(content) != LEGACY_CARS_SHA256:
            raise ValueError("Legacy cars dataset is not byte-identical to the pinned source")
        if name not in self.metadata:
            raise ValueError(f"Missing upstream dataset provenance: {name}")
        if name not in self.used:
            self.used[name] = {
                "id": name,
                "sha256": sha256(content),
                "bytes": len(content),
                "embedded": embedded,
                "sourceURLs": [],
                "upstreamMetadata": self.metadata[name],
            }
        record = self.used[name]
        record["embedded"] = record["embedded"] or embedded
        if url not in record["sourceURLs"]:
            record["sourceURLs"].append(url)
        return name, content

    @staticmethod
    def delimited_records(content: bytes, delimiter: str) -> list[dict[str, str]]:
        # d3-dsv maps missing columns to empty strings and ignores extra cells.
        # Python DictReader instead introduces None, so spell out the same map.
        rows = csv.reader(io.StringIO(content.decode("utf-8"), newline=""), delimiter=delimiter)
        columns = next(rows, [])
        return [{column: row[index] if index < len(row) else ""
                 for index, column in enumerate(columns)} for row in rows]

    def inline(self, node: object, issues: list[str], dependencies: list[str]) -> None:
        if isinstance(node, list):
            for child in node:
                self.inline(child, issues, dependencies)
            return
        if not isinstance(node, dict):
            return
        if isinstance(node.get("url"), str):
            url = node["url"]
            name, content = self.asset(url, embedded=True)
            dependencies.append(url)
            suffix = Path(name).suffix
            data_format = node.get("format", {})
            declared_type = data_format.get("type", suffix[1:])
            if suffix in (".csv", ".tsv") and declared_type in ("csv", "tsv"):
                node["values"] = self.delimited_records(content, "\t" if declared_type == "tsv" else ",")
                # Already decoded records are JSON; preserve parse directives.
                if "type" in data_format:
                    data_format["type"] = "json"
            elif suffix == ".json":
                node["values"] = json.loads(content)
                if not isinstance(node["values"], list):
                    issues.append(f"{name}: original JSON object and format retained; current renderer requires array data.")
                if data_format.get("type") == "topojson":
                    issues.append(f"{name}: TopoJSON feature/mesh format retained; maps are outside the current static profile.")
            else:
                # Do not guess a decoder or silently drop format semantics.
                node["values"] = content.decode("utf-8")
                data_format.setdefault("type", declared_type)
                node["format"] = data_format
                issues.append(f"{name}: raw data text and format retained; current renderer requires array data.")
            del node["url"]
            return
        for key, child in node.items():
            if key not in ("values", "datasets"):
                self.inline(child, issues, dependencies)

    def image_references(self, node: object, issues: list[str]) -> None:
        if isinstance(node, dict):
            for child in node.values():
                self.image_references(child, issues)
        elif isinstance(node, list):
            for child in node:
                self.image_references(child, issues)
        elif isinstance(node, str) and node.startswith("data/") and Path(node).suffix == ".png":
            self.asset(node, embedded=False)
            issues.append(f"{node}: original image reference retained without embedding; image marks are unsupported.")


def write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


def raw_deflate(content: bytes) -> bytes:
    compressor = zlib.compressobj(level=9, wbits=-15)
    return compressor.compress(content) + compressor.flush()


def rendering_preview(report_path: Path, chunks: list[str], fence_positions: list[int],
                      entries: list[dict], markdown: bytes, full_filename: str,
                      compressed_output: Path, output: Path | None, fixtures: Path) -> None:
    report_bytes = report_path.read_bytes()
    report = json.loads(report_bytes)
    unique_entries = {entry["id"]: entry for entry in entries}
    if (report.get("galleryEntries") != len(entries)
            or report.get("markdownBytes") != len(markdown)
            or report.get("uniqueSpecs") != len(unique_entries)):
        raise SystemExit("Rendering report counts do not match this complete pinned gallery")
    if report.get("sourceMarkdownSHA256", sha256(markdown)) != sha256(markdown):
        raise SystemExit("Rendering report belongs to a different full gallery source")
    samples = report.get("samples", [])
    by_id = {sample["id"]: sample for sample in samples}
    if len(by_id) != len(samples) or set(by_id) != set(unique_entries):
        raise SystemExit("Rendering report must classify every distinct gallery example exactly once")
    outcomes = {"chart", "source-size-fallback", "policy-fallback", "runtime-or-svg-fallback"}
    classifications = []
    for name, entry in unique_entries.items():
        sample = by_id[name]
        if sample.get("outcome") not in outcomes or sample.get("sourceBytes") != entry["sourceBytes"]:
            raise SystemExit(f"Rendering report source or outcome mismatch: {name}")
        classification = {"id": name, "outcome": sample["outcome"], "sourceBytes": sample["sourceBytes"]}
        if "dataMarkCount" in sample:
            classification["dataMarkCount"] = sample["dataMarkCount"]
        if report.get("testedWidths"):
            outcomes_by_width = sample.get("outcomesByWidth", {})
            expected_widths = {str(width) for width in report["testedWidths"]}
            if set(outcomes_by_width) != expected_widths or any(outcome != sample["outcome"] for outcome in outcomes_by_width.values()):
                raise SystemExit(f"Rendering report has inconsistent width outcomes: {name}")
        if "outcomesByWidth" in sample:
            classification["outcomesByWidth"] = sample["outcomesByWidth"]
        classifications.append(classification)
    baseline = set(report.get("baselineSuccessfulIDs", []))
    successful = {sample["id"] for sample in samples if sample["outcome"] == "chart"}
    if not baseline.issubset(successful):
        raise SystemExit("Rendering preview would drop previously successful examples: " + ", ".join(sorted(baseline - successful)))
    # Keep the exact classification input in the repository, without copying
    # environment-specific timings. This normalized file is itself accepted by
    # --rendering-report, making preview regeneration reproducible offline.
    normalized_report = {
        "version": 1,
        "kind": "gallery-rendering-classification",
        "benchmarkReportSHA256": report.get("benchmarkReportSHA256", sha256(report_bytes)),
        "sourceMarkdownSHA256": sha256(markdown),
        "galleryEntries": len(entries),
        "markdownBytes": len(markdown),
        "uniqueSpecs": len(unique_entries),
        "samples": classifications,
    }
    for key in ("testedWidths", "benchmarkReports", "baselineSuccessfulIDs", "sourceByteLimit"):
        if key in report:
            normalized_report[key] = report[key]
    normalized_bytes = json_bytes(normalized_report, pretty=True)
    preview_chunks = list(chunks)
    preview_entries = []
    chart_count = 0
    reason = {
        "source-size-fallback": "source exceeds the renderer's size limit",
        "policy-fallback": "unsupported data, expression, interaction, or other policy restriction",
        "runtime-or-svg-fallback": "runtime or SVG compatibility restriction",
    }
    for index, (entry, position) in enumerate(zip(entries, fence_positions)):
        outcome = by_id[entry["id"]]["outcome"]
        kept = outcome == "chart"
        preview_entry = {
            "id": entry["id"], "title": entry["title"], "category": entry["category"],
            "occurrence": entry["occurrence"], "sourceURL": entry["sourceURL"],
            "sourceSHA256": entry["sourceSHA256"], "sourceBytes": entry["sourceBytes"],
            "fullEntryIndex": index, "disposition": "chart" if kept else "notice", "outcome": outcome,
        }
        historical_size_note = "Complete inline source exceeds the current renderer's 131072-byte limit."
        if historical_size_note in entry["dataIssues"]:
            # The archived corpus keeps its original notes. The separately
            # measured preview describes current outcomes without changing
            # any specification or dataset bytes.
            data_note_position = position - 1
            if not preview_chunks[data_note_position].startswith("Data note: "):
                raise SystemExit(f"Missing historical data note for {entry['id']}")
            current_note = (
                f"Large inline dataset retained in full ({entry['sourceBytes']:,} UTF-8 source bytes). "
                "The chart appears after its entire specification has streamed."
                if kept else f"Complete inline source contains {entry['sourceBytes']:,} UTF-8 bytes."
            )
            preview_chunks[data_note_position] = preview_chunks[data_note_position].replace(
                historical_size_note, current_note)
        if kept:
            # Leave all three fence chunks byte-for-byte identical, including
            # the body newline whose digest is in the full gallery manifest.
            preview_entry["fenceIndex"] = chart_count
            chart_count += 1
        else:
            preview_entry["reason"] = reason[outcome]
            preview_chunks[position] = (
                f"Not rendered by current static profile: {reason[outcome]}. "
                "Original specification link above.\n\n")
            preview_chunks[position + 1] = ""
            preview_chunks[position + 2] = ""
        preview_entries.append(preview_entry)
    notice_count = len(entries) - chart_count
    successful_unique = sum(sample["outcome"] == "chart" for sample in samples)
    preview_chunks[0] = "# Vega-Lite Official Gallery Preview\n\n"
    preview_chunks[1] = (
        f"{chart_count} native plots and {notice_count} notices across all {len(entries)} official gallery placements "
        f"({successful_unique} successfully rendered distinct examples), in Vega-Lite {VEGA_LITE_VERSION} order. "
        f"[Official gallery]({GALLERY_URL}) · [Pinned source]({SOURCE_ROOT}/site/_data/examples.json).\n\n")
    preview_chunks[2] = (
        "Every retained chart uses its exact full inline dataset and original specification. "
        "Charts reported as unsupported are replaced by notices so their large fallback code blocks do not overwhelm the native view. "
        "No retained chart is sampled, simplified, or rewritten. Interactive charts are static snapshots. "
        "Large inline datasets can take minutes to stream word by word before their charts appear.\n\n")
    preview_chunks[3] = (
        f"The complete unmodified source for all {len(entries)} placements remains available separately as `{full_filename}` "
        "and can be exported to standalone Markdown with `Scripts/export-vega-lite-gallery.py --output /private/tmp/Charts-Gallery.md`. "
        "Gallery titles, links, descriptions, and dataset notices are retained below; historical size-limit warnings are updated for this preview. "
        "Dataset attribution and original license metadata accompany the full corpus and preview.\n\n")
    preview = "".join(preview_chunks).encode("utf-8")
    compressed = raw_deflate(preview)
    manifest = {
        "version": 1, "kind": "rendering-preview", "entryCount": len(entries),
        "chartCount": chart_count, "noticeCount": notice_count,
        "distinctChartCount": successful_unique,
        "sourceManifest": "manifest.json", "sourceMarkdownSHA256": sha256(markdown),
        "renderingReport": {"file": "preview-rendering-report.json", "sha256": sha256(normalized_bytes),
                            "benchmarkReportSHA256": normalized_report["benchmarkReportSHA256"]},
        "markdown": {"file": compressed_output.name, "compression": "deflate-raw",
                     "decodedBytes": len(preview), "decodedSHA256": sha256(preview),
                     "compressedBytes": len(compressed)},
        "entries": preview_entries,
    }
    write(compressed_output, compressed)
    if output:
        write(output, preview)
    write(fixtures / "preview-manifest.json", json_bytes(manifest, pretty=True))
    write(fixtures / "preview-rendering-report.json", normalized_bytes)
    print(f"Preview: {chart_count} exact native chart fences; {notice_count} notices; "
          f"{len(preview):,} Markdown bytes; {len(compressed):,} raw DEFLATE bytes")


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=Path(tempfile.gettempdir()) / "pico-vega-lite-gallery-v6.5.0")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--output", type=Path, help="Optional standalone uncompressed Markdown output")
    parser.add_argument("--compressed-output", type=Path, default=root / "MarkdownExample/MarkdownExample/markdown files/Charts-Gallery.md.deflate")
    parser.add_argument("--fixtures", type=Path, default=root / "Tests/Fixtures/VegaLiteGallery")
    parser.add_argument("--rendering-report", type=Path,
                        help="Optional benchmark JSON or saved preview-rendering-report.json for a practical UI preview")
    parser.add_argument("--preview-output", type=Path, help="Optional standalone preview Markdown output")
    parser.add_argument("--preview-compressed-output", type=Path,
                        default=root / "MarkdownExample/MarkdownExample/markdown files/Charts-Gallery-Preview.md.deflate")
    args = parser.parse_args()
    if args.preview_output and not args.rendering_report:
        parser.error("--preview-output requires --rendering-report")

    source_bytes = pinned_archive(args.cache, "source-v6.5.0.tgz", SOURCE_URL,
                                  offline=args.offline, expected_sha256=SOURCE_SHA256)
    datasets_bytes = pinned_archive(args.cache, "vega-datasets-3.2.1.tgz", DATASETS_URL,
                                    offline=args.offline, integrity=DATASETS_INTEGRITY)
    source = Archive(source_bytes, "vega-lite-6.5.0/")
    datasets = Archive(datasets_bytes, "package/")
    locked = source.json("package-lock.json")["packages"]["node_modules/vega-datasets"]
    if locked["version"] != DATASETS_VERSION or locked["integrity"] != DATASETS_INTEGRITY:
        raise SystemExit("Gallery source no longer matches the pinned dataset dependency")
    index = source.json("site/_data/examples.json")
    catalog = datasets.json("datapackage.json")
    inliner = Inliner(datasets, {item["path"]: item for item in catalog["resources"]})
    entries = []
    fence_positions = []
    occurrence = collections.Counter()
    chunks = [
        "# Vega-Lite Official Gallery\n\n",
        f"All 203 gallery placements (189 distinct examples), in the official Vega-Lite {VEGA_LITE_VERSION} order. "
        f"[Official gallery]({GALLERY_URL}) · [Pinned source]({SOURCE_ROOT}/site/_data/examples.json).\n\n",
        "Datasets are included inline in full. Original transformations, expressions, selections, views, and marks are retained. "
        "The current static renderer shows the source code when an example uses unsupported features or exceeds its resource limits. "
        "Maps, external images, interactive controls, and many calculated examples therefore appear as code. "
        "Rendering a supported interactive example produces a static snapshot.\n\n",
        "The complete document is deliberately large for performance exploration. "
        "Data attribution and original license metadata are preserved in the gallery manifest and licensing files. "
        "External community links listed below the official gallery are not imported.\n\n",
    ]
    for group, subgroups in index.items():
        chunks.append(f"## {group}\n\n")
        for subgroup, examples in subgroups.items():
            if subgroup:
                chunks.append(f"### {subgroup}\n\n")
            for example in examples:
                name = example["name"]
                occurrence[name] += 1
                path = f"examples/specs/{name}.vl.json"
                original = source.read(path)
                spec = json.loads(original)
                issues = []
                dependencies = []
                inliner.inline(spec, issues, dependencies)
                inliner.image_references(spec, issues)
                body = json_bytes(spec)
                if len(body) > 131_072:
                    issues.append("Complete inline source exceeds the current renderer's 131072-byte limit.")
                issues = list(dict.fromkeys(issues))
                entry = {
                    "id": name,
                    "title": example["title"],
                    "category": [part for part in (group, subgroup) if part],
                    "sourceURL": SOURCE_ROOT + "/" + path,
                    "occurrence": occurrence[name],
                    "sourceSHA256": sha256(body),
                    "upstreamSHA256": sha256(original),
                    "sourceBytes": len(body),
                    "dataSources": list(dict.fromkeys(dependencies)),
                    "dataIssues": issues,
                }
                entries.append(entry)
                heading = "####" if subgroup else "###"
                chunks.append(f"{heading} {example['title']}\n\n")
                chunks.append(f"[Official example](https://vega.github.io/vega-lite/examples/{name}.html) · "
                              f"[Pinned specification]({entry['sourceURL']})\n\n")
                if example.get("description"):
                    chunks.append(example["description"].strip() + "\n\n")
                if issues:
                    chunks.append("Data note: " + " ".join(issues) + "\n\n")
                fence_positions.append(len(chunks))
                chunks.extend(["```vega-lite\n", body.decode("utf-8"), "```\n\n"])
    if len(entries) != 203 or len(occurrence) != 189:
        raise SystemExit("Unexpected gallery index; do not silently change this pinned corpus")
    markdown = "".join(chunks).encode("utf-8")
    compressed = raw_deflate(markdown)
    upstream = {
        "galleryURL": GALLERY_URL,
        "vegaLiteVersion": VEGA_LITE_VERSION,
        "vegaLiteCommit": VEGA_LITE_COMMIT,
        "sourceArchive": {"url": SOURCE_URL, "sha256": SOURCE_SHA256},
        "galleryIndex": SOURCE_ROOT + "/site/_data/examples.json",
        "vegaDatasetsVersion": DATASETS_VERSION,
        "datasetsArchive": {"url": DATASETS_URL, "integrity": DATASETS_INTEGRITY},
        "legacyCarsAlias": {"url": LEGACY_CARS_URL, "sha256": LEGACY_CARS_SHA256,
                            "note": "The referenced 1.29.0 file is byte-identical to cars.json in the pinned 3.2.1 archive."},
    }
    manifest = {
        "version": 1,
        "upstream": upstream,
        "markdown": {"file": args.compressed_output.name, "compression": "deflate-raw", "decodedBytes": len(markdown),
                     "decodedSHA256": sha256(markdown), "compressedBytes": len(compressed)},
        "entryCount": len(entries),
        "distinctExampleCount": len(occurrence),
        "entries": entries,
        "datasets": sorted(inliner.used.values(), key=lambda item: item["id"]),
        "licenses": {
            "specifications": "Vega-Lite-LICENSE.txt",
            "datasets": "dataset-licenses.json",
            "note": catalog["description"],
        },
    }
    license_catalog = {
        "version": 1,
        "upstream": upstream["datasetsArchive"],
        "notice": catalog["description"],
        "resources": [item["upstreamMetadata"] for item in manifest["datasets"]],
    }
    write(args.compressed_output, compressed)
    if args.output:
        write(args.output, markdown)
    write(args.fixtures / "manifest.json", json_bytes(manifest, pretty=True))
    write(args.fixtures / "dataset-licenses.json", json_bytes(license_catalog, pretty=True))
    write(args.fixtures / "Vega-Lite-LICENSE.txt", source.read("LICENSE"))
    # The sample app redistributes the compressed corpus, so keep its source
    # attribution alongside that resource as well as in the test fixtures.
    write(args.compressed_output.parent / "Charts-Gallery-data-credits.json", json_bytes(license_catalog, pretty=True))
    write(args.compressed_output.parent / "Charts-Gallery-LICENSE.txt", source.read("LICENSE"))
    if args.rendering_report:
        rendering_preview(args.rendering_report, chunks, fence_positions, entries, markdown,
                          args.compressed_output.name, args.preview_compressed_output,
                          args.preview_output, args.fixtures)
    readme = f"""# Official Vega-Lite gallery corpus

The example app's `Charts-Gallery.md.deflate` contains all 203 official gallery
placements (189 distinct specifications) from Vega-Lite {VEGA_LITE_VERSION},
commit `{VEGA_LITE_COMMIT}`. Duplicate placements and their category order
match the original gallery index. This excludes externally hosted community
examples. Compression only changes storage; the renderer receives the complete
uncompressed Markdown.

Regenerate from the repository root:

```sh
python3 Scripts/export-vega-lite-gallery.py --output /private/tmp/Charts-Gallery.md
```

Use `--cache /path/to/archives --offline` for network-free regeneration. The
cache must contain `source-v6.5.0.tgz` and `vega-datasets-3.2.1.tgz`.
The script verifies the source archive SHA-256 and npm dataset SHA-512 before
reading any members. It reads files directly from archives without extracting
paths. Runtime rendering does not access the network.

JSON data is copied in full. CSV and TSV decode to string-valued records with
the same missing/extra-column mapping as d3-dsv; any format.parse directives
remain unchanged. Explicit CSV/TSV format types become JSON because the input
is now decoded records. TopoJSON objects and format.feature/mesh and JSON
format.property are retained. The three original image references remain in
the unsupported image example, with metadata recorded but no image download
at runtime. There is no sampling, preaggregation, transform evaluation,
expression removal, interaction removal, or lowering of renderer limits.

`manifest.json` entries correspond one-to-one with the Markdown fences.
`sourceSHA256` hashes the exact UTF-8 fenced body including its trailing LF;
`upstreamSHA256` hashes the original specification bytes before inlining.
Repeated IDs are distinguished by their 1-based `occurrence`.
`dataIssues` records retained non-array data, images, and sources exceeding
the original 128 KiB export profile. Those notes remain frozen with the full
corpus and can predate the current renderer limits; they are not a complete
renderability claim.

The specifications retain the upstream BSD-3-Clause license in
`Vega-Lite-LICENSE.txt`. Dataset licensing is separate: the pinned upstream
catalog says its BSD license covers package code and infrastructure only.
`dataset-licenses.json` retains each used resource's original source and license
metadata, including entries whose license is unspecified. The catalog is
upstream attribution metadata, not a representation that every dataset has
the same license. Do not replace these records with a blanket BSD notice.
The exporter also writes `Charts-Gallery-data-credits.json` and
`Charts-Gallery-LICENSE.txt` beside the compressed app resource.

The complete Markdown is {len(markdown):,} bytes; raw DEFLATE storage is
{len(compressed):,} bytes. `manifest.json` records both counts and the complete
Markdown SHA-256. Raw DEFLATE uses RFC 1951 (wbits=-15), matching Foundation's NSData.decompressed(using: .zlib). Compressed bytes may vary with zlib versions; uncompressed
content, its digest, and each fenced source are deterministic.

## Native UI preview

The app opens `Charts-Gallery-Preview.md.deflate`, a separate practical preview.
It retains every original gallery heading, description, link, and dataset note.
Historical 128 KiB warnings are replaced with current source byte counts; kept
charts explicitly note that their complete specification must arrive before
rendering. The archived full corpus and its notes remain unchanged.
Only chart fences measured as successful are included, byte-for-byte identical
to the full corpus. Other fences become short, classified notices. This avoids
laying out tens of megabytes of fallback source code in the native view while
leaving the complete unmodified corpus available for export and benchmarks.

The example streams at approximately 30 whitespace-delimited words per second.
`bar_grouped_repeated` alone retains 72,270 words of inline source (1,281,975
UTF-8 bytes), taking about 40 minutes 9 seconds from its opening fence to its
closing fence at that demonstration speed. Its following heading cannot arrive
before the closing fence. This is producer pacing: the renderer keeps one fixed
loading attachment while open and compiles the exact chart only after closure.

Regenerate the preview from its saved classification report:

```sh
python3 Scripts/export-vega-lite-gallery.py --rendering-report Tests/Fixtures/VegaLiteGallery/preview-rendering-report.json --preview-output /private/tmp/Charts-Gallery-Preview.md
```

Add the same `--cache /path/to/archives --offline` options for offline use.
Alternatively pass the JSON report from the opt-in native rendering benchmark.
The exporter checks all 189 IDs, source byte counts, the full corpus byte count,
and any supplied full-source digest before accepting a classification report.
`preview-manifest.json` records each of the 203 placements, its full-source
digest, retained-fence index or notice outcome, and the preview content digest.
`preview-rendering-report.json` preserves the 189 distinct classifications and
the original benchmark report digest, without copying its environment-specific
timings. This classification is a measured snapshot of the current renderer,
not a promise that every source in the full gallery is supported. When present,
`testedWidths` and `outcomesByWidth` record independent provider results at
each width; `baselineSuccessfulIDs` prevents regeneration from removing the
previously successful examples.
"""
    write(args.fixtures / "README.md", readme.encode("utf-8"))
    print(f"Exported {len(entries)} placements / {len(occurrence)} distinct specifications")
    print(f"Markdown: {len(markdown):,} bytes; raw DEFLATE: {len(compressed):,} bytes")
    print(f"Embedded datasets: {sum(item['embedded'] for item in inliner.used.values())}; retained images: "
          f"{sum(not item['embedded'] for item in inliner.used.values())}")
    print(f"SHA-256: {sha256(markdown)}")


if __name__ == "__main__":
    main()
