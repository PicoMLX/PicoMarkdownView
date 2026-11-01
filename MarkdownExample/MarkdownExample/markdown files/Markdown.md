# Markdown

## Harbor Notes: release review

**Release candidate:** `1.4.0-rc.2` · **Workspace:** Harbor Notes · **Status:** *Ready for team review*

Harbor Notes is a fictional notebook for a research team. This brief follows a document from planning through publication. Names, counts, and timings are illustrative material for exploring formatting, selection, and copying.

### What changed

The release brings **clearer document navigation**, *more predictable exports*, and a simpler review checklist. The team replaced ~~separate checklists in every notebook~~ with **one *shared* release record**. Existing notes keep their titles and links, so reviewers can compare the candidate with the previous release without rebuilding their workspace.

A document marked `ready-for-review` now has an owner and a written acceptance check. The pending work is described in words alongside its status. Read the [release plan](https://example.com/harbor/release-plan) before opening the candidate, and consult the [formatting guide](https://example.com/harbor/formatting) for unfamiliar markup.

#### Scope and ownership

Remaining items count unanswered review comments. Each owner still needs final approval, including areas with no open comments.

| Work area | Review state | Remaining items | Owner note |
| :--- | :---: | ---: | :--- |
| **Document navigation** | Ready | 0 | Keep the selected note visible after switching sections. |
| Export and sharing | In review | 2 | Compare the attachment names with the [release plan](https://example.com/harbor/release-plan). |
| Search results | Ready | 0 | Highlight the matching phrase without hiding its context. |
| *Keyboard access* | In review | 1 | Confirm that focus returns to the original control. |

### Prepare the candidate

1. Collect the review material.
    - Open the planning notebook and the previous release notes.
    - Include a short note, a long report, and a document with a table.
        1. Keep their original titles.
        2. Record any missing attachment alongside its source document.

2. Complete the review in a fresh workspace.

    First check whether the information is understandable at the default text size. Then try zoom, keyboard navigation, and copying a selection across several paragraphs.

    > A reviewer should be able to explain the result from the document alone. Add any missing context before approving it.

3. Publish the decision.
    - Summarize the outcome in one paragraph.
    - Assign each follow-up to an owner.
    - Keep the candidate available until those follow-ups are resolved.

#### Final checklist

- [x] The release record names an owner and a reviewer.
- [x] Each completed change links to its acceptance check.
    - [x] Navigation preserves the selected document.
    - [x] Search results retain the surrounding sentence.
- [ ] Review the exported archive on a second machine.
    - [ ] Confirm attachment names and folder structure.
    - [ ] Open the archive without the original workspace.
- [ ] Approve the final release note.

### Notes from the review

> **Reviewer observation**
>
> The overview is easier to scan when the decision appears before the activity log. Keep the supporting detail available, but give the next reader a clear starting point.
>
> - Put the release state near the title.
> - Explain the few items that still need a decision.
>
>> An unanswered question is useful when it has an owner and a next step. An unexplained status marker is much harder to act on.

### Sample verification record

These invented measurements describe a review workload.[^harbor-metrics] The wide final column places explanatory text beside narrow numeric columns.

| Scenario | Documents | Median review time | Observation |
| :--- | ---: | ---: | :--- |
| Short meeting notes | 12 | 2 min | Titles and decisions were visible without opening a second document. |
| Reports with tables | 8 | 6 min | Reviewers checked both the header labels and the meaning of each aligned value. |
| Mixed attachments | 5 | 9 min | One archive needed clearer filenames before it could be approved. |

---

### Publication note

**Recommended decision: approve after the archive check.** Resolve the remaining comments about filenames and keyboard focus in this record so the next reviewer can follow the outcome.

Preserve the review record alongside the [sample release archive](https://example.com/harbor/releases/1.4.0). The archive, plan, and guide links belong to the same document as `review.owner`, the tables, and these footnotes.[^harbor-selection]

[^harbor-metrics]: These fictional figures were composed for the example. They are not app benchmarks or user analytics.

[^harbor-selection]: Try selecting from the summary through a table, then copy the selection to inspect the result.

## Specification examples

These small cases come from CommonMark 0.31.2 and the cmark-gfm extension tests. Their original placeholder text is retained so the source cases remain recognizable; the release report above is an authored composition.

### Emphasis

*foo **bar** baz*

### Inline code

`` foo ` bar ``

### Nested lists

- a
  - b
  - c

- d
  - e
  - f

### Blockquotes

> foo
>
> bar

### Links

[link](#fragment)

[link](https://example.com#fragment)

[link](https://example.com?foo=3#frag)

### Thematic rule

 - - -

### Tables

| aaa | bbb | ccc | ddd | eee |
| :--- | --- | :---: | --- | ---: |
| fff | ggg | hhh | iii | jjj |

### Strikethrough

A proper ~~strikethrough~~.

### Task lists

- [ ] foo
- [x] bar

### Footnotes

This is some text. It has a footnote[^a-footnote].

This footnote is referenced[^a-footnote] multiple times, in lots of different places.[^a-footnote]

[^a-footnote]: This footnote definition should have three backrefs.

## Sources

Selected examples by John MacFarlane ([CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/)) and Yuki Izumi and contributors ([cmark-gfm 0.29.0.gfm.13](https://github.com/github/cmark-gfm/blob/587a12bb54d95ac37241377e6ddc93ea0e45439b/test/extensions.txt)). The fictional Harbor Notes report, selection, section headings, and table/strikethrough syntax adaptations are by PicoMarkdownView contributors. This example is licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
