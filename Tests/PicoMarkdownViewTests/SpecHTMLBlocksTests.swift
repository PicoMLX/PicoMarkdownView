import Foundation
import Testing
@testable import PicoMarkdownView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// HTML blocks from the eighth conformance batch: raw HTML lines kept
/// verbatim and shown as plain text. The conformance suite proves the
/// single-shot text; these prove that streaming gives the same result at
/// every chunk split. Expected shapes are cmark-gfm's, in the conformance
/// suite's notation.
@Suite
struct SpecHTMLBlocksTests {
    static let cases: [(markdown: String, shape: String)] = [
        // Kinds 1 to 5 end on the line holding their marker, blank lines
        // and Markdown inside included; the rest of that line is the block's.
        ("<script>\nlet x = 1\n\n</script>\nafter\n\n", #"[html("<script>\nlet x = 1\n\n</script>"), p("after")]"#),
        ("<!-- a\n\n# b -->\n*c*\n\n", #"[html("<!-- a\n\n# b -->"), p("c")]"#),
        ("<?php echo 1; ?>after\ntext\n\n", #"[html("<?php echo 1; ?>after"), p("text")]"#),
        ("<!DOCTYPE html>\n\n", #"[html("<!DOCTYPE html>")]"#),
        ("<![CDATA[\nx\n]]>\n\n", #"[html("<![CDATA[\nx\n]]>")]"#),
        ("<STYLE>\np{}\n</Style>after\nnext\n\n", #"[html("<STYLE>\np{}\n</Style>after"), p("next")]"#),
        ("<textarea>\n\n*a*\n</TEXTAREA>\n\n", #"[html("<textarea>\n\n*a*\n</TEXTAREA>")]"#),
        ("<!-->\nafter\n\n", #"[html("<!-->"), p("after")]"#),
        ("<!-- *a* --> *b*\n*c*\n\n", #"[html("<!-- *a* --> *b*"), p("c")]"#),
        // Kinds 6 and 7 end at a blank line; Markdown inside is text.
        ("<details>\n<summary>Steps</summary>\nRun **this** first\n</details>\n\n",
         #"[html("<details>\n<summary>Steps</summary>\nRun **this** first\n</details>")]"#),
        ("<details>\n\n**bold**\n\n</details>\n\n", #"[html("<details>"), p("bold"), html("</details>")]"#),
        ("<answer>\nThe result is **42**\n</answer>\n\n", #"[html("<answer>\nThe result is **42**\n</answer>")]"#),
        ("<div>\n```\ncode\n```\n\n", #"[html("<div>\n```\ncode\n```")]"#),
        ("<div/>\n\n", #"[html("<div/>")]"#),
        ("<div>\tx\n\n", #"[html("<div>\tx")]"#),
        ("<x-tag data-a='1' b=c d>  \nbody\n\n", #"[html("<x-tag data-a=\'1\' b=c d>  \nbody")]"#),
        ("<x-tag a=\"1\"/>\nbody\n\n", #"[html("<x-tag a=\"1\"/>\nbody")]"#),
        ("</x-tag>\nbody\n\n", #"[html("</x-tag>\nbody")]"#),
        // Raw-text names are lone tags too when kind 1 has not taken them.
        ("</script>\n**bold**\n\n", #"[html("</script>\n**bold**")]"#),
        ("<script/>\nx\n\n", #"[html("<script/>\nx")]"#),
        ("a\n</script>\nx\n\n", #"[p("a </script> x")]"#),
        // A lone tag needs nothing else on its line, and a tag name only
        // counts whole.
        ("<x-tag a=\"1\">tail\n\n", #"[p("<x-tag a=\"1\">tail")]"#),
        ("<b>bold</b> text\n\n", #"[p("<b>bold</b> text")]"#),
        ("<https://example.com>\n\n", #"[p("https://example.com")]"#),
        ("a\n<detailsx>\n\n", #"[p("a <detailsx>")]"#),
        // Indentation: up to three spaces, kept; four are code.
        ("   <div>\n    x\n\n", #"[html("   <div>\n    x")]"#),
        ("    <div>\n\n", #"[code(-, "<div>")]"#),
        // Only kinds 1 to 6 interrupt a paragraph.
        ("Foo\n<div>\nbar\n\n", #"[p("Foo"), html("<div>\nbar")]"#),
        ("Foo\n<answer>\nbar\n\n", #"[p("Foo <answer> bar")]"#),
        ("> a\n<div>\n\n", #"[quote[p("a")], html("<div>")]"#),
        ("| a |\n| --- |\n<div>\n\n", #"[other, html("<div>")]"#),
        // A table is not a paragraph: a lone tag ends it too.
        ("| a |\n| --- |\n<answer>\ntext\n\n", #"[other, html("<answer>\ntext")]"#),
        // Inside quotes and list items: no laziness, and further markers
        // inside the block are text.
        ("> <div>\n> x\n\nafter\n\n", #"[quote[html("<div>\nx")], p("after")]"#),
        ("> <pre>\n> > a\n> </pre>\n\n", #"[quote[html("<pre>\n> a\n</pre>")]]"#),
        ("- <div>\n  x\n\n  y\n\n", #"[ul[[html("<div>\nx"), p("y")]]]"#),
        ("- <div>\nx\n\n", #"[ul[[html("<div>")]], p("x")]"#),
        ("- a\n\n  <!-- c\n\n  -->\n- b\n\n", #"[ul[[p("a"), html("<!-- c\n\n-->")], [p("b")]]]"#),
        ("- a\n  <div>\n\n", #"[ul[[p("a"), html("<div>")]]]"#),
        ("- a\n  <answer>\n\n", #"[ul[[p("a <answer>")]]]"#)
    ]

    static let documents = cases.map(\.markdown)

    private func parse(_ chunks: [String]) async -> [BlockSnapshot] {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        for chunk in chunks { _ = await assembler.apply(await tokenizer.feed(chunk)) }
        _ = await assembler.apply(await tokenizer.finish())
        return await assembler.makeSnapshot()
    }

    private func chunks(_ markdown: String, of size: Int) -> [String] {
        let characters = Array(markdown)
        return stride(from: 0, to: characters.count, by: size).map {
            String(characters[$0..<min($0 + size, characters.count)])
        }
    }

    /// The blocks in the conformance suite's notation: consecutive items of
    /// one kind form a list, an item's or quote's own text is its first
    /// paragraph, and whitespace runs collapse outside code and HTML.
    private func shape(_ blocks: [BlockSnapshot]) -> String {
        var children: [BlockID: [BlockSnapshot]] = [:]
        for block in blocks {
            if let parent = block.parentID { children[parent, default: []].append(block) }
        }
        func text(_ block: BlockSnapshot) -> String {
            (block.inlineRuns ?? []).map(\.text).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func verbatim(_ block: BlockSnapshot) -> String {
            var code = block.codeText ?? ""
            if code.hasSuffix("\n") { code.removeLast() }
            return code.debugDescription
        }
        func contents(_ block: BlockSnapshot) -> String {
            var content: [String] = []
            if !text(block).isEmpty { content.append("p(\(text(block).debugDescription))") }
            content += shapes(children[block.id] ?? [])
            return "[" + content.joined(separator: ", ") + "]"
        }
        func shapes(_ siblings: [BlockSnapshot]) -> [String] {
            var result: [String] = []
            var index = 0
            while index < siblings.count {
                if case .listItem(let ordered, _, _) = siblings[index].kind {
                    var items: [String] = []
                    while index < siblings.count, case .listItem(let itemOrdered, _, _) = siblings[index].kind, itemOrdered == ordered {
                        items.append(contents(siblings[index]))
                        index += 1
                    }
                    result.append((ordered ? "ol" : "ul") + "[" + items.joined(separator: ", ") + "]")
                    continue
                }
                let block = siblings[index]
                switch block.kind {
                case .paragraph: result.append("p(\(text(block).debugDescription))")
                case .blockquote: result.append("quote" + contents(block))
                case .fencedCode: result.append("code(-, \(verbatim(block)))")
                case .htmlBlock: result.append("html(\(verbatim(block)))")
                default: result.append("other")
                }
                index += 1
            }
            return result
        }
        return "[" + shapes(blocks.filter { $0.parentID == nil }).joined(separator: ", ") + "]"
    }

    @Test("Each HTML block parses the same at every chunk split", arguments: documents)
    func everyChunkSplit(markdown: String) async {
        let baseline = await parse([markdown])
        let characters = Array(markdown)
        for split in 0...characters.count {
            let streamed = await parse([String(characters[..<split]), String(characters[split...])])
            #expect(streamed == baseline, "Split at character \(split)")
        }
        #expect(await parse(characters.map(String.init)) == baseline)
    }

    @Test("Each HTML block parses the same when split between any two scalars", arguments: documents)
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

    @Test("Each HTML block has cmark-gfm's structure")
    func structure() async {
        for (markdown, expected) in Self.cases {
            let actual = shape(await parse([markdown]))
            #expect(actual == expected, Comment(rawValue: markdown.debugDescription + " → " + actual))
        }
    }

    @Test("An HTML block's text streams as it arrives, and only a blank line ends a block tag's")
    func htmlStreamsAsItArrives() async {
        let tokenizer = MarkdownTokenizer()
        let opened = await tokenizer.feed("<details>\nRun **th")
        #expect(opened.openBlocks.map(\.kind) == [.htmlBlock])
        let text = { (result: ChunkResult) in
            result.events.compactMap { event -> String? in
                if case .blockAppendFencedCode(_, let chunk) = event { return chunk }
                return nil
            }.joined()
        }
        #expect(text(opened) == "<details>\nRun **th")
        let more = await tokenizer.feed("is**\n</details>\n")
        #expect(text(more) == "is**\n</details>\n")
        #expect(more.openBlocks.map(\.kind) == [.htmlBlock])
        let blank = await tokenizer.feed("  \n")
        #expect(text(blank).isEmpty, "the blank line is not part of the block")
        #expect(blank.openBlocks.isEmpty)
    }

    @Test("A long tag streams in small chunks like the whole text")
    func longTagStreams() async {
        for markdown in [
            "<div class=\"" + String(repeating: "a ", count: 10_000) + "\">\nx\n\n",
            "<x-tag data-a=\"" + String(repeating: "a ", count: 10_000) + "\">\nx\n\n",
            "Foo\n<x-tag data-a=\"" + String(repeating: "a ", count: 10_000) + "\">\nx\n\n",
            "<!-- " + String(repeating: "a ", count: 10_000) + "-->\nx\n\n"
        ] {
            let whole = await parse([markdown])
            #expect(await parse(chunks(markdown, of: 8)) == whole)
        }
        let lone = await parse(chunks("<x-tag data-a=\"" + String(repeating: "a ", count: 10_000) + "\">\nx\n\n", of: 8))
        #expect(lone.map(\.kind) == [.htmlBlock])
        let interrupting = await parse(chunks("Foo\n<x-tag data-a=\"" + String(repeating: "a ", count: 10_000) + "\">\nx\n\n", of: 8))
        #expect(interrupting.map(\.kind) == [.paragraph], "a lone tag does not interrupt a paragraph")
    }

    @Test("A line whose text has gone out is not blank once trimming leaves only its trailing spaces")
    func trimmedLineIsNotBlank() async {
        let spaces = String(repeating: " ", count: 2_000)
        let cases: [(markdown: String, shape: String)] = [
            ("<div>\nhello" + spaces + "\n**bold**\n\n", #"[html("<div>\nhello"# + spaces + #"\n**bold**")]"#),
            ("> <div>\n> hello" + spaces + "\n> **bold**\n\n", #"[quote[html("<div>\nhello"# + spaces + #"\n**bold**")]]"#),
            ("- <div>\n  hello" + spaces + "\n  **bold**\n\n", #"[ul[[html("<div>\nhello"# + spaces + #"\n**bold**")]]]"#),
            ("> hello" + spaces + "\n> more\n\n", #"[quote[p("hello more")]]"#)
        ]
        for (markdown, expected) in cases {
            let whole = await parse([markdown])
            #expect(shape(whole) == expected, Comment(rawValue: String(markdown.prefix(16)).debugDescription))
            #expect(await parse(chunks(markdown, of: 8)) == whole, Comment(rawValue: String(markdown.prefix(16)).debugDescription))
        }
    }

    @Test("An HTML block renders as its text, in the body font")
    func rendersAsPlainText() async throws {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { await assembler.block($0) }
        _ = await renderer.apply(await assembler.apply(await tokenizer.feed("Intro\n\n<details>\n<summary>Steps</summary>\nRun **this**\n</details>\n\n")))
        _ = await renderer.apply(await assembler.apply(await tokenizer.finish()))
        let blocks = await renderer.renderedBlocks()
        #expect(blocks.map(\.kind) == [.paragraph, .htmlBlock])
        #expect(String(blocks[1].content.characters) == "<details>\n<summary>Steps</summary>\nRun **this**\n</details>\n")
        func font(_ block: RenderedBlock) throws -> PlatformFont {
            let content = NSAttributedString.picoConverted(from: block.content)
            return try #require(content.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
        }
        #expect(try font(blocks[1]) == font(blocks[0]))
        #expect(blocks[1].codeBlock == nil)
    }
}
