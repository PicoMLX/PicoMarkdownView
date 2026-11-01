# Tags & Mentions

PicoMarkdownView recognises lightweight inline tags so a host app can attach
custom interactions without forking the parser. Tap any tag below — the panel
above the text shows the last tag you tapped, and on macOS hovering a tag or
link updates the **hover** readout.

## Profile previews

Hover over @[Maya Chen](maya) or @[Pico Bot](pico-bot) to see a profile preview.
Click a mention to keep it open, or activate it with a keyboard or touch.
These are fictional demo profiles. Close or Escape dismisses the card.

## A project conversation

@[Maya Chen](maya) is reviewing the #navigation changes for [[Harbor Notes]].
The next step is to ask @[Pico Bot](pico-bot) for a summary of [[Release Checklist]].
These named mentions use stable identifiers even though their visible names contain spaces.

> @[Maya Chen](maya): The reading layout is ready. Please keep the #accessibility checks beside the design notes.
>
> @[Pico Bot](pico-bot): I can help summarize the open items. Start with [[Release Checklist]] and the #review topic.

### Owners and follow-up

| Work item | Owner | Topic |
| --- | --- | --- |
| Reading layout | @[Maya Chen](maya) | #navigation |
| Release summary | @[Pico Bot](pico-bot) | #review |
| Final checks | **@[Maya Chen](maya)** | #accessibility |

- [ ] Ask @[Maya Chen](maya) to review the #layout notes.
- [x] Link the discussion to [[Release Checklist]].
- [ ] Ask @[Pico Bot](pico-bot) for a short #summary.

Try the profiles in ordinary text, inside the quote, and in the table. Other tags below exercise the callback readout without opening a profile card.

## Mentions (`@`)

There are **two** mention forms.

### 1. Bare form — `@rawstring`

The identifier is the literal string after the `@`. Tapping @behlool or
@johndoe routes a `Tag` whose `identifier` is exactly `behlool` / `johndoe`
and whose `displayText` is `@behlool` / `@johndoe`.

Trailing punctuation is stripped, so @behlool! and @johndoe. still resolve to
`behlool` and `johndoe` (the `!` and `.` stay in the sentence). Adjacent
mentions without a separator — @beh@lool — emit one tag followed by plain
text, matching Slack/Discord/Twitter.

Non-ASCII leading characters don't suppress the opener, so 🎯@rocket and
张伟@wei still recognise the mention, while an email like john@example.com
is deliberately **not** treated as a tag.

### 2. Markdown-link form — `@[Display Name](id)`

This decouples the visible name from the lookup key — useful when the
identifier is an opaque ID and the name has spaces:

- @[John Doe](u-2345) renders as “@John Doe” but routes `identifier == "u-2345"`.
- @[Ada Lovelace](user_17) renders as “@Ada Lovelace”, `identifier == "user_17"`.

The display text can contain spaces and punctuation; the id in the parens is
what your handler receives for lookup.

## Hashtags (`#`)

Hashtags use the bare form: #swift, #SwiftUI, and #markdown each route a `Tag`
with prefix `#`. Use these for topic filters. A trailing strip applies here
too: #done! resolves to `done`.

## Wiki-links (`[[ ]]`) — opt-in paired delimiter

When the host enables the paired prefix, double brackets become tags:
[[Home Page]] and [[Getting Started]] route `identifier == "Home Page"` /
`"Getting Started"` with prefix `[[`. Paired delimiters are exempt from the
left-boundary rule, so glued text like see[[Home Page]] still matches.

## Tickers (`$`) — opt-in (collides with math)

`$` is **off by default** because it collides with TeX inline math
(`$x = mc^2$`). This document enables it, so $AAPL and $MSFT route as tickers.
Keep it disabled in documents that contain math.

## Tags vs. ordinary links

Ordinary Markdown links still work and route through `onOpenLink`, not the tag
handler: visit [the PicoMarkdownView repo](https://github.com/PicoMLX/PicoMarkdownView)
or an autolink like https://swift.org — these arrive as plain URLs.

## Tags inside other formatting

Tags are recognised inside **bold @[Jane Roe](u-9)**, *italic #emphasis*, and
list items:

- Assigned to @[John Doe](u-2345) for #triage
- Blocked on [[Release Checklist]]
- Watching $AAPL

> Blockquote with a mention @behlool and a #note.

That's every tag kind in one document.
