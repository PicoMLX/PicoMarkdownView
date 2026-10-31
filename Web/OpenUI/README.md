# Bundled OpenUI web runtime

This directory builds the official OpenUI React Renderer, full openuiLibrary and stock ThemeProvider into the macOS-only PicoOpenUIRuntime resource target. Native Markdown remains in PicoMarkdownView's TextKit 2 document; the web runtime renders only the body of a completed OpenUI payload.

## Rebuild

The generated resources are committed so package consumers do not need Node or npm at build time or runtime. The build/test toolchain accepts Node versions in the locked jsdom engine range: `^22.22.2 || ^24.15.0 || >=26.0.0`.

```sh
OPENUI_TELEMETRY_DISABLED=1 DO_NOT_TRACK=1 npm ci --ignore-scripts --no-fund --no-audit
npm run build
npm test
```

Run these commands from Web/OpenUI. Exact direct dependency versions and the transitive resolution are stored in package.json and package-lock.json. Installation scripts are disabled, including upstream installation telemetry. esbuild bundles a classic IIFE script, the official KaTeX CSS used by OpenUI TextContent, and its fonts under fonts/. No CDN or remote font is required. Rebuilding replaces generated font files and records them in BuildInfo.json; the KaTeX package notice is included with the other third party notices.

Output is Sources/PicoOpenUIRuntime/Resources/OpenUI. The package copies that directory without flattening it. Preserve index.html, app.js, app.css, the linked legal-comments file and generated notices when rebuilding or redistributing resources. Versions.json and BuildInfo.json record dependency versions and asset sizes without timestamps or local paths.

Tests and their source fixtures are development files under tests/. They are excluded from the resource directory. The DOM harness supplies synthetic layout and canvas text measurements; real WebKit rendering, sizing and native selection require the macOS integration checks.

## Native bridge

The local page creates one React root. Native code calls window.picoOpenUI.render with structured arguments:

```js
window.picoOpenUI.render({
  source: "root = Stack([...])",
  sourceID: "one-document-payload-identity",
  colorScheme: "light", // or dark
  isStreaming: false
});
```

The Renderer key depends only on sourceID. Appearance updates with the same source identity retain component/form state; a new identity gets a fresh renderer. Repeated identical requests do not rerender. The initial API supports completed payloads; the presence of the upstream isStreaming parameter does not promise progressive OpenUI rendering.

Messages use window.webkit.messageHandlers.picoOpenUI.postMessage:

```js
{ kind: "ready", payload: { versions: { /* pinned packages */ } }, sourceID: null }
{ kind: "size", payload: { height: 480 }, sourceID: "..." }
{ kind: "action", payload: { /* original OpenUI ActionEvent */ }, sourceID: "..." }
{ kind: "error", payload: [{ source, code, message }], sourceID: "..." }
```

Native code validates the source identity before accepting asynchronous messages. ready means the bridge is installed; a later valid size report establishes measured content. Size reports are timer-coalesced and suppress unchanged heights. They do not depend on requestAnimationFrame, which WebKit may suspend for inactive content. Initial zero-width layout waits for a usable host width. Measurements include visible body portals used by stock controls such as DatePicker; opening, closing, repositioning and intrinsic reflow update the native frame. Negative-top placement in a short inline viewport temporarily reserves room for FloatingUI to reposition. Portal mutations and ResizeObserver reports are timer-coalesced, and unchanged heights are suppressed; document.scrollHeight is deliberately not used.

Input is limited to 100000 JavaScript string code units; reported heights must be finite and between 1 and 20000 points. The native host can apply its own viewport policy. Diagnostics are limited to 20 entries with bounded messages, deduplicated, and cleared with an empty array after valid rendering.

Field edits remain inside the official renderer. There is no native per-keystroke state stream, inspection API, test helper, fixture chooser or diagnostic UI in the production page. Explicit actions emit the upstream event unchanged, including scoped form values and model-provided context. Native code owns model requests, navigation and app actions. No tool provider, OpenUI Gateway or model SDK is configured in the page.

## Content policy

The shipped page uses a restrictive Content Security Policy. Scripts, styles and fonts are local; inline styles are permitted for the official theme and components. Network connections, iframes, objects and HTML form navigation are blocked. Images can use bundled local assets or data/blob URLs; remote model-provided image URLs are blocked. PicoMarkdownView's remoteImagesEnabled option does not currently flow into the web child, so this initial policy intentionally performs no remote image requests.

The native navigation delegate must continue to handle external navigation requests and semantic open_url actions. Generated source is interpreted as OpenUI Lang data, never evaluated as JavaScript. The source copied by the surrounding document remains separate from mutable web form state.

The presentation is stock OpenUI CSS with its light/dark ThemeProvider. It does not become native AppKit/SwiftUI controls or Liquid Glass merely because WKWebView hosts it.

## Upstream versions and notices

- @openuidev/lang-core and @openuidev/react-lang: 1.0.2
- @openuidev/react-ui and @openuidev/react-headless: 0.18.1
- React and React DOM: 18.3.1
- Zustand: 4.5.7
- Zod: 4.6.7
- KaTeX: 0.16.47 (the same locked version used by the official TextContent renderer)

[OpenUI source and MIT license](https://github.com/thesysdev/openui). THIRD_PARTY_NOTICES.txt includes bundled package metadata and available license files, with the upstream OpenUI MIT notice when its package omits a separate license file. app.js.LEGAL.txt preserves bundled source license comments.
