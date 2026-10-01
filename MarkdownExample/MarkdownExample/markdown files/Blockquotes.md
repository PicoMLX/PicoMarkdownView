# Blockquotes

Text before the quote.

> ## Quoted heading
> - **First item** with [a link](https://example.com).
> - Second item with $x^2$.
>   - Nested item
>
> ```swift
> let greeting = "Hello"
>
> print(greeting)
> ```
> After the code block.
>> ### Nested heading
>> 1. Ordered item
>> 2. Another item
> ## Back to the outer quote
> Final quoted paragraph.

Text after the quote, still part of the same selectable document.

> ## Review regressions
> - [x] Checked task
> - [ ] Unchecked task
>
> | Expression | Value |
> | --- | --- |
> | $x^2$ | $4$ |
> | $y^2$ | $9$ |
>
> $$
> x^2 + y^2 = 13
> $$
>
>   ```swift
>   let x = 1
>  one
> zero
>    three
>   ```

   > # Indented quote
   > Final quoted paragraph.

> ---

> $$x$$y

> > ```swift
> code outside the inner fence
> > ```

> # Line-boundary regressions
> $$x$$
> Paragraph after same-line math.
> * * *
> Paragraph after the rule.
>
> [^quoted]: Quoted footnote definition.
> [^second]: Separate footnote definition.
>     Indented continuation.
> Paragraph outside the definitions.
>
> - List parent
>   > Nested quote inside the list item.
> - Following list item

$$x$$y

> # Verbatim and list-child regressions
> ```text
> [ref]: /url
> ```
>
> - Code owner
>   ```swift
>   let answer = 42
>   ```
> - Table owner
>   | Expression | Value |
>   | --- | --- |
>   | $x^2$ | $4$ |
>
> # Indented code
>     one
>     two
