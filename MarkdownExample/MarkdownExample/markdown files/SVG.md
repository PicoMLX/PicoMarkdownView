# SVG graphics

This page opts into native SVG rendering on macOS. Raw SVG stays hidden while it streams; a subtle loading card appears after 350 ms if the fence is still open. Each completed graphic replaces that card when its fenced source finishes streaming. Pausing or canceling stops the spinner without completing the parser's open SVG. The paragraphs around it remain selectable Markdown text, and copying a loading card includes the SVG source received so far. On iOS, these SVG fences remain code.

## CSS and a color gradient

This transparent graphic uses a CSS class for its outline and an SVG gradient for its fill. Hover over it or move keyboard focus into it to reveal the zoom and copy buttons. Zoom in, pan, then press Escape to return to the text.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 200">
  <title>Three overlapping circles</title>
  <desc>Three circles overlap from left to right, with a violet-to-cyan gradient through the middle circle.</desc>
  <style>.outline { stroke: #64748b; stroke-width: 2; }</style>
  <defs>
    <linearGradient id="color" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#8b5cf6"/>
      <stop offset="1" stop-color="#06b6d4"/>
    </linearGradient>
  </defs>
  <circle class="outline" cx="160" cy="100" r="75" fill="#8b5cf6" opacity="0.7"/>
  <circle class="outline" cx="240" cy="100" r="75" fill="url(#color)"/>
  <circle class="outline" cx="320" cy="100" r="75" fill="#06b6d4" opacity="0.7"/>
</svg>
```

Select from this sentence back through the graphic. Copying the selection includes the underlying SVG in a code fence, rather than an attachment placeholder or screenshot.

## Clipping and internal references

The three stars below reuse a single shape. A circular clip cuts off the stripes behind them. Everything stays inside the existing graphic frame when zoomed.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 200">
  <title>Three stars over a striped circle</title>
  <defs>
    <clipPath id="circle"><circle cx="240" cy="100" r="88"/></clipPath>
    <path id="star" d="M0,-24 L7,-7 L25,-7 L11,5 L16,23 L0,12 L-16,23 L-11,5 L-25,-7 L-7,-7 Z"/>
  </defs>
  <g clip-path="url(#circle)">
    <rect x="130" y="12" width="220" height="176" fill="#38bdf8"/>
    <path d="M130,40 H350 M130,80 H350 M130,120 H350 M130,160 H350" stroke="#4f46e5" stroke-width="20"/>
  </g>
  <g fill="#fbbf24" stroke="#92400e" stroke-width="2">
    <use href="#star" transform="translate(175 100)"/>
    <use href="#star" transform="translate(240 100)"/>
    <use href="#star" transform="translate(305 100)"/>
  </g>
</svg>
```

## A gradient mask inside a quote

> This graphic belongs to a blockquote. Its viewport receives the width left after the native quote indentation.
>
> ```svg
> <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 160">
>   <title>A cyan wave fading to transparency</title>
>   <defs>
>     <linearGradient id="fade"><stop stop-color="white"/><stop offset="1" stop-color="black"/></linearGradient>
>     <mask id="mask"><rect width="480" height="160" fill="url(#fade)"/></mask>
>   </defs>
>   <path d="M0,80 Q60,0 120,80 T240,80 T360,80 T480,80 L480,160 H0 Z" fill="#06b6d4" mask="url(#mask)"/>
> </svg>
> ```
>
> This is still native blockquote text below the graphic.

## A graphic as the first child of a list item

- ```svg
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 120">
    <title>A checkmark in a circle</title>
    <circle cx="160" cy="60" r="48" fill="#22c55e"/>
    <path d="M136,61 L153,78 L185,43" fill="none" stroke="white" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/>
  </svg>
  ```
- The list continues as native Markdown after the graphic.

## Unsupported content stays readable

This example deliberately uses a blur filter that the native SVG presentation does not support. It remains a code block so the source is visible and copyable.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 120">
  <defs><filter id="blur"><feGaussianBlur stdDeviation="4"/></filter></defs>
  <circle cx="120" cy="60" r="40" fill="#8b5cf6" filter="url(#blur)"/>
</svg>
```

The document continues normally after an unsupported SVG. Existing Mermaid diagrams, ordinary code and math keep their own rendering paths.
