import Foundation
import Testing
@testable import PicoMarkdownView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// List items from the seventh conformance batch: items hold blocks, stay
/// open across blank lines, and are kept by indentation to their content
/// column. The conformance suite proves the single-shot text; these prove
/// that streaming gives the same result at every chunk split. Expected
/// shapes are cmark-gfm's, in the conformance suite's notation.
@Suite
struct SpecListsTests {
    static let cases: [(markdown: String, shape: String)] = [
        // Blocks after a blank line, indented to the content column.
        ("- one\n\n  two\n\n", #"[ul[[p("one"), p("two")]]]"#),
        (" -    one\n\n      two\n\n", #"[ul[[p("one"), p("two")]]]"#),
        ("- foo\n\n\n  bar\n\n", #"[ul[[p("foo"), p("bar")]]]"#),
        ("1.  foo\n\n    ```\n    bar\n    ```\n\n    baz\n\n", #"[ol[[p("foo"), code(-, "bar"), p("baz")]]]"#),
        ("- Foo\n\n      bar\n\n\n      baz\n\n", #"[ul[[p("Foo"), code(-, "bar\n\n\nbaz")]]]"#),
        ("1.     indented code\n\n   paragraph\n\n       more code\n\n",
         #"[ol[[code(-, "indented code"), p("paragraph"), code(-, "more code")]]]"#),
        ("1. a\n\n   ```\n   x\n\n   ```\n2. b\n\n", #"[ol[[p("a"), code(-, "x\n")], [p("b")]]]"#),
        ("- [ ] task\n\n  more\n\n", #"[ul[[p("task"), p("more")]]]"#),
        // Blank lines in code lose the item's indentation too.
        ("- ```python\n  value = \"\"\"a\n  \n  b\"\"\"\n  ```\n\n", #"[ul[[code(-, "value = \"\"\"a\n\nb\"\"\"")]]]"#),
        ("- a\n\n      x\n        \n      y\n\n", #"[ul[[p("a"), code(-, "x\n  \ny")]]]"#),
        // A table in an item ends at the start of another block (GFM); a
        // plain line is a row. Tables show as `other` here.
        ("- a\n\n  | x |\n  | --- |\n  # heading\n\n", #"[ul[[p("a"), other, h1("heading")]]]"#),
        ("- a\n\n  | x |\n  | --- |\n  ```\n  y\n  ```\n\n", #"[ul[[p("a"), other, code(-, "y")]]]"#),
        ("- a\n\n  | x |\n  | --- |\n  - b\n\n", #"[ul[[p("a"), other, ul[[p("b")]]]]]"#),
        ("- a\n\n  | x |\n  | --- |\n  y\n\n", #"[ul[[p("a"), other]]]"#),
        // A definition the item does not keep ends it.
        ("- a\n\n[ref]: /url\n  text\n\n", #"[ul[[p("a")]], p("text")]"#),
        ("- a\n\n  [ref]: /url\n  text\n\n", #"[ul[[p("a"), p("text")]]]"#),
        // Less indented, a line ends the item, unless it continues a
        // paragraph lazily.
        ("- a\n\n- b\n\nafter\n\n", #"[ul[[p("a")], [p("b")]], p("after")]"#),
        ("- a\n  b\nc\n\n", #"[ul[[p("a b c")]]]"#),
        ("- a\n\n  b\nc\n\n", #"[ul[[p("a"), p("b c")]]]"#),
        ("- a\n - b\n  - c\n   - d\n    - e\n\n", #"[ul[[p("a")], [p("b")], [p("c")], [p("d - e")]]]"#),
        // Empty items.
        ("-\n  foo\n-\n  ```\n  bar\n  ```\n-\n      baz\n\n", #"[ul[[p("foo")], [code(-, "bar")], [code(-, "baz")]]]"#),
        ("-\n\n  foo\n\n", #"[ul[[]], p("foo")]"#),
        ("- foo\n-\n- bar\n\n", #"[ul[[p("foo")], [], [p("bar")]]]"#),
        ("*\n\n", "[ul[[]]]"),
        // Nesting by content column, markers and delimiters.
        ("- foo\n - bar\n  - baz\n   - boo\n\n", #"[ul[[p("foo")], [p("bar")], [p("baz")], [p("boo")]]]"#),
        ("10) foo\n    - bar\n\n", #"[ol[[p("foo"), ul[[p("bar")]]]]]"#),
        ("10) foo\n   - bar\n\n", #"[ol[[p("foo")]], ul[[p("bar")]]]"#),
        ("- - foo\n\n", #"[ul[[ul[[p("foo")]]]]]"#),
        ("1. - 2. foo\n\n", #"[ol[[ul[[ol[[p("foo")]]]]]]]"#),
        ("- # Foo\n- Bar\n\n", #"[ul[[h1("Foo")], [p("Bar")]]]"#),
        // A tab after a nested marker counts from the line's start.
        ("- -\tfoo\n\n", #"[ul[[ul[[p("foo")]]]]]"#),
        ("1. -\tfoo\n\n", #"[ol[[ul[[p("foo")]]]]]"#),
        ("- a\n  - b\n\n    c\n- d\n\n", #"[ul[[p("a"), ul[[p("b"), p("c")]]], [p("d")]]]"#),
        ("* foo\n  * bar\n\n  baz\n\n", #"[ul[[p("foo"), ul[[p("bar")]], p("baz")]]]"#),
        ("- a\n- ```\n  b\n\n\n  ```\n- c\n\n", #"[ul[[p("a")], [code(-, "b\n\n")], [p("c")]]]"#),
        ("1234567890. not ok\n\n", #"[p("1234567890. not ok")]"#),
        // Tabs count to the next multiple of four columns.
        ("- a\n\t- b\n\n", #"[ul[[p("a"), ul[[p("b")]]]]]"#),
        ("- foo\n\n\tbar\n\n", #"[ul[[p("foo"), p("bar")]]]"#),
        // A tab in an item's content counts from the line's start too.
        ("- a\n\n  \tfoo\n\n", #"[ul[[p("a"), p("foo")]]]"#),
        ("- a\n\n  \t  foo\n\n", #"[ul[[p("a"), code(-, "foo")]]]"#),
        ("- a\n\n      x\n  \ty\n\n", #"[ul[[p("a"), code(-, "x"), p("y")]]]"#),
        ("- a\n\n      x\n  \t  y\n\n", #"[ul[[p("a"), code(-, "x\ny")]]]"#),
        // Short of four columns, a tab is indentation a block opener may have,
        // also where it decides that a line is not lazy.
        ("- a\n\n  \t# heading\n\n", #"[ul[[p("a"), h1("heading")]]]"#),
        ("- a\n\n  \t---\n\n", #"[ul[[p("a"), hr]]]"#),
        ("- a\n  1. b\n  \t# heading\n\n", #"[ul[[p("a"), ol[[p("b")]], h1("heading")]]]"#),
        ("- a\n  1. b\n  \t- c\n\n", #"[ul[[p("a"), ol[[p("b")]], ul[[p("c")]]]]]"#),
        ("- a\n  1. b\n  \t```\n  x\n  ```\n\n", #"[ul[[p("a"), ol[[p("b")]], code(-, "x")]]]"#),
        ("- a\n  1. b\n  \tc\n\n", #"[ul[[p("a"), ol[[p("b c")]]]]]"#),
        ("  \tfoo\n\n", #"[code(-, "foo")]"#)
    ]

    static let documents = cases.map(\.markdown)

    private func parse(_ chunks: [String]) async -> [BlockSnapshot] {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        for chunk in chunks { _ = await assembler.apply(await tokenizer.feed(chunk)) }
        _ = await assembler.apply(await tokenizer.finish())
        return await assembler.makeSnapshot()
    }

    /// The blocks in the conformance suite's notation: consecutive items of
    /// one kind form a list, an item's own text is its first paragraph, and
    /// whitespace runs collapse.
    private func shape(_ blocks: [BlockSnapshot]) -> String {
        var children: [BlockID: [BlockSnapshot]] = [:]
        for block in blocks {
            if let parent = block.parentID { children[parent, default: []].append(block) }
        }
        func text(_ block: BlockSnapshot) -> String {
            (block.inlineRuns ?? []).map(\.text).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func shapes(_ siblings: [BlockSnapshot]) -> [String] {
            var result: [String] = []
            var index = 0
            while index < siblings.count {
                if case .listItem(let ordered, _, _) = siblings[index].kind {
                    var items: [String] = []
                    while index < siblings.count, case .listItem(let itemOrdered, _, _) = siblings[index].kind, itemOrdered == ordered {
                        let item = siblings[index]
                        var content: [String] = []
                        if !text(item).isEmpty { content.append("p(\(text(item).debugDescription))") }
                        content += shapes(children[item.id] ?? [])
                        items.append("[" + content.joined(separator: ", ") + "]")
                        index += 1
                    }
                    result.append((ordered ? "ol" : "ul") + "[" + items.joined(separator: ", ") + "]")
                    continue
                }
                let block = siblings[index]
                switch block.kind {
                case .paragraph: result.append("p(\(text(block).debugDescription))")
                case .heading(let level): result.append("h\(level)(\(text(block).debugDescription))")
                case .fencedCode:
                    var code = block.codeText ?? ""
                    if code.hasSuffix("\n") { code.removeLast() }
                    result.append("code(-, \(code.debugDescription))")
                case .horizontalRule: result.append("hr")
                case .blockquote:
                    var content: [String] = []
                    if !text(block).isEmpty { content.append("p(\(text(block).debugDescription))") }
                    content += shapes(children[block.id] ?? [])
                    result.append("quote[" + content.joined(separator: ", ") + "]")
                default: result.append("other")
                }
                index += 1
            }
            return result
        }
        return "[" + shapes(blocks.filter { $0.parentID == nil }).joined(separator: ", ") + "]"
    }

    @Test("Each list parses the same at every chunk split", arguments: documents)
    func everyChunkSplit(markdown: String) async {
        let baseline = await parse([markdown])
        let characters = Array(markdown)
        for split in 0...characters.count {
            let streamed = await parse([String(characters[..<split]), String(characters[split...])])
            #expect(streamed == baseline, "Split at character \(split)")
        }
        #expect(await parse(characters.map(String.init)) == baseline)
    }

    @Test("Each list parses the same when split between any two scalars", arguments: documents)
    func everyScalarSplit(markdown: String) async {
        let baseline = await parse([markdown])
        let scalars = Array(markdown.unicodeScalars)
        for split in 0...scalars.count {
            var head = String.UnicodeScalarView(), tail = String.UnicodeScalarView()
            head.append(contentsOf: scalars[..<split])
            tail.append(contentsOf: scalars[split...])
            #expect(await parse([String(head), String(tail)]) == baseline, "Split at scalar \(split)")
        }
    }

    @Test("Each list has cmark-gfm's structure")
    func structure() async {
        for (markdown, expected) in Self.cases {
            let actual = shape(await parse([markdown]))
            #expect(actual == expected, Comment(rawValue: markdown.debugDescription + " → " + actual))
        }
    }

    /// Items cannot hold a block quote yet: a line in an item that would
    /// start one at the top level ends the items and starts it there, as
    /// before items held blocks. (cmark-gfm keeps the quote in the item.)
    static let quoteCases: [(markdown: String, shape: String)] = [
        ("- a\n\n  > # H\n\n", #"[ul[[p("a")]], quote[h1("H")]]"#),
        ("- a\n\n  > q\n  > r\n\n", #"[ul[[p("a")]], quote[p("q r")]]"#),
        ("- a\n\n  > q\n\n  b\n\n", #"[ul[[p("a")]], quote[p("q")], p("b")]"#),
        ("- a\n  > b\n- c\n\n", #"[ul[[p("a")]], quote[p("b")], ul[[p("c")]]]"#),
        // Four columns are code at the top level, so the line stays text.
        ("- a\n  - b\n\n    > q\n\n", #"[ul[[p("a"), ul[[p("b"), p("> q")]]]]]"#)
    ]

    @Test("A quote line in an item starts a quote after the items, at every chunk split")
    func quoteLineEndsItems() async {
        for (markdown, expected) in Self.quoteCases {
            let baseline = await parse([markdown])
            let actual = shape(baseline)
            #expect(actual == expected, Comment(rawValue: markdown.debugDescription + " → " + actual))
            let characters = Array(markdown)
            for split in 0...characters.count {
                let streamed = await parse([String(characters[..<split]), String(characters[split...])])
                #expect(streamed == baseline, Comment(rawValue: markdown.debugDescription + " split at \(split)"))
            }
            #expect(await parse(characters.map(String.init)) == baseline)
        }
    }

    @Test("A long line in a nested item streams in small chunks like the whole text")
    func longItemLineStreams() async {
        let markdown = "- a\n  - b\n\n    " + String(repeating: "word ", count: 6_000) + "*end*\n\n"
        let characters = Array(markdown)
        let chunks = stride(from: 0, to: characters.count, by: 8).map {
            String(characters[$0..<min($0 + 8, characters.count)])
        }
        let whole = await parse([markdown])
        #expect(await parse(chunks) == whole)
        #expect(shape(whole).hasPrefix(#"[ul[[p("a"), ul[[p("b"), p("word word"#))
    }

    @Test("One line opens at most 99 items, as in cmark-gfm; further markers are text")
    func sameLineNestingStops() async {
        let markdown = String(repeating: "- ", count: 1_600) + "x\n\n"
        let characters = Array(markdown)
        let chunks = stride(from: 0, to: characters.count, by: 8).map {
            String(characters[$0..<min($0 + 8, characters.count)])
        }
        let whole = await parse([markdown])
        #expect(await parse(chunks) == whole)
        let items = whole.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 99)
        #expect(whole.count == 99, "the remaining markers are the innermost item's text")
        let text = (items.last?.inlineRuns ?? []).map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text == String(repeating: "- ", count: 1_501) + "x")
    }

    @Test("An item's child blocks render at its text column, the first one with its marker")
    func childBlocksRenderInsideTheItem() async throws {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { await assembler.block($0) }
        for character in "- # Title\n- Bar\n\n  more\n\n" {
            _ = await renderer.apply(await assembler.apply(await tokenizer.feed(String(character))))
        }
        _ = await renderer.apply(await assembler.apply(await tokenizer.finish()))
        let blocks = await renderer.renderedBlocks()
        #expect(blocks.map(\.kind) == [.listItem(ordered: false, index: nil, task: nil), .heading(level: 1),
                                       .listItem(ordered: false, index: nil, task: nil), .paragraph])
        func style(_ block: RenderedBlock) throws -> NSParagraphStyle {
            let content = NSAttributedString.picoConverted(from: block.content)
            return try #require(content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        }
        // The first item has no text of its own: its marker is on the
        // heading's line, which hangs it before the item's text column.
        #expect(blocks[0].content.characters.isEmpty)
        let textIndent = try #require(blocks[0].listItem?.textIndent)
        #expect(textIndent > 0)
        #expect(String(blocks[1].content.characters).hasPrefix("• Title"))
        #expect(try style(blocks[1]).headIndent == textIndent)
        #expect(try style(blocks[1]).firstLineHeadIndent < textIndent)
        // A later child is indented to the column without a marker.
        #expect(String(blocks[2].content.characters).hasPrefix("• Bar"))
        #expect(String(blocks[3].content.characters).hasPrefix("more"))
        #expect(try style(blocks[3]).firstLineHeadIndent == blocks[2].listItem?.textIndent)
    }

    @Test("An item's text streams as it arrives, and a blank line keeps the item open")
    func itemStreamsAndStaysOpen() async {
        let tokenizer = MarkdownTokenizer()
        _ = await tokenizer.feed("- first")
        let more = await tokenizer.feed(" words")
        let text = more.events.compactMap { event -> String? in
            if case .blockAppendInline(_, let runs) = event { return runs.map(\.text).joined() }
            return nil
        }.joined()
        #expect(text == " words")
        let blank = await tokenizer.feed("\n\n")
        #expect(blank.openBlocks.map(\.kind) == [.listItem(ordered: false, index: nil, task: nil)])
        let after = await tokenizer.feed("next")
        #expect(after.events.contains { if case .blockEnd = $0 { return true }; return false })
        #expect(after.openBlocks.map(\.kind) == [.paragraph])
    }
}
