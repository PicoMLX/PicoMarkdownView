#!/usr/bin/env python3
"""Export short, pinned Prism/SwiftMath examples using only vendored inputs."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "MarkdownExample/FixtureSources"
APP = ROOT / "MarkdownExample/MarkdownExample"


def read_verified(path: Path, expected_hash: str) -> str:
    data = path.read_bytes()
    actual_hash = hashlib.sha256(data).hexdigest()
    if actual_hash != expected_hash:
        raise ValueError(f"Source hash mismatch: {path.relative_to(ROOT)}")
    return data.decode("utf-8").replace("\r\n", "\n")


def code_page() -> str:
    folder = SOURCES / "Code"
    manifest = json.loads((folder / "manifest.json").read_text())
    parts = [
        "# Code",
        "Language labels select syntax highlighting. Select code alongside the surrounding text, or copy a code block.",
    ]
    for fixture in manifest["fixtures"]:
        source = read_verified(folder / fixture["path"], fixture["sha256"])
        # Prism's .test format puts token expectations after a separator of 10+ dashes.
        snippet = re.split(r"^-{10,}[^\S\n]*$", source, maxsplit=1, flags=re.MULTILINE)[0]
        start, end = fixture["source_lines"]
        lines = snippet.strip("\n").splitlines()
        excerpt = "\n".join(lines[start - 1:end]).rstrip()
        parts.extend([f"## {fixture['title']}", f"```{fixture['language']}\n{excerpt}\n```"])
    url = f"{manifest['repository']}/tree/{manifest['revision']}/tests/languages"
    parts.append(f"Source: selected [Prism {manifest['version']} grammar tests]({url}), used under the MIT license.")
    return "\n\n".join(parts) + "\n"


def math_page() -> str:
    folder = SOURCES / "Math"
    manifest = json.loads((folder / "manifest.json").read_text())
    source = read_verified(folder / "EXAMPLES.md", manifest["sha256"])
    parts = ["# Math", "Native math rendering with inline expressions and display equations."]
    for fixture in manifest["examples"]:
        title = re.escape(fixture["title"])
        section = re.search(rf"^## {title}[^\S\n]*\n(.*?)(?=^## |\Z)", source, flags=re.MULTILINE | re.DOTALL)
        if section is None:
            raise ValueError(f"Missing SwiftMath example: {fixture['title']}")
        fence = re.search(r"^```LaTeX\n(.*?)\n```", section.group(1), flags=re.MULTILINE | re.DOTALL)
        if fence is None:
            raise ValueError(f"Missing TeX fence: {fixture['title']}")
        tex = "\n".join(line.rstrip() for line in fence.group(1).splitlines())
        if fixture["presentation"] == "inline":
            parts.extend(["## Inline expressions", f"The square of a sum fits within a paragraph: \\({tex}\\)."])
        else:
            parts.extend([f"## {fixture['title']}", f"\\[\n{tex}\n\\]"])
    url = f"{manifest['repository']}/blob/{manifest['revision']}/EXAMPLES.md"
    parts.append(f"Source: selected [SwiftMath {manifest['version']} examples]({url}), used under the MIT license.")
    return "\n\n".join(parts) + "\n"


def bundled_notices() -> str:
    parts = []
    for kind in ("Code", "Math"):
        folder = SOURCES / kind
        manifest = json.loads((folder / "manifest.json").read_text())
        parts.append(f"{manifest['repository']} {manifest['version']}\nRevision: {manifest['revision']}\n\n{(folder / 'LICENSE.txt').read_text().rstrip()}")
    return "\n\n----------------------------------------\n\n".join(parts) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify committed output without writing")
    args = parser.parse_args()
    outputs = {
        APP / "markdown files/Code.md": code_page(),
        APP / "markdown files/Math.md": math_page(),
        APP / "FixtureLicenses/Code-Math-LICENSE.txt": bundled_notices(),
    }
    stale = []
    for path, content in outputs.items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    if stale:
        print("Regenerate example fixtures: " + ", ".join(stale), file=sys.stderr)
        return 1
    print("Code and Math fixtures match pinned sources." if args.check else "Exported Code and Math fixtures.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
