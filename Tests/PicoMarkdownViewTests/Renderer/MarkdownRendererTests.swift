import Foundation
import Testing
@testable import PicoMarkdownView

@Suite
struct MarkdownRendererTests {
    @Test("Paragraph rendering produces joined text")
    func paragraphRendering() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let first = await tokenizer.feed("Hello ")
        let diff1 = await assembler.apply(first)
        _ = await renderer.apply(diff1)

        let second = await tokenizer.feed("world\n\n")
        let diff2 = await assembler.apply(second)
        _ = await renderer.apply(diff2)

        let output = await renderer.currentAttributedString()
        let rendered = String(output.characters)
        #expect(rendered.contains("Hello world"))
    }

    @Test("Heading and list are rendered with prefixes")
    func headingAndListRendering() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let chunk = await tokenizer.feed("# Title\n- First item\n- Second item\n\n")
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        let output = await renderer.currentAttributedString()
        let rendered = String(output.characters)
        #expect(rendered.contains("Title"))
        #expect(rendered.contains("• First item"))
        #expect(rendered.contains("• Second item"))
    }

    @Test("Table rendering flattens rows with separators")
    func tableRendering() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let chunk = await tokenizer.feed("| A | B |\n| --- | --- |\n| 1 | 2 |\n\n")
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        let output = await renderer.currentAttributedString()
        let rendered = String(output.characters)
        #expect(rendered.contains("A | B"))
        #expect(rendered.contains("1 | 2"))
    }

    @Test("Empty diff produces no update")
    func emptyDiffReturnsNil() async {
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let diff = AssemblerDiff(documentVersion: 0, changes: [])
        let result = await renderer.apply(diff)
        #expect(result == nil)
    }
}
