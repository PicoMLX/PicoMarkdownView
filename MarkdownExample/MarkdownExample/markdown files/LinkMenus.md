# Link Context Menus

A file link and a web link can each provide a different context menu. The same destinations appear in several Markdown layouts below so you can try an isolated link, an inline link, a list, a quote, and a hosted table.

On macOS, right-click or Control-click a link. All file links on this page share one fictional destination; all web links share another. These are **mock menus**: selecting a menu item or clicking one of these links does nothing.

## Standalone file link

[Markdown export](file:///tmp/PicoMarkdownView-context-menu-demo.md)

The file menu offers Open file, Open in VS Code, Open with, Save as, Copy path, Copy file contents, and Reveal in Finder. Open the **Open with** submenu to inspect the application choices. The file does not need to exist for this mock example.

## Standalone web link

[PR #42](https://example.com/pico-link-menu-demo)

The web menu starts with an Open in heading and offers Code review, New tab, New window, Default browser, Copy link, and Save link as. It uses the same menu regardless of the link's display text.

## Links within a paragraph

A review response might say: the complete [Markdown export](file:///tmp/PicoMarkdownView-context-menu-demo.md) contains the analysis, while [the pull request](https://example.com/pico-link-menu-demo) contains the implementation. Right-click each link in this sentence and compare the menu. Right-clicking the ordinary text between them should use the text view's normal behavior.

This longer paragraph also makes the links part of a continuous selection. Select from the beginning of the previous paragraph through this one, then open the menu on a specific link. The menu should describe the link under the pointer even when the selection covers more than that link.

## A review checklist

- [ ] Read the [exported report](file:///tmp/PicoMarkdownView-context-menu-demo.md).
- [ ] Inspect [the proposed change](https://example.com/pico-link-menu-demo).
- [ ] Compare the menu on a **bold [file reference](file:///tmp/PicoMarkdownView-context-menu-demo.md)** with an *italic [web reference](https://example.com/pico-link-menu-demo)*.

### A quoted handoff

> The report is ready for review. Open the [Markdown file](file:///tmp/PicoMarkdownView-context-menu-demo.md) for the full write-up, or use [the review link](https://example.com/pico-link-menu-demo) for the change.
>
> Both links are part of this quote, but their menus still depend on the destination type.

## Links in a table

| Review material | File reference | Web reference |
| --- | --- | --- |
| Analysis | [Export](file:///tmp/PicoMarkdownView-context-menu-demo.md) | [Review](https://example.com/pico-link-menu-demo) |
| Follow-up | [Notes](file:///tmp/PicoMarkdownView-context-menu-demo.md) | [Discussion](https://example.com/pico-link-menu-demo) |

These table cells use the same two mock menus as the standalone links. Try both rows and resize the window to change their available width.

## Things to compare

1. Open the file and web menus from more than one layout.
2. Explore the file menu's submenu using the pointer or keyboard arrows.
3. Dismiss a menu with Escape, then open the other link's menu.
4. Select text across links and table cells, checking that ordinary selection remains available.

The examples use native macOS menus. On iOS, the document still shows the links and layout examples, but these desktop mock context menus are not presented.
