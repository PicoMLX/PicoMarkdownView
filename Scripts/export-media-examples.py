#!/usr/bin/env python3
"""Regenerate the image/SVG and diagram showcases; --check validates them offline."""

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
SELECTION = [
    ("Flowchart", 2, "An application architecture with grouped clients, services and storage. Solid and dotted arrows distinguish the paths between components."),
    ("Sequence", 1, "An order moves from customer to web app, API and bank. Numbered messages, an activation bar and a note show the stages of the exchange."),
    ("Class", 1, "Nested namespaces organise a volcanic system. Classes expose methods, and labelled relationships connect the parts."),
    ("Entity relationship", 2, "Cars, people and named drivers form a data model with primary, foreign and unique keys, typed fields and relationship cardinality."),
    ("State", 1, "A document progresses from draft to publication. A nested review state and labelled transitions show approval and rejection paths."),
    ("Gantt", 2, "Task durations, calendar dates and a dependency appear on a shared timeline, grouped into project sections."),
    ("Git graph", 1, "Branches diverge, merge and receive a cherry-picked commit. Explicit commit names make the resulting history easy to follow."),
    ("Mindmap", 1, "A central topic branches into history, nature and culture. Nested labels demonstrate hierarchy, Unicode text and multiline content."),
    ("Timeline", 1, "Sectioned events and multiple labels describe the Hawaiian islands in a chronological layout."),
    ("User journey", 1, "A working day is split into phases. Each task includes a score and the people involved, adding an experience dimension to the sequence."),
    ("Sankey", 1, "Flows from the electricity grid split into destinations. The width of each connection represents its numeric amount."),
    ("Radar", 1, "Four restaurant profiles share the same labelled axes and scale, making their relative strengths visible in one graphic."),
]
SVG_SELECTION = [
    "CSS and a color gradient",
    "Clipping and internal references",
    "A gradient mask inside a quote",
]
IMAGES_INTRO = """# Images & SVG

Raster images and vector graphics share one selectable document. These samples are bundled with the app and work offline. On macOS, click a standalone image to open the image viewer, or hover over a vector graphic to reveal its zoom and copy controls. SVG fences remain readable source on iOS.

## Raster image formats

These original [PngSuite images](https://github.com/pnggroup/libpng/tree/49363adcfaf098748d7a4c8c624ad8c45a8c3a86/contrib/pngsuite) are deliberately small: each is 32 × 32 pixels. They exercise three ways to store PNG color.

### RGB color

Three 8-bit channels store the red, green and blue components of each pixel.

![PngSuite RGB color pattern](example-image:///basn2c08.png)

### Palette color

Pixels refer to entries in a color palette rather than storing an RGB value directly.

![PngSuite indexed color pattern](example-image:///basn3p08.png)

### Color with transparency

An alpha channel adds per-pixel transparency to the color channels.

![PngSuite RGBA transparency pattern](example-image:///basn6a08.png)

## CSS and a color gradient

The circles combine a CSS class for their outlines, a linear gradient, and overlapping translucent fills. The graphic fits the text width; zooming preserves the vector edges.

"""
IMAGES_CLIP = """

## Clipping, groups and reused shapes

The striped background is clipped to a circle. A single star path is reused three times with different translations, while a parent group supplies their shared fill and stroke.

"""
IMAGES_LAYOUT = """

## Images within text

An RGB image ![RGB color pattern](example-image:///basn2c08.png) can sit between words, including **bold text**, *emphasis* and a [regular link](https://www.libpng.org/pub/png/). The sentence continues after the attachment, so selecting and copying can span both text and image source.

Palette ![indexed color pattern](example-image:///basn3p08.png) and transparent ![RGBA transparency pattern](example-image:///basn6a08.png) images also work within the same paragraph.

## Images in lists and blockquotes

- ![RGB pattern within a list](example-image:///basn2c08.png)
  This image belongs to a list item, with a caption that wraps inside the list indentation.
- The next item continues as ordinary Markdown text.
- A compact inline sample ![palette pattern within a list](example-image:///basn3p08.png) stays within the surrounding sentence.

> ![Transparent pattern within a blockquote](example-image:///basn6a08.png)
>
> The image and this caption share the quote's indentation. Drag a selection from outside the quote through the image and back into the text.

## An SVG mask within a blockquote

The wave below uses a gradient mask to fade its fill. Its container is a native Markdown blockquote, so the graphic receives the width left after the quote indentation.

"""
IMAGES_END = """
>
> The blockquote continues with selectable text beneath the graphic.

## Selection and source copying

Select from this paragraph back through the wave, images and captions. Copying a selection preserves the underlying Markdown image URLs and SVG fences. On macOS, try the graphic's Copy source control, then zoom in and press Escape to return to the document.

*Raster fixtures © Willem van Schaik, used with permission. Vector examples are PicoMarkdownView's own SVG demonstrations, reused from its SVG example.*
"""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def diagram_examples(source):
    examples = {}
    for section in re.finditer(r"^## ([^\n]+)\n(.*?)(?=^## |\Z)", source, re.M | re.S):
        for index, fence in enumerate(re.finditer(r"^```mermaid\n(.*?)^```[ \t]*$", section[2], re.M | re.S), 1):
            examples[(section[1], index)] = fence[1]
    return examples


