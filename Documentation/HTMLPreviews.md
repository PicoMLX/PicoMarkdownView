# HTML previews on macOS

`PicoMarkdownViewHTML` is an optional product for displaying static HTML/CSS blocks inside the macOS 27 TextKit 2 document. Paragraphs, headings, lists, quotes, tables, code, and math continue to use their existing renderers. Importing the product alone does not enable previews.

## Enable previews

Add `PicoMarkdownViewHTML` to your macOS app target alongside `PicoMarkdownView`. In Xcode, select the additional product from the same package. For a package target shared with iOS, make the dependency conditional:

```swift
.target(
    name: "ChatUI",
    dependencies: [
        .product(name: "PicoMarkdownView", package: "PicoMarkdownView"),
        .product(name: "PicoMarkdownViewHTML", package: "PicoMarkdownView",
                 condition: .when(platforms: [.macOS]))
    ]
)
```

Opt in when constructing the view:

```swift
import SwiftUI
import PicoMarkdownView
#if os(macOS)
import PicoMarkdownViewHTML
#endif

struct MessageBody: View {
    let markdown: String

    var body: some View {
#if os(macOS)
        PicoMarkdownView(markdown, embeddedBlockRenderers: [.htmlPreview])
#else
        PicoMarkdownView(markdown)
#endif
    }
}
```

The same argument is available on the `chunks:` and `stream:` initializers. For an LLM response, continue supplying incremental chunks through the stream initializer:

```swift
PicoMarkdownView(stream: makeStream, embeddedBlockRenderers: [.htmlPreview])
```

As with theme and tokenizer configuration, choose the renderers when constructing the view. Change the view's identity if you need to reconfigure an existing instance.

## Which blocks become previews?

The built-in renderer recognizes two explicit selectors:

| Input | Opted-in macOS behavior |
| --- | --- |
| Raw CommonMark HTML block | Static HTML preview when the block closes |
| Fenced `html-preview` block | Static HTML/CSS preview when the fence closes |
| Fenced `html` block | Ordinary source code |
| Inline HTML within a Markdown paragraph | Existing inline behavior |
| Markdown or math block | Existing rendering |

Raw HTML keeps CommonMark's existing block boundaries. Many block tags end at a blank line; other forms have their own closing conditions. Keep a simple raw HTML fragment together without internal blank lines:

```html
<div>
  <h3>Summary</h3>
  <p>A complete static card.</p>
</div>
```

Use `html-preview` for a full layout, embedded styles, or HTML containing blank lines:

````markdown
A native Markdown paragraph before the preview.

```html-preview
<style>
  .summary { display: grid; gap: 12px; padding: 20px; }
  .summary h3 { margin: 0; }
</style>
<section class="summary">
  <h3>Summary</h3>
  <p>This is a static HTML preview.</p>
</section>
```

A native Markdown paragraph after the preview.
````

## Streaming, selection, and resizing

Once an opted-in raw HTML block or `html-preview` fence is recognized, its source is hidden behind one stable, compact attachment. A softly rounded loading card with a small native spinner and “Preparing preview…” appears after about 350 ms. The deadline starts once per block and continues through closure and first preview preparation; incoming chunks never restart it. A ready preview replaces the placeholder immediately, with no minimum display time. Paused or canceled open streams show a static status instead of an indefinitely spinning indicator. Reduce Motion uses a static status icon.

The factory still receives only the final, immutable source after the block or fence closes. HTML parsing and sanitization run once off the main actor when that closed block is first presented; no browser is created for incomplete prefixes. The prepared result is reused for appearance/font changes and after window detachment; only the lightweight document shell is restyled. Subsequent Markdown continues through the incremental pipeline. Resizing updates the embedded document's available width and height without replacing the surrounding text.

Each preview is one selection unit in the native text document. A selection spanning the preview copies its underlying source, including the fence for a fenced block. Sanitization affects presentation only; it does not rewrite copied source. The first version provides no preview toolbar. Empty or oversized source keeps its native source presentation. A preparation failure, load failure, excessive rendered height, or viewport-fixed layout shows source in the attachment instead of clipping the preview.

## Viewport lifetime

On macOS, a preview creates a browser page when its native attachment intersects the scroll viewport. Scrolling it offscreen releases the page and its WebKit view while retaining sanitized HTML and the last measured height. Returning to the attachment reuses those values and loads the page at its current width; it does not reparse Markdown or HTML. Nested scroll clipping and hidden or minimized windows are respected. A page containing keyboard or own-app accessibility focus remains mounted to preserve that focus.

An evicted preview uses its cached height as the minimum while the loading status replaces its browser page. A narrow column or larger status text can reserve more space so the loading card never overlaps following Markdown. Returning to it shows the preview as soon as the new page is ready, without flashing raw HTML or sanitized text. Its cached height keeps the surrounding layout stable. Width or font changes made offscreen are applied and remeasured when it becomes visible again. This implementation does not retain a bitmap snapshot of every preview.

Selection and copying remain owned by the surrounding TextKit document. An offscreen attachment still exports the original HTML or fenced Markdown, including content removed from the visual preview by sanitization.

## Static content policy

The adapter uses WebKit only in the optional macOS product. It permits a bounded subset of semantic HTML and CSS, including simple cards, lists, tables, flex/grid layouts, and gradients. Author-provided scripts, event handlers, forms, embedded browsing contexts, navigation, and animations are disabled or removed. External resources are not loaded; images become their alternative text. Use text labels for information that would otherwise depend on an image or color alone.

The app uses its own isolated script to measure layout. That does not enable JavaScript supplied by the HTML block. CSS is scoped to the embedded document and does not style the Markdown around it. Positioned or transformed `::before`/`::after` content, and generated content on the document root, use source fallback because their bounds cannot be measured reliably. Ordinary static in-flow generated content on the body and its descendants remains supported when it fits the viewport. Extra overflow inside a transformed body uses source fallback rather than an unscaled height estimate.

Apps that link only `PicoMarkdownView` keep the existing HTML source rendering and gain no WebKit dependency from this feature. iOS retains its existing renderer; the optional preview adapter is macOS-only.

## Example app

Open `MarkdownExample/MarkdownExample.xcodeproj`, select the macOS destination, and choose **HTMLPreviews**. Only that sample opts in; the other example documents retain their existing behavior. The sample includes raw HTML, responsive styled previews, an ordinary `html` code fence, native paragraphs and math, and word-by-word streaming.

Try resizing the window, selecting across a preview, and copying into another editor. Compare the copied source with the Plain Text tab.
