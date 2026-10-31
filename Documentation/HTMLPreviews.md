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

Open blocks retain their normal source presentation. The HTML view is created after the block or fence closes; an incomplete HTML document is not repeatedly loaded during streaming. Subsequent Markdown continues through the incremental pipeline. Resizing updates the embedded document's available width and height without replacing the surrounding text.

Each preview is one selection unit in the native text document. A selection spanning the preview copies its underlying source, including the fence for a fenced block. Sanitization affects presentation only; it does not rewrite copied source. The first version provides no preview toolbar. Documents that exceed the source/complexity limits keep their native source presentation. A load failure, excessive rendered height, or viewport-fixed layout shows source in the attachment instead of clipping the preview.

## Static content policy

The adapter uses WebKit only in the optional macOS product. It permits a bounded subset of semantic HTML and CSS, including simple cards, lists, tables, flex/grid layouts, and gradients. Author-provided scripts, event handlers, forms, embedded browsing contexts, navigation, and animations are disabled or removed. External resources are not loaded; images become their alternative text. Use text labels for information that would otherwise depend on an image or color alone.

The app uses its own isolated script to measure layout. That does not enable JavaScript supplied by the HTML block. CSS is scoped to the embedded document and does not style the Markdown around it.

Apps that link only `PicoMarkdownView` keep the existing HTML source rendering and gain no WebKit dependency from this feature. iOS retains its existing renderer; the optional preview adapter is macOS-only.

## Example app

Open `MarkdownExample/MarkdownExample.xcodeproj`, select the macOS destination, and choose **HTMLPreviews**. Only that sample opts in; the other example documents retain their existing behavior. The sample includes raw HTML, responsive styled previews, an ordinary `html` code fence, native paragraphs and math, and word-by-word streaming.

Try resizing the window, selecting across a preview, and copying into another editor. Compare the copied source with the Plain Text tab.
