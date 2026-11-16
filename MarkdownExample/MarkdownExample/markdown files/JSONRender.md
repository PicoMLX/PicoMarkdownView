# Project review

The prototype is ready for a design review. Turn on **Show project notes** to see what changed, or choose **Send review request** to see the sample action in the status panel.

```json-render
{
  "root": "project",
  "elements": {
    "project": {
      "type": "Card",
      "props": { "title": "Prototype review", "description": "Final design pass" },
      "children": ["notes-toggle", "notes", "request"]
    },
    "notes-toggle": {
      "type": "Switch",
      "props": { "label": "Show project notes", "checked": { "$bindState": "/showNotes" } }
    },
    "notes": {
      "type": "Text",
      "props": { "text": "The revised layout has a shorter onboarding flow." },
      "visible": { "$state": "/showNotes", "eq": true }
    },
    "request": {
      "type": "Button",
      "props": { "label": "Send review request", "variant": "primary" },
      "on": { "press": { "action": "sendMessage", "params": { "message": "Review requested for the prototype." } } }
    }
  },
  "state": { "showNotes": false }
}
```

The next step is to collect feedback and update the prototype. Select across the card and this paragraph to copy the fenced JSON with the surrounding text.

## Asset review

```json-render
{
  "root": "review",
  "elements": {
    "review": { "type": "Card", "props": { "title": "Image checks", "icon": "photo" }, "children": ["grid"] },
    "grid": { "type": "Grid", "props": { "columns": 2, "gap": "md" }, "children": ["preview", "summary"] },
    "preview": {
      "type": "Image",
      "props": { "src": "example-image:///basn2c08.png", "alt": "PngSuite RGB test pattern", "height": 136 }
    },
    "summary": { "type": "Stack", "props": { "gap": "sm" }, "children": ["status", "progress"] },
    "status": { "type": "Badge", "props": { "text": "Decoded", "variant": "success" } },
    "progress": { "type": "Progress", "props": { "label": "Asset checks", "value": 3, "max": 4 } }
  }
}
```

## Source fallback

This spec names a component outside Vercel's native catalog, so Pico displays the original code.

```json-render
{
  "root": "unknown",
  "elements": {
    "unknown": { "type": "UnknownComponent", "props": {} }
  }
}
```
