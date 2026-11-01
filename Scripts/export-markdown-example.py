#!/usr/bin/env python3
"""Generate the compact Markdown showcase from pinned, offline spec examples."""

import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "MarkdownExample/FixtureSources/Markdown"
OUTPUT = ROOT / "MarkdownExample/MarkdownExample/markdown files/Markdown.md"
MANIFEST = SOURCES / "manifest.json"
COMMONMARK = ROOT / "Conformance/Fixtures/commonmark-spec-0.31.2.json"
EXTENSIONS = SOURCES / "cmark-gfm-extensions-0.29.0.gfm.13.txt"
COMMONMARK_SHA = "e626f48c945674ee1f6da2b0675f9d60d6f14930a4cf15d849a4a094297b165b"
EXTENSIONS_SHA = "a2a45e98be9fca95f564f927265a0f63beea6cae5369d1cf4bde44caa51b2a3a"
CM_URL = "https://spec.commonmark.org/0.31.2/"
GFM_COMMIT = "587a12bb54d95ac37241377e6ddc93ea0e45439b"
GFM_URL = f"https://github.com/github/cmark-gfm/blob/{GFM_COMMIT}/test/extensions.txt"

# These cases are all closed, self-contained blocks with no overlapping link
# reference labels. Blank lines and section headings separate their contexts.
# Arbitrary conformance cases must not be concatenated this way.
CM_SECTIONS = [
    ("Headings", [62]),
    ("Emphasis", [350, 378, 410]),
    ("Inline code", [329]),
    ("Lists", [326]),
    ("Ordered lists", [302]),
    ("Blockquotes", [228, 251]),
    ("Links", [501]),
    ("Horizontal rule", [51]),
]
GFM_SECTIONS = [
    ("Tables", [1, 6]),
    ("Strikethrough", [17]),
    ("Task lists", [28]),
    ("Footnotes", [24]),
]


def read_checked(path, expected_sha):
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected_sha:
        raise SystemExit(f"Pinned fixture changed: {path}\nExpected {expected_sha}; got {actual}")
    return data.decode("utf-8")


def generate():
    commonmark = {case["number"]: case for case in json.loads(read_checked(COMMONMARK, COMMONMARK_SHA))}
    extensions = read_checked(EXTENSIONS, EXTENSIONS_SHA)
    pattern = r"^(`{32}) example\n(.*?)^\.\n(.*?)^\1\n"
    extension_cases = list(re.finditer(pattern, extensions, re.MULTILINE | re.DOTALL))
    if len(extension_cases) != 30:
        raise SystemExit("Unexpected cmark-gfm extensions corpus structure")

    parts = [
        "# Markdown",
        "A compact selection from CommonMark 0.31.2 and the cmark-gfm extension tests. "
        "Explore text formatting here; dedicated examples cover code, math, and rich content.",
    ]
    records = []
    for heading, numbers in CM_SECTIONS:
        parts.append(f"## {heading}")
        for number in numbers:
            case = commonmark[number]
            parts.append(case["markdown"].rstrip("\n"))
            records.append({
                "section": heading,
                "source": "commonmark",
                "case": number,
                "sourceSection": case["section"],
                "url": f"{CM_URL}#example-{number}",
                "changes": [],
            })
    for heading, numbers in GFM_SECTIONS:
        parts.append(f"## {heading}")
        for number in numbers:
            match = extension_cases[number - 1]
            markdown = match.group(2)
            changes = []
            if heading == "Tables" and number == 6:
                # GFM permits shorter delimiters; Pico currently requires at
                # least three hyphens per cell. Keep every alignment marker.
                markdown = markdown.replace(":-- | --- | :-: | --- | --:\n",
                                            ":--- | --- | :---: | --- | ---:\n")
                markdown = "\n".join(f"| {row} |" for row in markdown.rstrip("\n").splitlines()) + "\n"
                changes.extend([
                    "Expanded each table delimiter cell to at least three hyphens; retained alignment.",
                    "Added leading and trailing pipes to all three table rows; retained cell text and alignment.",
                ])
            if heading == "Strikethrough":
                # cmark-gfm also accepts single tildes. Use the double-tilde
                # spelling supported by PicoMarkdownView and ChatGPT.
                markdown = markdown.replace("~strikethrough~", "~~strikethrough~~")
                changes = ["Changed single-tilde delimiters to double tildes."]
            parts.append(markdown.rstrip("\n"))
            line = extensions[:match.start()].count("\n") + 1
            records.append({
                "section": heading,
                "source": "cmark-gfm",
                "case": number,
                "sourceLine": line,
                "url": f"{GFM_URL}#L{line}",
                "changes": changes,
            })
    parts.extend([
        "## Sources",
        f"Selected examples by John MacFarlane ([CommonMark 0.31.2]({CM_URL})) and "
        f"Yuki Izumi and contributors ([cmark-gfm 0.29.0.gfm.13]({GFM_URL})). "
        "Selection, section headings, and table/strikethrough syntax adaptations by PicoMarkdownView contributors. "
        "This example is licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).",
    ])
    markdown = "\n\n".join(parts) + "\n"
    manifest = {
        "output": str(OUTPUT.relative_to(ROOT)),
        "license": "CC-BY-SA-4.0",
        "commonmark": {
            "version": "0.31.2", "url": CM_URL,
            "input": str(COMMONMARK.relative_to(ROOT)), "sha256": COMMONMARK_SHA,
        },
        "cmark-gfm": {
            "version": "0.29.0.gfm.13", "commit": GFM_COMMIT, "url": GFM_URL,
            "input": str(EXTENSIONS.relative_to(ROOT)), "sha256": EXTENSIONS_SHA,
        },
        "cases": records,
        "outputSHA256": hashlib.sha256(markdown.encode()).hexdigest(),
    }
    return markdown, json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify committed output without writing")
    args = parser.parse_args()
    markdown, manifest = generate()
    for path, content in [(OUTPUT, markdown), (MANIFEST, manifest)]:
        if args.check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit(f"Regenerate with python3 Scripts/export-markdown-example.py: {path}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    case_count = sum(len(numbers) for _, numbers in CM_SECTIONS + GFM_SECTIONS)
    print(f"{'Verified' if args.check else 'Generated'} Markdown.md: {len(markdown.encode()):,} bytes, {case_count} selected cases")


if __name__ == "__main__":
    main()
