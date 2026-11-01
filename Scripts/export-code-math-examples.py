#!/usr/bin/env python3
"""Export Code/Math showcases and pinned reference cases using vendored inputs."""

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
    authored = json.loads((folder / manifest["authored_examples"]).read_text())
    parts = [
        "# Code",
        "Explore syntax highlighting, selectable code, and source copying in a document with realistic examples. The examples below share a small weather-station dataset across several languages.",
        "The practical examples are authored for PicoMarkdownView. The final section contains separate, pinned Prism grammar-test excerpts.",
    ]
    for example in authored["examples"]:
        parts.extend([
            f"## {example['title']}",
            example["description"],
            f"```{example['language']}\n{example['source']}\n```",
        ])
    parts.extend([
        "## Upstream grammar reference",
        "These compact excerpts come directly from Prism's tests. They exercise particular grammar rules; they are not standalone programs. The first two also place code inside a quote and a list.",
    ])
    for fixture in manifest["fixtures"]:
        source = read_verified(folder / fixture["path"], fixture["sha256"])
        # Prism's .test format puts token expectations after a separator of 10+ dashes.
        snippet = re.split(r"^-{10,}[^\S\n]*$", source, maxsplit=1, flags=re.MULTILINE)[0]
        start, end = fixture["source_lines"]
        lines = snippet.strip("\n").splitlines()
        excerpt = "\n".join(lines[start - 1:end]).rstrip()
        fence = f"```{fixture['language']}\n{excerpt}\n```"
        if fixture.get("container") == "blockquote":
            fence = "> A function can be quoted alongside its explanation.\n>\n" + "\n".join("> " + line for line in fence.splitlines())
        elif fixture.get("container") == "list":
            fence = "- A decorator and the function it wraps:\n\n" + "\n".join("    " + line for line in fence.expandtabs(4).splitlines())
        parts.extend([f"### {fixture['title']}", fence])
    url = f"{manifest['repository']}/tree/{manifest['revision']}/tests/languages"
    parts.append(f"Reference source: selected [Prism {manifest['version']} grammar tests]({url}), used under the MIT license. Practical examples and document composition are PicoMarkdownView additions.")
    return "\n\n".join(parts) + "\n"


def math_page() -> str:
    folder = SOURCES / "Math"
    manifest = json.loads((folder / "manifest.json").read_text())
    source = read_verified(folder / "EXAMPLES.md", manifest["sha256"])
    parts = [
        "# Math",
        "Explore native typesetting in paragraphs, lists, tables, and displayed equations. The named equation examples below come from the pinned SwiftMath example collection, with explanatory prose added for this showcase.",
        "## Math in a document",
        r"A measurement $x_i$ can appear inside an ordinary sentence. The mean \(\mu\) and standard deviation $\sigma$ retain their mathematical appearance alongside **bold**, *italic*, and `code` text.",
        r"Both `$...$` and `\(...\)` delimit inline math. The displayed examples below also use both `$$...$$` and `\[...\]` delimiters.",
        "### A short analysis workflow",
        r"1. Collect the observations \(x_1, x_2, \ldots, x_N\)." + "\n" + r"2. Compute their mean, $\mu = \frac{1}{N}\sum_{i=1}^{N}x_i$." + "\n" + r"3. Compare each residual \(x_i-\mu\) with the spread $\sigma$.",
        "### Notation alongside prose",
        "| Quantity | Inline math | Meaning |\n| :--- | :---: | :--- |\n" + r"| Observation | \(x_i\) | The value of sample $i$ |" + "\n" + r"| Mean | $\mu = \frac{1}{N}\sum_{i=1}^{N}x_i$ | The center of the measurements |" + "\n" + r"| Variance | \(\sigma^2\) | The squared spread |" + "\n" + r"| Standard deviation | $\sqrt{\sigma^2}$ | Spread in the original units |",
        r"> **Reading tip:** The notation \(x_i\) describes one sample; $\{x_1,\ldots,x_N\}$ describes the collection. Selection can cross this quote, the table, and the equations below.",
        "## Equation collection",
    ]
    for fixture in manifest["examples"]:
        title = re.escape(fixture["title"])
        section = re.search(rf"^## {title}[^\S\n]*\n(.*?)(?=^## |\Z)", source, flags=re.MULTILINE | re.DOTALL)
        if section is None:
            raise ValueError(f"Missing SwiftMath example: {fixture['title']}")
        fence = re.search(r"^```LaTeX\n(.*?)\n```", section.group(1), flags=re.MULTILINE | re.DOTALL)
        if fence is None:
            raise ValueError(f"Missing TeX fence: {fixture['title']}")
        tex = "\n".join(line.rstrip() for line in fence.group(1).splitlines())
        if fixture["title"] == "Lorentz Equations":
            # The pinned documentation has an accidental quote after the last equation.
            tex = tex.replace('xy"', 'xy')
        parts.extend([f"### {fixture['title']}", fixture["description"]])
        presentation = fixture["presentation"]
        if presentation == "inline_parentheses":
            parts.append(f"Within a sentence: \\({tex}\\).")
        elif presentation == "inline_dollar":
            parts.append(f"Within a sentence: ${tex}$.")
        elif presentation == "display_dollar":
            parts.append(f"$$\n{tex}\n$$")
        elif presentation == "display_parentheses":
            parts.append(f"\\[\n{tex}\n\\]")
        else:
            raise ValueError(f"Unknown math presentation: {presentation}")
    url = f"{manifest['repository']}/blob/{manifest['revision']}/EXAMPLES.md"
    parts.append(f"Equation source: [SwiftMath {manifest['version']} examples]({url}), used under the MIT license. The Lorentz example's stray terminal quote is removed; other equation bodies are unchanged apart from trailing whitespace. Prose, table, lists, and Markdown composition are PicoMarkdownView additions.")
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
