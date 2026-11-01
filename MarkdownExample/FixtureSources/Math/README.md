# Math example sources

The example app contains selected excerpts from [mgriebling/SwiftMath](https://github.com/mgriebling/SwiftMath) 1.7.3, pinned to commit `fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7`. The vendored inputs and the manifest's hashes make regeneration offline and deterministic.

Run `python3 Scripts/export-code-math-examples.py` from the repository root. Add `--check` to verify that committed output matches these inputs without writing files.

The generator extracts the named `LaTeX` fences, trims trailing whitespace on each line, wraps them in Markdown inline or display math delimiters, and omits upstream reference images. Upstream headings are retained for the display examples. The app uses SwiftMath for native rendering.

The original MIT notice is in `LICENSE.txt`; both notices are also bundled in the app as `FixtureLicenses/Code-Math-LICENSE.txt`. Introductions, Markdown wrappers and page organization are PicoMarkdownView additions.
