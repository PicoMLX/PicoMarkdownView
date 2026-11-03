---
name: svg-graphics
description: >-
  Create self-contained SVG illustrations when precise geometry, dimensions,
  or custom shapes explain something better than prose or a Mermaid graph.
  Use only when the client enables SVG previews; not for ordinary Markdown,
  quantitative charts better expressed as Vega-Lite, or interactive controls.
---

# Static vector illustrations

Use a fenced `svg` block containing one complete SVG document. Close the fence
before continuing the answer. Keep surrounding explanations, headings, lists,
tables, and equations in Markdown so they retain native selection and rendering.
Use Mermaid for relationships and flows; choose SVG when placement or shape
proportions carry information, such as matrices or a labeled technical figure.

## Client behavior

- PicoMarkdownView requires the app's SVG option on macOS 27. SVG previews are
  off by default. iOS retains the SVG source as a code block. Do not promise a
  rendered graphic when this option is unavailable; include its key meaning in
  prose and use supported Markdown, math, or Mermaid instead.
- Complete static documents are decoded when the fence closes; partial XML is
  not progressively drawn. Invalid or unsupported content remains source code.
- Copying the graphic with surrounding text exports its original fenced SVG.

## Authoring rules

- Start with `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 W H">`, using
  finite positive dimensions. Keep the document compact and readable at chat
  widths; avoid an oversized canvas or thousands of tiny objects.
- Prefer `rect`, `circle`, `ellipse`, `line`, `polyline`, `polygon`, `path`,
  `text`, `tspan`, and groups. Local definitions, gradients, clipping, masks,
  and fragment references such as `url(#gradient)` are supported when needed.
- Supply a direct child `<title>` and a useful `<desc>`: the native graphic uses
  these as its accessible description. Use visible labels, not color alone.
- Keep labels inside the viewBox, use readable text sizes, and give text enough
  contrast against its own shapes in both light and dark pages. SVG keeps the
  author's colors; the client does not recolor it to match the chat theme.
- Keep geometry truthful. Label schematic proportions or illustrative numbers.
  Put mathematical notation in the surrounding native math renderer when SVG
  text would make it harder to read.
- Use only static, self-contained content: no scripts, event handlers,
  animation, filters, `foreignObject`, embedded images, external fonts or other
  network resources. Do not include DTDs, entity declarations, CSS imports,
  CSS at-rules, or references outside this SVG. Use plain system font families.
- If the user asks to see XML source, use an `xml` code fence. Ordinary `html`
  fences also remain code; raw HTML is not an SVG rendering shortcut.

## Example

This schematic shows a 4-by-6 update as a 4-by-2 factor times a 2-by-6 factor.
The dimensions determine the relative rectangle sizes.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 170">
  <title>Low-rank matrix factorization</title>
  <desc>A 4 by 6 update equals a 4 by 2 factor multiplied by a 2 by 6 factor. Rectangles show the relative matrix dimensions.</desc>
  <style>text { paint-order: stroke; stroke: #f8fafc; stroke-width: 3; stroke-linejoin: round; }</style>
  <g font-family="Helvetica, Arial, sans-serif" font-size="14" text-anchor="middle" fill="#172554">
    <rect x="8" y="44" width="120" height="80" fill="#dbeafe" stroke="#2563eb"/>
    <text x="68" y="88">Update</text>
    <text x="68" y="148">4 × 6</text>
    <text x="143" y="88">=</text>
    <rect x="158" y="44" width="40" height="80" fill="#dcfce7" stroke="#15803d"/>
    <text x="178" y="88">A</text>
    <text x="178" y="148">4 × 2</text>
    <text x="215" y="88">×</text>
    <rect x="232" y="64" width="120" height="40" fill="#fef3c7" stroke="#b45309"/>
    <text x="292" y="88">B</text>
    <text x="292" y="148">2 × 6</text>
  </g>
</svg>
```