def svg_examples(source):
    examples = {}
    for section in re.finditer(r"^## ([^\n]+)\n(.*?)(?=^## |\Z)", source, re.M | re.S):
        fences = re.findall(r"^((?:> )?```svg\n.*?^(?:> )?```[ \t]*$)", section[2], re.M | re.S)
        if fences:
            examples[section[1]] = fences[0]
    return examples


def outputs():
    corpus_path = APP / "markdown files/Diagrams.md"
    data = corpus_path.read_bytes()
    if sha256(data) != DIAGRAMS_SHA256:
        raise ValueError("Full diagram corpus changed; review the pinned selection before updating its hash.")
    examples = diagram_examples(data.decode("utf-8"))
    markdown = "# Diagrams\n\nTwelve examples from [Pele’s published gallery](https://pele.run/examples) demonstrate different diagram families, layouts and notation. Each graphic is followed by ordinary selectable Markdown. Open the full gallery for the complete set.\n"
    for section, number, description in SELECTION:
        markdown += f"\n## {section}\n\n{description}\n\n```mermaid\n{examples[(section, number)]}```\n"
    markdown += "\nTry zooming a diagram, copying its source, and selecting text across the boundary between a paragraph and its graphic.\n"
    diagram_manifest_path = SOURCES / "Diagrams/manifest.json"
    diagram_manifest = json.loads(diagram_manifest_path.read_text())
    diagram_manifest["selection"] = [
        {"section": section, "example": number, "sourceSHA256": sha256(examples[(section, number)].encode("utf-8"))}
        for section, number, _ in SELECTION
    ]
    diagram_manifest["adaptations"] = "Twelve Mermaid fence bodies unchanged; page title, explanations and section order adapted for the feature showcase."
    image_manifest_path = SOURCES / "Images/manifest.json"
    image_manifest = json.loads(image_manifest_path.read_text())
    svg_manifest = image_manifest["svg"]
    svg_source = (ROOT / svg_manifest["sourceCorpus"]).read_bytes()
    if sha256(svg_source) != svg_manifest["sourceCorpusSHA256"]:
        raise ValueError("Original SVG example changed; review the selected graphics before updating its hash.")
    svgs = svg_examples(svg_source.decode("utf-8"))
    svg_manifest["selection"] = [{"section": section, "example": 1, "sourceSHA256": sha256(svgs[section].encode("utf-8"))} for section in SVG_SELECTION]
    images = (IMAGES_INTRO + svgs[SVG_SELECTION[0]] + IMAGES_CLIP + svgs[SVG_SELECTION[1]]
              + IMAGES_LAYOUT + svgs[SVG_SELECTION[2]] + IMAGES_END)
    return {
        APP / "markdown files/Images.md": images,
        APP / "markdown files/Diagrams-Overview.md": markdown,
        diagram_manifest_path: json.dumps(diagram_manifest, indent=2) + "\n",
        image_manifest_path: json.dumps(image_manifest, indent=2) + "\n",
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
    print("Validated 3 pinned PNGs, 3 source SVGs, 12 source diagrams and generated documents." if args.check else "Exported the image/SVG and diagram showcases from pinned fixtures.")


if __name__ == "__main__":
    main()
