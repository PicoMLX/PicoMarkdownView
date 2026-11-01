# Curated Markdown fixture

`../../MarkdownExample/markdown files/Markdown.md` is the example app's compact
text-formatting showcase. Regenerate it offline from the repository root:

```sh
python3 Scripts/export-markdown-example.py
python3 Scripts/export-markdown-example.py --check
```

The generator selects 11 CommonMark examples and five cmark-gfm examples.
`manifest.json` records each source case, section, URL, modification, input hash,
and the generated output hash.

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
next section; the footnote case has a unique reference label. Do not replace
this selection with arbitrary concatenated conformance inputs: unclosed fences,
lists, and document-wide reference definitions can change neighboring cases.

## License and adaptation

Both sources use **CC BY-SA 4.0**. The generated adaptation uses that license too.
The CommonMark spec attributes John MacFarlane; the extensions snapshot attributes
Yuki Izumi, version 0.1, dated 2016-08-31. Added introductory prose and headings
are by PicoMarkdownView contributors. Two sample syntax adaptations match the
renderer’s current supported subset: single-tilde strikethrough becomes double
tildes, and the aligned table’s delimiter cells are expanded to at least three
hyphens each while retaining their alignment markers. The table’s three rows
also receive leading and trailing pipes. All cell text is unchanged. The
selection omits the hard-line-break case because the native renderer currently
presents it as a soft line break. The original pinned sources remain unchanged.
A license/attribution notice is included in the app at
`MarkdownExample/MarkdownExample/FixtureLicenses/Markdown-LICENSE.txt`.
