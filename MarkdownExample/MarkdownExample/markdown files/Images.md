# Images & SVG

Raster images and vector graphics share one selectable document. These samples are bundled with the app and work offline. On macOS, click a standalone image to open the image viewer, or hover over a vector graphic to reveal its zoom and copy controls. SVG fences remain readable source on iOS.

## Raster image formats

These original [PngSuite images](https://github.com/pnggroup/libpng/tree/49363adcfaf098748d7a4c8c624ad8c45a8c3a86/contrib/pngsuite) are deliberately small: each is 32 × 32 pixels. They exercise three ways to store PNG color.

### RGB color

Three 8-bit channels store the red, green and blue components of each pixel.

![PngSuite RGB color pattern](example-image:///basn2c08.png)

### Palette color

Pixels refer to entries in a color palette rather than storing an RGB value directly.

![PngSuite indexed color pattern](example-image:///basn3p08.png)

### Color with transparency

An alpha channel adds per-pixel transparency to the color channels.

![PngSuite RGBA transparency pattern](example-image:///basn6a08.png)

## CSS and a color gradient

The circles combine a CSS class for their outlines, a linear gradient, and overlapping translucent fills. The graphic fits the text width; zooming preserves the vector edges.

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

## Clipping, groups and reused shapes

The striped background is clipped to a circle. A single star path is reused three times with different translations, while a parent group supplies their shared fill and stroke.

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

## Images within text

An RGB image ![RGB color pattern](example-image:///basn2c08.png) can sit between words, including **bold text**, *emphasis* and a [regular link](https://www.libpng.org/pub/png/). The sentence continues after the attachment, so selecting and copying can span both text and image source.

Palette ![indexed color pattern](example-image:///basn3p08.png) and transparent ![RGBA transparency pattern](example-image:///basn6a08.png) images also work within the same paragraph.

## Images in lists and blockquotes

- ![RGB pattern within a list](example-image:///basn2c08.png)
  This image belongs to a list item, with a caption that wraps inside the list indentation.
- The next item continues as ordinary Markdown text.
- A compact inline sample ![palette pattern within a list](example-image:///basn3p08.png) stays within the surrounding sentence.

> ![Transparent pattern within a blockquote](example-image:///basn6a08.png)
>
> The image and this caption share the quote's indentation. Drag a selection from outside the quote through the image and back into the text.

## An SVG mask within a blockquote

The wave below uses a gradient mask to fade its fill. Its container is a native Markdown blockquote, so the graphic receives the width left after the quote indentation.

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
> The blockquote continues with selectable text beneath the graphic.

## Selection and source copying

Select from this paragraph back through the wave, images and captions. Copying a selection preserves the underlying Markdown image URLs and SVG fences. On macOS, try the graphic's Copy source control, then zoom in and press Escape to return to the document.

*Raster fixtures © Willem van Schaik, used with permission. Vector examples are PicoMarkdownView's own SVG demonstrations, reused from its SVG example.*
