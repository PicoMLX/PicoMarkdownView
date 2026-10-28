# Blockquotes

Quoted text keeps its bar, and blocks inside a quote keep their own styling.

## Quotes in list items

1. A step with a note:

   > Quoted inside the item, with its bar at the item's text column.
   > ### And a heading
2. A nested item holds one too:
   - Inner item
     > Quoted in the inner item,
     continued lazily on an unmarked line.

> A quote outside the list keeps its bar at the edge.

## Headings inside a quote

> ## A quoted heading
> Body text under the heading, with **bold** and a [link](https://example.com).
> ### A smaller one
> More text after it.

## Code inside a quote

> Here is some code:
> ```swift
> let answer = 42
>
> print(answer)
> ```
> And text after the code.

The `>` line inside the fence is a blank code line; it does not end the quote.

## Lists inside a quote

> Things to do:
> - [x] a finished task
> - [ ] an open one
>   - with a nested item
> 1. first
> 2. second
>
> Text after the list is a new quote paragraph.

## A table inside a quote

> | Column | Value |
> | --- | ---: |
> | **bold** | 1 |
> | plain | 22 |
> Text after the table.

## Footnotes inside a quote

> [^q]: A quoted footnote definition.
> [^r]: Another one.

## Rules and math

> Above the rule
> ---
> Below the rule
>
> $$
> E = mc^2
> $$
> And $$x^2$$ on its own line is display math too.

## Nested quotes

> Level one
>> ## Heading at level two
>> Text at level two
> Back at level one

> > A fence at level two:
> > ```
> > code
> > ```

## What ends a quote

> Quoted text
***
A rule without a marker ends the quote, and this paragraph is outside it.

> ```
> code without a closing fence
>
> A blank line ends the quote and the code.

```text
> Inside a code block, markers are just text.
```
