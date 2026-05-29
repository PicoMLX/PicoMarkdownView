# Workflow: Restore the Inline-Tag View Layer (PR #2 follow-up)

> Status: the tokenizer/parser layer (`@`, `#`, `[[…]]`, tickers, all edge
> cases and streaming guarantees) is **merged and intact**. The host-facing
> **view layer** described as the "follow-up PR" in PR #2 was never committed
> to git (verified absent across every branch, all 3 PR head/merge refs, the
> `0.1` tag, the reflog, and all dangling objects). This document is the
> recovery plan to rebuild it.

## Why this is a document and not (yet) a finished PR

The package's view layer is `UIViewRepresentable`/`NSViewRepresentable` +
TextKit code. The agent execution environment has **no Swift toolchain**, so
this code cannot be compiled or `swift test`'d here — the same reason PR #2
was deliberately split ("no Swift toolchain is available in the agent's
execution environment to compile-check view-layer code blind"). Author/verify
the steps below in Xcode on macOS.

## Target API (from PR #2's documented follow-up)

Add these host-facing modifiers + config to `PicoMarkdownView`:

| API | Purpose |
|---|---|
| `onContentSize { (CGSize) in … }` | Fires when rendered content size changes (e.g. a newline grows height). *This is the "onChangeFrame when a newline is added" callback.* |
| `onTagTap { (Tag, Anchor<CGRect>?) in … }` | Typed tap callback for `@`/`#`/`[[…]]` tags (decoded `Tag`, not a raw URL). |
| `onTagHover { (Tag?, Anchor<CGRect>?) in … }` | macOS hover enter/exit for tags (anchor for popovers). |
| `onLinkHover { (URL?, Anchor<CGRect>?) in … }` | macOS hover for ordinary links. |
| `.tagPrefixes([TagPrefix])` (or init param) | Configure which prefixes the view's tokenizer recognises (defaults `@`, `#`). |
| `onOpenLink` (existing) + Anchor overload | Keep URL-only overload; add an overload that also yields an `Anchor`. |

## Verified integration map (cross-checked against the real source)

These are the load-bearing facts the rebuild hangs on — all confirmed from
clean reads this session:

1. **Tags already become links.** `InlineParser.makePicoTagURL` emits
   `pico-tag:///<prefix>/<identifier>` (percent-encoded, alphanumerics-only)
   and tag runs carry `InlineStyle.tag` + `.link` + `linkURL` + a `Tag`
   payload. `MarkdownAttributeBuilder` (≈ line 893) already turns any `.link`
   run into a hit-testable `.link` attribute. **So tag taps already flow
   through the existing link path** — `onTagTap` is a typed decode of the
   `pico-tag://` URL, not new hit-testing.

2. **Tap routing exists in the controller.** `TextKitStreamingController` has a
   `LinkHandling` protocol (`var linkTapHandler: ((URL) -> Void)?`), a
   `setLinkHandler(_:on:)`, and the UIKit views are `UITextViewDelegate`s whose
   `textView(_:shouldInteractWith:in:interaction:)` calls
   `linkTapHandler?(URL); return false`.
   **VERIFY:** whether `setLinkHandler` is actually called from the
   `UIViewRepresentable`/`NSViewRepresentable` and bridged to
   `@Environment(\.openURL)`. The current `PicoMarkdownView.body` did not
   appear to read `\.openURL` or call `setLinkHandler`, so the tap→`onOpenLink`
   bridge may itself be incomplete. Confirm in Xcode; if missing, wiring it is
   step 0.
   **VERIFY:** the AppKit (`NSTextView`) side of link clicking — likely needs
   `clicked(onLink:at:)` override or `NSTextViewDelegate
   textView(_:clickedOnLink:at:)`.

3. **Content-size callback = clone of the mermaid-width observer.** The pattern
   to mirror, already present on all four view subclasses
   (`StreamingTextKit1View`/`StreamingTextKit2View` × UIKit/AppKit):
   - stored closure `var onMermaidContentWidthChanged: ((CGFloat?) -> Void)?`
   - recomputed in `layoutSubviews()` (UIKit) / `layout()` (AppKit), fired only
     when the value changes
   - installed via `installMermaidWidthObserver(on:_:)`
   - surfaced to SwiftUI via the representable's `onMeasuredContentWidth`
     closure → `viewModel.updateMermaidContentWidth`.

   `intrinsicContentSize` already computes the content **height** from
   `layoutManager.usedRect(for:)`. Add a parallel `onContentSizeChanged:
   ((CGSize) -> Void)?` observer using `usedRect.size` (or
   `intrinsicContentSize`), fired from the same `layout`/`layoutSubviews` hook.

4. **`tagPrefixes` threading path** (pure plumbing, lowest risk):
   `PicoMarkdownView.init(... tagPrefixes:)`
   → `MarkdownStreamingViewModel.init(... tagPrefixes:)`
   → `MarkdownStreamingPipeline.init(... tagPrefixes:)`
   → `MarkdownTokenizer(tagPrefixes:)` (currently `MarkdownTokenizer()` at
   pipeline init line ≈ 11). `TagPrefix` already exposes
   `.mention/.hashtag/.ticker/.paired(open:close:)/.defaults`.

## Progress

- [x] **Phase 1 — `tagPrefixes` config** — commit `a3b7292`. Threaded through
      all three `PicoMarkdownView` inits → `MarkdownStreamingViewModel` →
      `MarkdownStreamingPipeline` → `MarkdownTokenizer(tagPrefixes:)`.
- [x] **Phase 2 — `onContentSize` callback** — commit `8d44cf9`. The
      "callback when a newline is added". `.onContentSize { (CGSize) in }`
      modifier, mirroring the mermaid width-observer on all four text-view
      subclasses. *Compile-unverified (no toolchain here).*
- [ ] **Phase 0 — link bridge** (prerequisite for taps; net-new, no existing
      code to mirror).
- [ ] **Phase 3 — `onTagTap`**.
- [ ] **Phase 4 — `onTagHover` / `onLinkHover`** (macOS).
- [ ] **Phase 5 — `onOpenLink` Anchor overload + docs**.

> ⚠️ Phases 0/3/4 are the **highest-risk** part: the tap-routing
> infrastructure does **not currently exist** (`setLinkHandler` has zero
> callers, no `UITextViewDelegate`/`NSTextViewDelegate`, no `NSTrackingArea`),
> so there is no existing pattern to mirror and nothing can be compiled in this
> environment. Best authored in Xcode on macOS.

## Phased plan (do in order; commit per phase)

**Phase 0 — confirm the link bridge (VERIFY in Xcode).**
Tap a normal `[x](https://…)` link in the example app with `.onOpenLink`. If it
does not fire, wire the representable: read `@Environment(\.openURL)` and call
`controller.setLinkHandler({ openURL($0) }, on: textView)` in
`updateUIView`/`updateNSView`. This must work before tags can.

**Phase 1 — `tagPrefixes` config (low risk, pure Swift).**
Thread the param through the 4 types above. Default `.defaults`. Add the
init-param form first; a `.tagPrefixes(_:)` modifier can wrap it later.

**Phase 2 — `onContentSize` callback (low risk, mirrors mermaid).**
Add `onContentSizeChanged` observer to the 4 view subclasses + an
`installContentSizeObserver(on:_:)` on the controller + an `onContentSize`
closure on the representable, surfaced as a `.onContentSize { size in }` View
modifier. Fire from the existing `layout`/`layoutSubviews` hook, de-duped.

**Phase 3 — `onTagTap` (medium risk).**
In the link handler path, decode `pico-tag:///prefix/identifier` URLs back into
`Tag` (reverse of `makePicoTagURL`). If the URL scheme is `pico-tag`, route to
`onTagTap(tag, anchor)`; otherwise route to `onOpenLink`. Provide an
`Anchor<CGRect>` from the tapped glyph rect
(`layoutManager.boundingRect(forGlyphRange:in:)`) for popover anchoring.

**Phase 4 — `onTagHover` / `onLinkHover` (higher risk, macOS only).**
Add `NSTrackingArea` (mouseMoved) on the AppKit views; hit-test the character
under the cursor, read its `.link` attribute, decode tag-vs-URL, fire the
hover closure with the glyph rect anchor. iOS: no hover (taps only) — make the
modifiers no-ops on iOS or gate with `#if os(macOS)`.

**Phase 5 — `onOpenLink` Anchor overload + docs.**
Add an overload of `onOpenLink` that also yields an `Anchor<CGRect>`, keeping
the existing URL-only overload for source compatibility. Update README.

## Test plan (macOS / Xcode)

- `swift test` — parser goldens still green (no regressions from `tagPrefixes`).
- Example app: tap `@mention` / `#hashtag` / `[[wiki]]` → `onTagTap` fires with
  correct decoded `Tag`; tap `[x](url)` → `onOpenLink` fires.
- Stream content that adds a newline → `onContentSize` fires with growing height.
- macOS: hover a tag/link → `onTagHover`/`onLinkHover` fires with a sensible rect.
- `.tagPrefixes([.mention, .hashtag, .ticker])` enables `$TICKER`; default set
  leaves `$x$` math intact.

## Decode helper (reverse of makePicoTagURL)

```swift
// pico-tag:///<pct-prefix>/<pct-identifier>  ->  (prefix, identifier)
func decodePicoTag(_ url: URL) -> (prefix: String, identifier: String)? {
    guard url.scheme == "pico-tag" else { return nil }
    // path is "/<prefix>/<identifier>"; components drop the leading "/"
    let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count == 2 else { return nil }
    let prefix = parts[0].removingPercentEncoding ?? String(parts[0])
    let identifier = parts[1].removingPercentEncoding ?? String(parts[1])
    return (prefix, identifier)
}
```
