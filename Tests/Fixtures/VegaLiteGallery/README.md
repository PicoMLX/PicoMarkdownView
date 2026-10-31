# Official Vega-Lite gallery corpus

The example app's `Charts-Gallery.md.deflate` contains all 203 official gallery
placements (189 distinct specifications) from Vega-Lite 6.5.0,
commit `e415f441845e198629f2049b46849ddcfdbf6596`. Duplicate placements and their category order
match the original gallery index. This excludes externally hosted community
examples. Compression only changes storage; the renderer receives the complete
uncompressed Markdown.

Regenerate from the repository root:

```sh
python3 Scripts/export-vega-lite-gallery.py --output /private/tmp/Charts-Gallery.md
```

Use `--cache /path/to/archives --offline` for network-free regeneration. The
cache must contain `source-v6.5.0.tgz` and `vega-datasets-3.2.1.tgz`.
The script verifies the source archive SHA-256 and npm dataset SHA-512 before
reading any members. It reads files directly from archives without extracting
paths. Runtime rendering does not access the network.

JSON data is copied in full. CSV and TSV decode to string-valued records with
the same missing/extra-column mapping as d3-dsv; any format.parse directives
remain unchanged. Explicit CSV/TSV format types become JSON because the input
is now decoded records. TopoJSON objects and format.feature/mesh and JSON
format.property are retained. The three original image references remain in
the unsupported image example, with metadata recorded but no image download
at runtime. There is no sampling, preaggregation, transform evaluation,
expression removal, interaction removal, or lowering of renderer limits.

`manifest.json` entries correspond one-to-one with the Markdown fences.
`sourceSHA256` hashes the exact UTF-8 fenced body including its trailing LF;
`upstreamSHA256` hashes the original specification bytes before inlining.
Repeated IDs are distinguished by their 1-based `occurrence`.
`dataIssues` records retained non-array data, images, and sources exceeding
the current 128 KiB renderer limit; it is not a complete renderability claim.

The specifications retain the upstream BSD-3-Clause license in
`Vega-Lite-LICENSE.txt`. Dataset licensing is separate: the pinned upstream
catalog says its BSD license covers package code and infrastructure only.
`dataset-licenses.json` retains each used resource's original source and license
metadata, including entries whose license is unspecified. The catalog is
upstream attribution metadata, not a representation that every dataset has
the same license. Do not replace these records with a blanket BSD notice.
The exporter also writes `Charts-Gallery-data-credits.json` and
`Charts-Gallery-LICENSE.txt` beside the compressed app resource.

The complete Markdown is 67,025,394 bytes; raw DEFLATE storage is
9,658,735 bytes. `manifest.json` records both counts and the complete
Markdown SHA-256. Raw DEFLATE uses RFC 1951 (wbits=-15), matching Foundation's NSData.decompressed(using: .zlib). Compressed bytes may vary with zlib versions; uncompressed
content, its digest, and each fenced source are deterministic.

## Native UI preview

The app opens `Charts-Gallery-Preview.md.deflate`, a separate practical preview.
It retains every original gallery heading, description, link, and data note.
Only chart fences measured as successful are included, byte-for-byte identical
to the full corpus. Other fences become short, classified notices. This avoids
laying out tens of megabytes of fallback source code in the native view while
leaving the complete unmodified corpus available for export and benchmarks.

Regenerate the preview from its saved classification report:

```sh
python3 Scripts/export-vega-lite-gallery.py --rendering-report Tests/Fixtures/VegaLiteGallery/preview-rendering-report.json --preview-output /private/tmp/Charts-Gallery-Preview.md
```

Add the same `--cache /path/to/archives --offline` options for offline use.
Alternatively pass the JSON report from the opt-in native rendering benchmark.
The exporter checks all 189 IDs, source byte counts, the full corpus byte count,
and any supplied full-source digest before accepting a classification report.
`preview-manifest.json` records each of the 203 placements, its full-source
digest, retained-fence index or notice outcome, and the preview content digest.
`preview-rendering-report.json` preserves the 189 distinct classifications and
the original benchmark report digest, without copying its environment-specific
timings. This classification is a measured snapshot of the current renderer,
not a promise that every source in the full gallery is supported.
