# Diagram showcase

`Diagrams-Overview.md` selects twelve unchanged Mermaid fence bodies from the
already-vendored official Pele gallery in `Diagrams.md`. The page includes
flowchart, sequence, class, entity relationship, state, Gantt, Git graph, mindmap,
timeline, user journey, Sankey and radar examples. Concise explanations describe
what to inspect in each graphic.

`manifest.json` records the source corpus commit/hash, the one-based example
number within each named section, and each selected fence body's SHA-256. The
first Flowchart example is skipped so the page shows a familiar app/services/
storage graph. Entity relationship and Gantt use their second examples to show
a relational data model and task dependencies, respectively.

The original `Diagrams.md` retains all 58 examples across 32 families and is
still used by `PeleDemoExamplesTests`. Its full gallery is available from the
Diagrams page. The showcase uses the existing bundled Pele 1.9.1 renderer.

Regenerate both media pages and selection manifests with
`python3 Scripts/export-media-examples.py`; validate offline with `--check`.
The script deliberately refuses changed full diagram or SVG corpora until their
pins are reviewed. Pele's upstream license is retained in the app's fixture
notices. Only page titles, explanations and section order are adapted; selected
Mermaid fence bodies remain verbatim.
