# Markdown

A compact selection from CommonMark 0.31.2 and the cmark-gfm extension tests. Explore text formatting here; dedicated examples cover code, math, and rich content.

## Headings

# foo
## foo
### foo
#### foo
##### foo
###### foo

## Emphasis

*foo bar*

**foo bar**

*foo **bar** baz*

## Inline code

`` foo ` bar ``

## Lists

- a
  - b
  - c

- d
  - e
  - f

## Ordered lists

1. foo
2. bar
3) baz

## Blockquotes

> # Foo
> bar
> baz

>>> foo
> bar
>>baz

## Links

[link](#fragment)

[link](https://example.com#fragment)

[link](https://example.com?foo=3#frag)

## Horizontal rule

 - - -

## Tables

| abc | def |
| --- | --- |
| ghi | jkl |
| mno | pqr |

| aaa | bbb | ccc | ddd | eee |
| :--- | --- | :---: | --- | ---: |
| fff | ggg | hhh | iii | jjj |

## Strikethrough

A proper ~~strikethrough~~.

## Task lists

- [ ] foo
- [x] bar

## Footnotes

This is some text. It has a footnote[^a-footnote].

This footnote is referenced[^a-footnote] multiple times, in lots of different places.[^a-footnote]

[^a-footnote]: This footnote definition should have three backrefs.

## Sources

Selected examples by John MacFarlane ([CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/)) and Yuki Izumi and contributors ([cmark-gfm 0.29.0.gfm.13](https://github.com/github/cmark-gfm/blob/587a12bb54d95ac37241377e6ddc93ea0e45439b/test/extensions.txt)). Selection, section headings, and table/strikethrough syntax adaptations by PicoMarkdownView contributors. This example is licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
