---
name: openui-interfaces
description: Create small interactive cards and forms in OpenUI Lang for Pico clients with OpenUI enabled. Use when a choice, input or follow-up action helps the user; keep ordinary explanations in Markdown.
---

# Interactive OpenUI content

Use an `openui` fence for a self-contained interactive part of an answer, such
as a choice card or a short form. Keep surrounding prose, headings, lists,
tables and math in their usual Markdown/LaTeX formats. A static explanation
usually needs no OpenUI view.

## Pico's renderer contract

- The host must enable OpenUI. PicoMarkdownView supports it on macOS 27;
  iOS and clients without OpenUI show the original code. Include a short
  explanation outside the fence so the answer remains useful there.
- An open fence streams as code. The interactive view appears when the fence
  closes or the stream finishes; do not promise live rendering of a partial
  OpenUI program. Close the fence before continuing the answer.
- The body is OpenUI Lang data: named assignments and component calls, not
  JSX, HTML, JavaScript, ChatKit JSON or an MCP App. Define `root`, use unique
  names for other values, quote strings and pass component arguments in order.
- Use the bundled stock components. Do not invent component names, properties
  or actions. The small vocabulary below is sufficient for the examples.
- The app receives explicit actions and decides what to do. A button cannot
  make a model request, open a URL, run code or execute a tool by itself.
  Form edits stay local until an action includes their scoped values.
- Remote images, network requests, iframes and external assets are disabled.
  There is no tool provider for `Query`/`Mutation`/`@Run`. Do not use them,
  scripts, custom components or assumed API connections in a Pico fence.
- Copying the surrounding response exports the original fenced program;
  entered form values do not rewrite that source. Do not describe form state
  as saved unless the host actually saves it.

## Tested building blocks

| Component | Positional arguments |
| --- | --- |
| `Stack` | children, direction (`"column"` or `"row"`), gap (`"s"`, `"m"`, `"l"`) |
| `Card` | children |
| `CardHeader` | title, description |
| `TextContent` | Markdown text string |
| `Buttons` | buttons, direction (`"row"` or `"column"`) |
| `Button` | label, action, variant (`"primary"` or `"secondary"`) |
| `Form` | name, button group, fields |
| `FormControl` | label, input, description |
| `Input` | name, placeholder, type (`"text"` or `"email"`), validation object |

`@ToAssistant("message", {key: "value"})` emits a follow-up request with
optional structured context. `@OpenUrl("https://example.com")` emits an
open-URL request. Both require a host action handler; do not imply the action
has already happened. Use descriptive button labels and visible form labels.
Keep choices few and layouts narrow enough to read on a phone.

## Follow-up card

Explain which options are being compared in native Markdown, then offer a
specific next step:

```openui
root = Card([heading, explanation, Buttons([compare], "row")])
heading = CardHeader("Compare options", "Choose what to explore next")
explanation = TextContent("Continue with a cost comparison of the options above.")
compare = Button("Compare costs", @ToAssistant("Compare the costs of these options", {topic: "costs"}), "primary")
```

## Scoped form

Explain that submitting sends the entered destination to the app. Keep field
names stable and use a distinct form name; the action includes that form's
values as `formState` together with `params.context`.

```openui
root = Card([CardHeader("Plan a trip", "Choose a starting point"), trip])
trip = Form("trip", Buttons([submit], "row"), [destination])
destination = FormControl("Destination", Input("destination", "City or region", "text", {required: true}), "Where would you like to go?")
submit = Button("Plan trip", @ToAssistant("Plan a trip using these details", {task: "trip-planning"}), "primary")
```
