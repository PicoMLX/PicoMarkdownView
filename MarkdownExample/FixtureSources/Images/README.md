# Offline image examples

`Images.md` displays three unmodified PngSuite fixtures from the official
libpng repository, release **v1.6.51**, commit
`49363adcfaf098748d7a4c8c624ad8c45a8c3a86`.

- `basn2c08.png`: 8-bit RGB.
- `basn3p08.png`: 8-bit palette color.
- `basn6a08.png`: 8-bit RGBA.

All three originals are 32×32 pixels. `manifest.json` records immutable URLs,
SHA-256 hashes and dimensions. The example host maps `example-image:///…` URLs
to these bundled assets. The network image/ATS sample remains a separate variant.

The fixture author's copyright and permission are retained in
`PngSuite-README.txt` and the app-bundled `FixtureLicenses/Images-LICENSE.txt`.
This is the PngSuite image permission, distinct from libpng's code license.

From the repository root:

```sh
python3 Scripts/export-media-examples.py --check
python3 Scripts/export-media-examples.py
python3 Scripts/export-media-examples.py --download
```

The first two commands work offline. `--download` restores only these three
images from their pinned upstream URLs and verifies hashes before writing.
