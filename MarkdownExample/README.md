# Example app

Open `MarkdownExample.xcodeproj` and run the **MarkdownExample** scheme on macOS
or iOS Simulator. The sidebar has nine feature destinations:

| Destination | Samples |
| --- | --- |
| Markdown | Composed release review and pinned CommonMark/GFM cases; nested-block regression example |
| Code | Seven practical language examples and pinned Prism 1.29.0 tests |
| Math | Twenty SwiftMath 1.7.3 expressions with prose, tables and lists |
| Images & SVG | Combined offline PngSuite/SVG showcase; focused SVG and network image samples |
| Charts | Eleven inline-data chart placements and data tables; full offline gallery on macOS |
| Diagrams | Twelve published Pele examples; full published gallery |
| OpenUI | Forms, calendar and summary cards; optional HTML previews on macOS |
| Tags & Mentions | Tag syntax, callbacks, and fictional user/bot profile previews |
| Link Context Menus | Inert file/web mock menus on macOS |

Related samples and galleries are selected with **Example** in the feature's
toolbar. **Reference** opens a source or specification in the default browser;
the app doesn't load a browser comparison automatically. The **Preview**,
**Source**, and **Diagnostics** tabs share the same document. The large chart
gallery omits the extra tabs to avoid duplicate processing of its 32 MB source.

Every example offers **Stream**, **Stream 10×**, and **Full Text** playback.
Changing playback affects the rest of an active stream; **Replay** (Command-R)
starts again. Examples open in Full Text mode at the top of the document. Select Stream or
Stream 10× and press Replay to watch one arrive. Images load offline by default; the explicitly
selected Network Images sample requires internet access and tests the app's
existing HTTP/ATS exception.

Rich native chart, diagram, SVG, OpenUI, HTML, and context-menu features have
platform-specific support; the examples retain the library's iOS source-code
fallbacks. Profile previews can also be opened with keyboard or touch.

## Fixture sources

Authored compositions and upstream selections are pinned, attributed, and regenerated offline:

```sh
python3 Scripts/export-markdown-example.py --check
python3 Scripts/export-code-math-examples.py --check
python3 Scripts/export-media-examples.py --check
python3 Scripts/export-chart-examples.py --check
```

These checks also run in CI. Run them from the repository root. Omit `--check` to regenerate the curated
Markdown files and notices. `FixtureSources/` records immutable revisions,
original inputs, selection IDs, hashes, and adaptations. The app ships the
corresponding notices in `MarkdownExample/FixtureLicenses/`.

The original full Pele and Vega-Lite gallery resources stay canonical for their
existing regression suites. Parser conformance and performance workloads remain
under `Conformance/` and `Tests/PicoMarkdownViewBenchmarks/` rather than becoming
additional sidebar destinations. Synthetic interaction/layout samples stay
Pico-specific.
