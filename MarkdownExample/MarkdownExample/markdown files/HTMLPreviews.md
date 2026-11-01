# HTML previews

This paragraph is native Markdown. You can select from this text, through a preview, and into the paragraph after it. Copying that selection keeps the original HTML source. Choose Stream and Replay to watch this page arrive: HTML stays hidden while it arrives, with a small delayed loading placeholder until the closed preview is ready.

## A raw HTML card

<div>
  <h3>Weekend checklist</h3>
  <p>A small HTML card between two native Markdown paragraphs.</p>
  <ul>
    <li>Choose a walking route.</li>
    <li>Pack a water bottle.</li>
    <li>Leave room for a coffee stop.</li>
  </ul>
</div>

This is native Markdown again, with **bold text**, an [ordinary link](https://example.com), and inline math: $E = mc^2$.

## An explicit styled preview

The `html-preview` fence opts into a preview. Resize the window to watch the two cards reflow within the available text width.

```html-preview
<style>
  .trip-summary {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 12px;
    color: #203047;
    font-family: -apple-system, sans-serif;
  }
  .trip-summary article {
    padding: 20px;
    border: 1px solid #b8cbe2;
    border-radius: 16px;
    background: #edf4fc;
  }
  .trip-summary h3 { margin: 0 0 8px; font-size: 1em; }
  .trip-summary strong { font-size: 2em; }
  .trip-summary p { margin: 8px 0 0; }
  @media (prefers-color-scheme: dark) {
    .trip-summary { color: #e5efff; }
    .trip-summary article { background: #18283e; border-color: #405a7b; }
  }
</style>
<div class="trip-summary">
  <article>
    <h3>Walking time</h3>
    <strong>45 min</strong>
    <p>An easy route with a riverside stop.</p>
  </article>
  <article>
    <h3>Distance</h3>
    <strong>3.2 km</strong>
    <p>A short loop that finishes where it starts.</p>
  </article>
</div>
```

This paragraph stays in the native text view after the preview. The preview's CSS applies inside its own document.

## Ordinary HTML source stays code

A normal `html` fence still displays syntax-highlighted source:

```html
<article>
  <h3>This remains a code example.</h3>
  <p>Use html-preview only when you want a preview.</p>
</article>
```

## Watch a preview arrive

Choose Stream or Stream 10×, then Replay to watch this document arrive word by word. While the following fence is open, its source stays hidden. A compact loading card appears after a short delay, then becomes the preview once the fence closes and the layout is ready.

```html-preview
<aside style="padding: 18px; border-left: 4px solid #4b83c4;">
  <h3>The HTML block is complete</h3>
  <p>This preview appears in place, without replacing the surrounding Markdown.</p>
</aside>
```

The stream continues here as native Markdown. Selection and copying can cross both previews, and math keeps using the existing renderer.
