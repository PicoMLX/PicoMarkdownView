#!/usr/bin/env python3
"""Regenerate the short image/diagram examples; --check validates them offline."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "MarkdownExample/MarkdownExample"
SOURCES = ROOT / "MarkdownExample/FixtureSources"
DIAGRAMS_SHA256 = "2f2bf24d93e9167c4a2809915f5b5c9e918644aadc3b2fb830d534af988679b0"
SELECTION = [("Flowchart", 2), ("Sequence", 1), ("Class", 1), ("State", 1)]
IMAGES_MARKDOWN = """# Images

Three small PNGs from [PngSuite](https://github.com/pnggroup/libpng/tree/49363adcfaf098748d7a4c8c624ad8c45a8c3a86/contrib/pngsuite), bundled for offline viewing. These original test images are 32 × 32 pixels.

On macOS, click a standalone image to open the image viewer. Drag across the text and images to try continuous selection.

## RGB color

![PngSuite RGB color pattern](example-image:///basn2c08.png)

## Palette color

![PngSuite indexed color pattern](example-image:///basn3p08.png)

## Transparency

![PngSuite RGBA transparency pattern](example-image:///basn6a08.png)

## Image within text

Before ![RGB color pattern](example-image:///basn2c08.png) after.

*Images © Willem van Schaik, used with permission.*
"""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def outputs():
    corpus_path = APP / "markdown files/Diagrams.md"
    data = corpus_path.read_bytes()
    if sha256(data) != DIAGRAMS_SHA256:
        raise ValueError("Full diagram corpus changed; review the pinned selection before updating its hash.")
    source = data.decode("utf-8")
    examples = {}
    for section in re.finditer(r"^## ([^\n]+)\n(.*?)(?=^## |\Z)", source, re.M | re.S):
        for index, fence in enumerate(re.finditer(r"^```mermaid\n(.*?)^```[ \t]*$", section[2], re.M | re.S), 1):
            examples[(section[1], index)] = fence[1]
    markdown = "# Diagrams\n\nFour examples from [Pele’s published gallery](https://pele.run/examples), rendered as native graphics. Open the full gallery for more diagram types.\n"
    for section, number in SELECTION:
        markdown += f"\n## {section}\n\n```mermaid\n{examples[(section, number)]}```\n"
    return {
        APP / "markdown files/Images.md": IMAGES_MARKDOWN,
        APP / "markdown files/Diagrams-Overview.md": markdown,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate generated documents and bundled PNG hashes without network access.")
    parser.add_argument("--download", action="store_true", help="Restore the three PNGs from their immutable upstream URLs.")
    args = parser.parse_args()
    if args.check and args.download:
        parser.error("--check and --download are mutually exclusive")
    manifest = json.loads((SOURCES / "Images/manifest.json").read_text())
    for image in manifest["files"]:
        path = APP / "ExampleImages" / image["filename"]
        data = urllib.request.urlopen(image["sourceURL"]).read() if args.download else path.read_bytes()
        if sha256(data) != image["sha256"]:
            raise ValueError(f"Unexpected PNG content: {image['filename']}")
        if args.download:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    for path, content in outputs().items():
        if args.check:
            if path.read_text() != content:
                raise ValueError(f"Out-of-date generated example: {path.relative_to(ROOT)}")
        else:
            path.write_text(content)
    print("Validated 3 pinned PNGs and 2 generated media examples." if args.check else "Exported 2 media examples from pinned fixtures.")


if __name__ == "__main__":
    main()
