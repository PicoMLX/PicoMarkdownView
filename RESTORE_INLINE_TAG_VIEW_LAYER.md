# Inline-Tag View Layer: Implementation And Verification

The restoration work is implemented and compiled. The original recovery plan's
"no Swift toolchain" and "compile-unverified" warnings are obsolete. This file
records the current API and evidence; see `VALIDATION.md` for the stack's checks.

## Current API

| API | Behavior |
| --- | --- |
| `tagPrefixes:` initializer argument | Defaults to mentions and hashtags; opt into tickers or paired tags. Fixed per view identity. |
| `.onTagTap { reference in ... }` | Receives `TagReference` with the prefix and identifier. |
| `.onOpenLink { url in ... }` | Receives ordinary links through SwiftUI `openURL`; also receives tag URLs when no tag handler is installed. |
| `.onTagHover { reference, rect in ... }` | macOS tag enter/exit, with a glyph rectangle in native text-view coordinates. |
| `.onLinkHover { url, rect in ... }` | macOS ordinary-link enter/exit, using the same coordinate space. |
| `.onContentSize { size in ... }` | Reports measured size changes, including streaming growth and font scaling. |
| `.markdownTextScale(_:)` | Live font/math scaling in addition to Dynamic Type; preserves the stream and selection. |

Hover callbacks are no-ops on iOS. Exit is `(nil, nil)`. Rectangles are not
SwiftUI `Anchor<CGRect>` values or screen coordinates; hosts must convert them
when anchoring UI in a different coordinate space. No tap-anchor overload is
implemented.

## Routing

Tags are ordinary attributed-string links carrying `pico-tag://` URLs. The
view decodes those URLs for `onTagTap`; otherwise it forwards them to `openURL`.
UIKit uses `textView(_:primaryActionFor:defaultAction:)` and invokes host
callbacks only when the returned action is performed. AppKit uses
`clicked(onLink:at:)`. Neither path enables text editing.

## Verified

- [x] Package tests and example builds on macOS and iOS.
- [x] UIKit primary actions forward the URL and visible text on invocation.
- [x] Default UIKit actions remain available when no handler is installed.
- [x] Native macOS link/tag clicks reach the installed handlers.
- [x] Native macOS hover bounds match layout-manager glyph bounds in view coordinates.
- [x] Repeated moves within one link are deduplicated; exit clears the hover.
- [x] Native selection spans multiple rendered blocks.
- [x] Hosted iOS Dynamic Type updates the existing text view and preserves selection across paragraphs.

The macOS example app was also smoke-tested for tag callbacks, full-document
select-all, cross-block drag selection, and table-math layout at 1x/2x zoom.

Coverage is in `TextItemLinkActionTests`, `ViewLinkHandlerTests`,
`PicoTagURLTests`, `TextKitInteractionTests`, `DynamicTypeIntegrationTests`, and
`TextScalingTests`. Pointer-only hover and a consuming app's popover placement
remain manual checks, not claims made by these automated tests.
