# Images & SVG showcase

`Images.md` combines offline raster fixtures, three native SVG demonstrations,
and image layout examples in paragraphs, lists and blockquotes.

The three unmodified PngSuite fixtures come from the official libpng repository,
release **v1.6.51**, commit `49363adcfaf098748d7a4c8c624ad8c45a8c3a86`:

- `basn2c08.png`: 8-bit RGB.
- `basn3p08.png`: 8-bit palette color.
- `basn6a08.png`: 8-bit RGBA.

All three originals are 32×32 pixels. `manifest.json` records immutable URLs,
SHA-256 hashes and dimensions. The example host maps `example-image:///…` URLs
to these bundled assets. The network image/ATS sample remains a separate variant.

The SVG graphics are **PicoMarkdownView's own examples**, selected from its
existing `SVG.md`. They are not an imported SVG conformance suite:

- **CSS and a color gradient**: CSS outlines, gradient fills, transparency.
- **Clipping and internal references**: clipped stripes, shared groups, repeated
  shapes with translated instances.
- **A gradient mask inside a quote**: a masked wave in a Markdown blockquote.

Their fence text remains unchanged, including the wave's quote prefix.
Surrounding prose and page composition are adapted. The manifest's `svg` entry
pins the original file commit/hash and each selected section/hash.

PngSuite copyright and permission are retained in `PngSuite-README.txt` and the
app-bundled `FixtureLicenses/Images-LICENSE.txt`. This is the PngSuite image
permission, distinct from libpng's code license. The project-authored SVGs use
PicoMarkdownView's MIT license, also bundled as `Images-SVG-LICENSE.txt`.

From the repository root:

```sh
python3 Scripts/export-media-examples.py --check
python3 Scripts/export-media-examples.py
python3 Scripts/export-media-examples.py --download
```

The first two commands work offline. `--check` validates PNG hashes, both source
corpus pins, the SVG/diagram selections and generated documents/manifests.
`--download` restores only the three PNG images from their pinned upstream URLs
and verifies hashes before writing.
