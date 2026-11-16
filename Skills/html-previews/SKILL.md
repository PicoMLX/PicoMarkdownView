---
name: html-previews
description: >-
  Create a static HTML/CSS preview or visual mockup when the user requests
  styling or layout beyond ordinary Markdown. Requires an enabled HTML preview
  adapter. Not for normal paragraphs, headings, lists or tables, interactive
  forms, executable web apps, or HTML source the user wants to inspect.
---

# Static HTML/CSS previews

Use a fenced `html-preview` block for a complete, self-contained static layout.
Keep the surrounding explanation in Markdown. Native Markdown and math retain
their normal rendering; do not wrap the response in HTML just to style it.
Use OpenUI for supported interactive controls, rather than decorative HTML
buttons that cannot perform an action.

## Exact format and availability

- `html-preview` requests a preview. An ordinary `html` fence shows source code.
  Raw CommonMark HTML blocks can also preview when the adapter is enabled, but
  blank lines can terminate them. Prefer `html-preview` for styles, documents,
  or content containing blank lines. When combining styles with semantic
  containers, use explicit `<html>`, `<head>` and `<body>` sections so the HTML
  parser does not have to infer document boundaries.
- PicoMarkdownView needs the optional `PicoMarkdownViewHTML` product and explicit
  preview opt-in on macOS 27. Importing the product alone does not enable it.
  iOS keeps its existing source rendering; `html-preview` fences remain code.
  If previews are unavailable, supply useful Markdown instead of promising UI.
- The completed block is prepared when it closes; incomplete HTML is not a
  live page. A selection through the preview copies the original source,
  including the fence. Sanitization changes presentation, not copied source.

## Supported content

- Use semantic HTML with modest scoped CSS: sections, articles, headings,
  paragraphs, lists, tables, flex/grid layout, borders, or gradients.
- Use normal document flow and responsive widths. Avoid viewport-fixed or
  sticky elements, absolute positioning, transforms, fixed-width overflow,
  and positioned pseudo-elements. Keep the preview short enough for a chat;
  oversized source or layouts beyond the adapter's bounds fall back to source.
- Inherit page text colors and system fonts where possible. Keep labels legible,
  structure content with headings, and communicate distinctions in text as
  well as color. Styles affect only the embedded preview.
- Do not include JavaScript, event handlers, forms, inputs, iframes, navigation,
  animation, external stylesheets, fonts, media, or network requests. This is a
  static preview, not an executable app. Links cannot navigate from it.
- Images are replaced by their alternative text. Use a normal Markdown image
  outside the preview for a real image. Embedded SVG and MathML are removed;
  use their supported native formats outside the HTML block.
- Do not invent file downloads, action handlers, or new preview fence names.
  Leave real actions and file resolution to the app.

## Example

For a requested two-panel storage layout mockup, use a responsive static preview.
The labels communicate the distinction without requiring color or interaction.

```html-preview
<html>
<head>
<style>
  .storage-options {
    display: flex;
    flex-wrap: wrap;
    gap: 12px;
  }
  .storage-options article {
    flex: 1 1 140px;
    min-width: 0;
    box-sizing: border-box;
    border: 1px solid currentColor;
    border-radius: 12px;
    padding: 12px;
  }
  .storage-options h3 { margin: 0 0 8px; }
  .storage-options p { margin: 0; }
</style>
</head>
<body>
<section class="storage-options" aria-label="Storage options">
  <article>
    <h3>Local files</h3>
    <p>Available on this device, including while offline.</p>
  </article>
  <article>
    <h3>Shared folder</h3>
    <p>Available to collaborators through the app's sharing service.</p>
  </article>
</section>
</body>
</html>
```
