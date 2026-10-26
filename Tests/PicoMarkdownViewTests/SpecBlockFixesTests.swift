import Foundation
import Testing
@testable import PicoMarkdownView

/// Block-level CommonMark fixes from the first conformance batch. The spec
/// examples in the conformance suite prove the single-shot parse; these prove
/// that streaming produces the same blocks at every chunk split, and pin the
/// structures the fixes are about.
@Suite
struct SpecBlockFixesTests {
    static let documents = [
        // ATX headings: closing sequences, escaped hashes, empty headings, tabs.
        "### foo ###     \n\n",
        "# foo#\n\n",
        "### foo \\###\n## foo #\\##\n# foo \\#\n\n",
        "## \n#\n### ###\n\n",
        "#\tFoo\n\n",
        // Thematic breaks: not four spaces into a paragraph; tabs between markers.
        "Foo\n    ***\n\n",
        "*\t*\t*\t\n\n",
        // Fences: backticks in a backtick info string; escapes in the info string.
        "``` ```\naaa\n\n",
        "``` foo\\+bar\nfoo\n```\n\n",
        // Indented code: blank lines inside and after the block.
        "    chunk1\n\n    chunk2\n  \n \n \n    chunk3\n\n",
        "    chunk1\n      \n      chunk2\n\n",
        "\n    \n    foo\n    \n\n",
        // `\[` is an escaped bracket unless it is display math alone or closed on its line.
        "\\[not a link](/foo)\n\\`not code`\n\n",
        "\\[\nx\n\\]\n\n",
        "\\[x\\]\n\n",
        // Backslashes: only ASCII punctuation is escapable; a trailing one is a hard break.
        "\\\t\\A\\a\\ \\3\\φ\\«\n\n",
        "foo\\\nbar\n\n",
        "foo\\\n\n",
        "foo\\\\\nbar\n\n"
    ]

    private func parse(_ chunks: [String]) async -> [BlockSnapshot] {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        for chunk in chunks { _ = await assembler.apply(await tokenizer.feed(chunk)) }
        _ = await assembler.apply(await tokenizer.finish())
        return await assembler.makeSnapshot()
    }

    private func text(of block: BlockSnapshot) -> String {
        (block.inlineRuns ?? []).map(\.text).joined()
    }

    @Test("Each fixed construct parses the same at every chunk split", arguments: documents)
    func everyChunkSplit(markdown: String) async {
        let baseline = await parse([markdown])
        let characters = Array(markdown)
        for split in 0...characters.count {
            let streamed = await parse([String(characters[..<split]), String(characters[split...])])
            #expect(streamed == baseline, "Split at character \(split)")
        }
        #expect(await parse(characters.map(String.init)) == baseline)
    }

    @Test("Closing sequences, escaped hashes and empty headings")
    func headings() async throws {
        #expect(await parse([Self.documents[0]]).map(text(of:)) == ["foo"])
        #expect(await parse([Self.documents[1]]).map(text(of:)) == ["foo#"], "a closing sequence needs a space before it")
        #expect(await parse([Self.documents[2]]).map(text(of:)) == ["foo ###", "foo ###", "foo #"], "escaped hashes are content")
        let empty = await parse([Self.documents[3]])
        #expect(empty.map(\.kind) == [.heading(level: 2), .heading(level: 1), .heading(level: 3)])
        #expect(empty.map(text(of:)) == ["", "", ""])
        let tab = await parse([Self.documents[4]])
        #expect(tab.map(\.kind) == [.heading(level: 1)])
        #expect(tab.map(text(of:)) == ["Foo"])
        let unterminated = await parse(["# foo#"])
        #expect(unterminated.map(text(of:)) == ["foo#"], "the tail settles at the end of input too")
    }

    @Test("Thematic breaks: indentation and tabs")
    func thematicBreaks() async {
        let continuation = await parse([Self.documents[5]])
        #expect(continuation.map(\.kind) == [.paragraph])
        let words = continuation.map { text(of: $0).split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        #expect(words == ["Foo ***"], "four spaces continue the paragraph")
        #expect(await parse([Self.documents[6]]).map(\.kind) == [.horizontalRule])
    }

    @Test("Fence info strings")
    func fences() async throws {
        let notAFence = await parse([Self.documents[7]])
        #expect(notAFence.map(\.kind) == [.paragraph], "a backtick info string may not contain backticks")
        let escaped = await parse([Self.documents[8]])
        #expect(escaped.map(\.kind) == [.fencedCode(language: "foo+bar")])
    }

    @Test("Indented code keeps interior blank lines, stripped like code, and drops trailing ones")
    func indentedCode() async throws {
        #expect(await parse([Self.documents[9]]).first?.codeText == "chunk1\n\nchunk2\n\n\n\nchunk3\n")
        #expect(await parse([Self.documents[10]]).first?.codeText == "chunk1\n  \n  chunk2\n")
        let trailing = await parse([Self.documents[11]])
        #expect(trailing.map(\.kind) == [.fencedCode(language: nil)])
        #expect(trailing.first?.codeText == "foo\n")
    }

    @Test("A backslash-bracket line is a paragraph unless it is display math alone or closed on its line")
    func escapedBracketVersusDisplayMath() async throws {
        let paragraph = await parse([Self.documents[12]])
        #expect(paragraph.map(\.kind) == [.paragraph])
        #expect(try #require(paragraph.first.map(text(of:))).contains("[not a link](/foo)"))
        #expect(try #require(paragraph.first.map(text(of:))).contains("`not code`"))
        #expect(await parse([Self.documents[13]]).map(\.kind) == [.math(display: true)])
        #expect(await parse([Self.documents[14]]).map(\.kind) == [.math(display: true)])
    }

    @Test("Backslashes escape ASCII punctuation only; a trailing one is a hard break")
    func backslashes() async throws {
        #expect(await parse([Self.documents[15]]).map(text(of:)) == ["\\\t\\A\\a\\ \\3\\φ\\«"])
        #expect(await parse([Self.documents[16]]).map(text(of:)) == ["foo\nbar"])
        #expect(await parse([Self.documents[17]]).map(text(of:)) == ["foo\\"], "a backslash ending the paragraph is literal")
        #expect(await parse([Self.documents[18]]).map(text(of:)) == ["foo\\ bar"], "an escaped backslash is not a break")
    }
}
