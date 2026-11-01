# Math example sources

The example app contains all 20 named expressions from [mgriebling/SwiftMath](https://github.com/mgriebling/SwiftMath) 1.7.3, pinned to commit `fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7`. The vendored input and manifest hash make regeneration offline and deterministic.

Run `python3 Scripts/export-code-math-examples.py` from the repository root. Add `--check` to verify that committed output matches these inputs without writing files.

The generator extracts named `LaTeX` fences, trims trailing whitespace, wraps them in Markdown inline or display math delimiters, and omits upstream reference images. The stray terminal double quote in the upstream Lorentz Equations sample is removed; the vendored input remains unchanged. Each original heading is retained. Adaptations are recorded in `manifest.json`.

Explanatory prose, the introductory notation table, list, blockquote, and Markdown composition are authored PicoMarkdownView additions, separate from the pinned equation bodies. Both inline delimiter forms and both display delimiter forms appear in the showcase. The app uses SwiftMath for native rendering.

The original MIT notice is in `LICENSE.txt`; both notices are also bundled in the app as `FixtureLicenses/Code-Math-LICENSE.txt`.
