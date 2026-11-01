# Code example sources

The example app contains selected excerpts from [PrismJS/prism](https://github.com/PrismJS/prism) 1.29.0, pinned to commit `59e5a3471377057de1f401ba38337aca27b80e03`. The vendored inputs and the manifest's hashes make regeneration offline and deterministic.

Run `python3 Scripts/export-code-math-examples.py` from the repository root. Add `--check` to verify that committed output matches these inputs without writing files.

The `.test` input format contains a source snippet, then a line of dashes, then expected tokens. The generator uses only the source section. `source_lines` selects inclusive lines within that section after normalizing CRLF to LF; a null end includes the rest. The Swift and Python selections are short, complete excerpt blocks. These are syntax-highlighter fixtures, not runnable sample programs.

The original MIT notice is in `LICENSE.txt`; both notices are also bundled in the app as `FixtureLicenses/Code-Math-LICENSE.txt`. Introductions, Markdown wrappers and page organization are PicoMarkdownView additions.
