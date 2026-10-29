#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS code block decoration metadata")
@MainActor
struct MacCodeBlockMetadataTests {
    @Test("Only complete code blocks carry decoration IDs and colors")
    func codeMetadataExcludesInlineBackgrounds() async throws {
        let pipeline = MarkdownStreamingPipeline()
        let backend = TextKitStreamingBackend()
        let markdown = """
        Paragraph with `inline code` and <kbd>key</kbd>.

        ```swift
        let first = 1

        print(first)
        ```

            indented one

            indented two

        ```text
        separate block
        ```

        After paragraph.

        """
        apply(await pipeline.feed(markdown), to: backend)
        apply(await pipeline.finish(), to: backend)
        let blocks = await pipeline.blocksSnapshot()
        let storage = backend.snapshotAttributedString()
        #expect(blocks.filter { $0.codeBlock != nil }.count == 3)
        var offset = 0
        var ids: [UInt64] = []
        for block in blocks {
            let source = NSAttributedString.picoConverted(from: block.content)
            let rendered = storage.attributedSubstring(from: NSRange(location: offset, length: source.length))
            offset += source.length
            if block.codeBlock != nil {
                ids.append(block.id)
                #expect(rendered.string.hasSuffix("\n"))
                for index in 0..<rendered.length {
                    #expect((rendered.attribute(.picoCodeBlockID, at: index, effectiveRange: nil) as? NSNumber)?.uint64Value == block.id)
                    #expect(rendered.attribute(.picoCodeBlockBackgroundColor, at: index, effectiveRange: nil) as? NSColor ==
                            rendered.attribute(.backgroundColor, at: index, effectiveRange: nil) as? NSColor)
                }
                #expect(source.attribute(.picoCodeBlockID, at: 0, effectiveRange: nil) == nil)
            } else {
                rendered.enumerateAttribute(.picoCodeBlockID, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
                    #expect(value == nil)
                }
            }
        }
        #expect(Set(ids).count == 3)
        let keyboard = (storage.string as NSString).range(of: "key")
        #expect(keyboard.location != NSNotFound)
        #expect(storage.attribute(.backgroundColor, at: keyboard.location, effectiveRange: nil) != nil)
        #expect(storage.attribute(.picoCodeBlockBackgroundColor, at: keyboard.location, effectiveRange: nil) == nil)
    }

    @Test("Appending and closing a fence retain its ID through blank lines and the final newline")
    func streamingKeepsCodeMetadata() async throws {
        let pipeline = MarkdownStreamingPipeline()
        let backend = TextKitStreamingBackend()
        apply(await pipeline.feed("```swift\nlet value ="), to: backend)
        let initial = backend.snapshotAttributedString()
        let id = try #require(initial.attribute(.picoCodeBlockID, at: 0, effectiveRange: nil) as? NSNumber)
        apply(await pipeline.feed(" 1\n\nprint(value)\n"), to: backend)
        apply(await pipeline.feed("```\n\n"), to: backend)
        apply(await pipeline.finish(), to: backend)
        let final = backend.snapshotAttributedString()
        #expect(final.string.contains("\n\n"))
        for index in 0..<final.length {
            #expect(final.attribute(.picoCodeBlockID, at: index, effectiveRange: nil) as? NSNumber == id)
            #expect(final.attribute(.picoCodeBlockBackgroundColor, at: index, effectiveRange: nil) is NSColor)
        }
    }

    @Test("A transparent code theme does not introduce a block background")
    func transparentThemeHasNoDecoration() async {
        let theme = MarkdownRenderTheme.default().withCodeHighlighting(
            codeBlockTheme: CodeBlockTheme(font: FontSpec(size: 15), foregroundColor: .label, backgroundColor: .clear),
            codeHighlighter: nil)
        let pipeline = MarkdownStreamingPipeline(theme: theme)
        let backend = TextKitStreamingBackend()
        apply(await pipeline.feed("```text\nno fill\n```\n\n"), to: backend)
        apply(await pipeline.finish(), to: backend)
        let storage = backend.snapshotAttributedString()
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
            #expect(attributes[.picoCodeBlockID] == nil)
            #expect(attributes[.picoCodeBlockBackgroundColor] == nil)
            #expect(attributes[.backgroundColor] == nil)
        }
    }

    private func apply(_ update: StreamingUpdate?, to backend: TextKitStreamingBackend) {
        guard let update else { return }
        _ = backend.apply(blocks: update.blocks, diffs: [update.diff], selection: NSRange(location: 0, length: 0))
    }
}
#endif
