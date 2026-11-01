# Diagram overview

`Diagrams-Overview.md` is a short selection of four unchanged Mermaid fence
bodies from the already-vendored official Pele gallery in `Diagrams.md`.
`manifest.json` records the source corpus commit/hash and one-based example
number within each named section. The first Flowchart example is skipped so
the overview shows a familiar app/services/storage graph.

The original `Diagrams.md` retains all 58 examples across 32 families and is
still used by `PeleDemoExamplesTests`. Its full gallery is available from the
Diagrams page. The overview uses the existing bundled Pele 1.9.1 renderer.

Regenerate both short media pages with
`python3 Scripts/export-media-examples.py`; validate offline with `--check`.
The script deliberately refuses a changed full corpus until its pin is reviewed.
Pele's upstream license is retained in the app's fixture notices.
