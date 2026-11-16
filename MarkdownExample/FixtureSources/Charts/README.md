# Chart showcase sources

`composition.md` contains PicoMarkdownView's original five illustrative chart placements and narrative. The generated page adds six verbatim Vega-Lite 6.5.0 specifications selected from the already-vendored offline gallery preview. The source revision, hashes, and URLs are recorded in `manifest.json`; canonical source and dataset provenance remain in `Tests/Fixtures/VegaLiteGallery/`.

The exporter verifies the canonical preview hash and every selected specification hash before composing the page. It adds explanatory prose and complete accessible Markdown tables of each selected plot's primary inline data, without editing specifications, values, appearance, or encodings.

Run `python3 Scripts/export-chart-examples.py` from the repository root, or append `--check` for an offline verification. Existing app-bundled `Charts-Gallery-LICENSE.txt` and `Charts-Gallery-data-credits.json` retain the upstream spec and dataset notices. The full gallery stays unchanged and separately selectable.
