#!/usr/bin/env python3
"""Expand the chart showcase with exact, pinned, already-vendored gallery specs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zlib

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "MarkdownExample/MarkdownExample/markdown files"
SOURCES = ROOT / "MarkdownExample/FixtureSources/Charts"
PREVIEW = ROOT / "Tests/Fixtures/VegaLiteGallery/preview-manifest.json"
SELECTION = [
    ("bar_grouped", "Grouped comparisons", "Compare three groups side by side within each category. Group identity uses both the horizontal offset and the legend; the underlying nine observations appear below the plot."),
    ("bar_negative", "Values on both sides of zero", "Bars extend above and below a shared zero baseline. The conditional axis styling emphasizes zero while keeping a single quantitative scale."),
    ("histogram_log", "Transformations and logarithmic bins", "This official example calculates logarithms, bins the transformed values, and converts the bin boundaries back to the original units. It exercises a data transformation pipeline as well as a logarithmic axis."),
    ("bar_gantt", "Ranges and schedules", "A ranged bar has a start and an end rather than a shared zero baseline. The three sample tasks form a short sequence, making this a useful layout for schedules and intervals."),
    ("layer_bar_annotations", "Layered annotations", "The original example layers an emphasized part of a bar, a horizontal threshold rule, and a text annotation over its base plot. Its historical air-quality data and threshold are retained as an upstream rendering fixture."),
    ("trellis_anscombe", "Small multiples", "Four scatter plots share a consistent structure while revealing different distributions. The complete Anscombe data stays in the specification; resizing the window also exercises the layout of multiple plot panels."),
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def rows_in(spec):
    if isinstance(spec, dict):
        data = spec.get("data", {})
        if isinstance(data, dict) and isinstance(data.get("values"), list) and data["values"]:
            if all(isinstance(row, dict) and row for row in data["values"]):
                return data["values"]
        for value in spec.values():
            rows = rows_in(value)
            if rows:
                return rows
    if isinstance(spec, list):
        for value in spec:
            rows = rows_in(value)
            if rows:
                return rows
    return []


def data_table(spec):
    rows = rows_in(spec)
    if not rows:
        return ""
    columns = list(dict.fromkeys(key for row in rows for key in row))
    def cell(value):
        return str(value).replace("|", "\\|").replace("\n", " ") if value is not None else "—"
    lines = ["### Data", "", "| " + " | ".join(columns) + " |", "| " + " | ".join("---" for _ in columns) + " |"]
    lines.extend("| " + " | ".join(cell(row.get(key)) for key in columns) + " |" for row in rows)
    return "\n".join(lines)


def generate():
    preview = json.loads(PREVIEW.read_text())
    decoded = zlib.decompress((APP / "Charts-Gallery-Preview.md.deflate").read_bytes(), -15)
    if digest(decoded) != preview["markdown"]["decodedSHA256"]:
        raise ValueError("The canonical gallery preview no longer matches its pinned manifest")
    fences = re.findall(r"^```vega-lite\n(.*?)^```", decoded.decode(), re.M | re.S)
    parts = [(SOURCES / "composition.md").read_text().rstrip(), "## Official Vega-Lite examples", "The following six specifications are copied exactly from the pinned Vega-Lite 6.5.0 gallery, including their complete inline data. Accompanying Markdown explanations and data tables are additions for this example app. These are static native plots; the full Gallery contains the broader compatibility corpus."]
    records = []
    for identifier, heading, explanation in SELECTION:
        entry = next(item for item in preview["entries"] if item["id"] == identifier and item["disposition"] == "chart")
        source = fences[entry["fenceIndex"]]
        if digest(source.encode()) != entry["sourceSHA256"]:
            raise ValueError("Source mismatch: " + identifier)
        spec = json.loads(source)
        parts.extend(["## " + heading, explanation, "```vega-lite\n" + source + "```", "[Official example](" + entry["sourceURL"] + ")", data_table(spec)])
        records.append({"id": identifier, "sourceURL": entry["sourceURL"], "sourceSHA256": entry["sourceSHA256"], "changes": []})
    parts.extend(["## Explore further", "Use the Example selector to open the complete offline Gallery. Select Source to inspect every encoding and observation, or choose Stream and Replay to watch each closed fence become a chart. The published specifications retain their upstream appearance rather than applying a new example-app chart theme."])
    markdown = "\n\n".join(part for part in parts if part) + "\n"
    manifest = {"output": str((APP / "Charts.md").relative_to(ROOT)), "version": "6.5.0", "revision": "e415f441845e198629f2049b46849ddcfdbf6596", "input": str(PREVIEW.relative_to(ROOT)), "entries": records, "authoredComposition": str((SOURCES / "composition.md").relative_to(ROOT)), "outputSHA256": digest(markdown.encode()), "notices": "Charts-Gallery-LICENSE.txt and Charts-Gallery-data-credits.json (already bundled)"}
    return markdown, json.dumps(manifest, indent=2) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    markdown, manifest = generate()
    for path, content in [(APP / "Charts.md", markdown), (SOURCES / "manifest.json", manifest)]:
        if args.check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit("Regenerate chart examples: " + str(path.relative_to(ROOT)))
        else:
            path.write_text(content)
    print("Verified chart examples: five authored placements and six exact upstream specifications." if args.check else "Exported chart examples.")


if __name__ == "__main__":
    main()
