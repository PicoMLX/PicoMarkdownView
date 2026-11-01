# Curated Markdown fixture

`../../MarkdownExample/markdown files/Markdown.md` is the example app's
text-formatting showcase. Regenerate it offline from the repository root:

```sh
python3 Scripts/export-markdown-example.py
python3 Scripts/export-markdown-example.py --check
```

The page begins with `authored-showcase.md`, an original fictional Harbor Notes
release review by PicoMarkdownView contributors. It combines paragraphs,
headings, mixed inline styles, nested ordered/unordered/task lists, blockquotes,
two aligned tables, inline links and footnotes. All project names, counts and
timings were composed for this example; they are not app benchmarks.

A separate **Specification examples** section contains six CommonMark cases and
four cmark-gfm cases. `manifest.json` distinguishes the authored composition from
the pinned upstream cases, recording their source paths, authors, licenses,
hashes, case IDs, URLs and modifications. The generator also records the final
output hash. Both components are distributed under CC BY-SA 4.0.

## Pinned sources

- **CommonMark 0.31.2**, John MacFarlane:
  <https://spec.commonmark.org/0.31.2/>. The existing normalized conformance JSON
  at `Conformance/Fixtures/commonmark-spec-0.31.2.json` is the input. Original
  example numbers are retained.
- **cmark-gfm 0.29.0.gfm.13**, commit
  `587a12bb54d95ac37241377e6ddc93ea0e45439b`:
  <https://github.com/github/cmark-gfm/blob/587a12bb54d95ac37241377e6ddc93ea0e45439b/test/extensions.txt>.
  The adjacent snapshot is byte-for-byte upstream. Examples are numbered by
  their order in that file; the manifest also stores the original source lines.

These are small, valid, self-contained selections for a rendered showcase, not
an assertion of complete conformance. All selected blocks terminate before the
next section. The authored report uses `harbor-` footnote labels, which are
distinct from the specification case’s `a-footnote` label. Do not replace
this selection with arbitrary concatenated conformance inputs: unclosed fences,
lists, and document-wide reference definitions can change neighboring cases.

## License and adaptation

Both sources use **CC BY-SA 4.0**. The generated adaptation uses that license too.
The CommonMark spec attributes John MacFarlane; the extensions snapshot attributes
Yuki Izumi, version 0.1, dated 2016-08-31. The authored Harbor Notes report,
introductory prose and section headings are by PicoMarkdownView contributors,
who license their contributions to this fixture under CC BY-SA 4.0. Two sample syntax adaptations match the
renderer’s current supported subset: single-tilde strikethrough becomes double
tildes, and the aligned table’s delimiter cells are expanded to at least three
hyphens each while retaining their alignment markers. The table’s three rows
also receive leading and trailing pipes. All cell text is unchanged. The
selection omits the hard-line-break case because the native renderer currently
presents it as a soft line break. Links use ordinary inline destinations; the
reference-link case is omitted because its definitions currently appear as
visible text in the native renderer. The original pinned sources remain unchanged.
A license/attribution notice is included in the app at
`MarkdownExample/MarkdownExample/FixtureLicenses/Markdown-LICENSE.txt`.
