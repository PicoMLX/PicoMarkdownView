import Foundation
import Testing
@testable import PicoMarkdownView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    
    @Test("Multiline paragraph streaming preserves content")
    func multilineParagraphRendering() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let first = await tokenizer.feed("This is a multiline\n")
        let diff1 = await assembler.apply(first)
        _ = await renderer.apply(diff1)

        let second = await tokenizer.feed("paragraph!\n\n")
        let diff2 = await assembler.apply(second)
        _ = await renderer.apply(diff2)

        let output = await renderer.currentAttributedString()
        let rendered = String(output.characters)
        #expect(rendered.contains("This is a multiline paragraph!"))
    }
    
    @Test("Multiline paragraph single feed preserves content")
    func singleFeedMultilineParagraphRendering() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let first = await tokenizer.feed("This is a multiline\nparagraph!\n\n")
        let diff1 = await assembler.apply(first)
        _ = await renderer.apply(diff1)

        let output = await renderer.currentAttributedString()
        let rendered = String(output.characters)
        #expect(rendered.contains("This is a multiline paragraph!"))
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

    @Test("Paragraph soft line breaks emit spaces")
    func paragraphSoftBreaksEmitSpaces() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let sample = "Readability, however, is emphasized above all else. A Markdown-formatted\ndocument should be publishable as-is.\n\n"
        let chunk = await tokenizer.feed(sample)
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        guard let firstEvent = chunk.events.first else {
            Issue.record("Missing events")
            return
        }
        let blockID: BlockID
        switch firstEvent {
        case .blockStart(let id, _):
            blockID = id
        default:
            Issue.record("Unexpected first event: \(firstEvent)")
            return
        }

        let snapshot = await assembler.block(blockID)
        let texts = snapshot.inlineRuns?.map(\.text) ?? []
        let joined = texts.joined()
        #expect(joined.contains("Markdown-formatted document"))

        let output = await renderer.currentAttributedString()
        let rendered = String(output.characters)
        #expect(rendered.contains("Markdown-formatted document"))
    }

    @Test("Renderer surfaces inline images")
    func rendererSurfacesInlineImages() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let chunk = await tokenizer.feed("Intro ![diagram](https://example.com/diagram.png) outro\n\n")
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        let blocks = await renderer.renderedBlocks()
        guard let paragraph = blocks.first else {
            Issue.record("Missing rendered blocks")
            return
        }

        #expect(paragraph.images.count == 1)
        if let descriptor = paragraph.images.first {
            #expect(descriptor.source == "https://example.com/diagram.png")
            #expect(descriptor.url == URL(string: "https://example.com/diagram.png"))
            #expect(descriptor.altText == "diagram")
        }

        let renderedString = String(paragraph.content.characters)
        #expect(renderedString.contains("Intro"))
        #expect(renderedString.contains("outro"))
        #expect(!renderedString.contains("diagram"))
    }

    @Test("Tables render with text table blocks")
    func tablesRenderWithStyledBlocks() async {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let renderer = MarkdownRenderer { id in
            await assembler.block(id)
        }

        let tableMarkdown = """
        | Col A | Col B |
        | :--- | ---: |
        | A1 | B1 |
        | A2 | B2 |

        """

        let chunk = await tokenizer.feed(tableMarkdown)
        let diff = await assembler.apply(chunk)
        _ = await renderer.apply(diff)

        let finishChunk = await tokenizer.finish()
        let finishDiff = await assembler.apply(finishChunk)
        _ = await renderer.apply(finishDiff)

        let output = await renderer.currentAttributedString()
        let ns = NSAttributedString(output)
        let searchRange = NSRange(location: 0, length: ns.length)

        var foundTableBlock = false
        ns.enumerateAttribute(.paragraphStyle, in: searchRange, options: []) { value, _, stop in
            guard let paragraph = value as? NSParagraphStyle else { return }
            if paragraph.textBlocks.contains(where: { $0 is NSTextTableBlock }) {
                foundTableBlock = true
                stop.pointee = true
            }
        }

        #expect(foundTableBlock)

#if canImport(UIKit)
        typealias TestFont = UIFont
#else
        typealias TestFont = NSFont
#endif

        if ns.length > 0, let font = ns.attribute(.font, at: 0, effectiveRange: nil) as? TestFont {
#if canImport(UIKit)
            #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
#else
            #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
#endif
        } else {
            Issue.record("Missing font attribute for table header")
        }
    }
}
