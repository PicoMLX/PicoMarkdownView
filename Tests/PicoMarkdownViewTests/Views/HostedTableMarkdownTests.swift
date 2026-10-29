#if os(macOS)
import Foundation
import Testing
@testable import PicoMarkdownView

@Suite("Hosted table Markdown export")
struct HostedTableMarkdownTests {
    @Test("Adjacent fragments keep one semantic emphasis or code span")
    func adjacentStyledFragmentsRoundTrip() async throws {
        let cells = [
            [InlineRun(text: "bo", style: .bold), InlineRun(text: "ld", style: .bold)],
            [InlineRun(text: "em", style: .italic), InlineRun(text: "phasis", style: .italic)],
            [InlineRun(text: "co", style: .code), InlineRun(text: "de", style: .code)],
            [InlineRun(text: "struck", style: .strikethrough), InlineRun(text: "through", style: .strikethrough)]
        ]
        let table = TableSnapshot(headerCells: [[InlineRun(text: "Content")]], rows: cells.map { [$0] }, isHeaderConfirmed: true)
        let exported = PicoHostedTableMarkdown.render(table)
        let reparsed = try await parseTable(exported, chunkSize: 2)
        #expect(reparsed.rows.count == cells.count)
        for (actual, expected) in zip(reparsed.rows, cells) {
            #expect(normalized(try #require(actual.first)) == normalized(expected), Comment(rawValue: exported))
        }
    }

    @Test("Small-chunk table copies preserve inline meaning", arguments: [
        "**bold *and italic* tail**",
        "*italic **and bold** tail*",
        "[**bold** and *italic*](https://example.com/a_(b))",
        "@alice, **@bob** and @[Display Name](u-2345)",
        "`` `tick` `` and `  padded  `",
        #"escaped \| pipe and backslash \\ with literal \* markers"#,
        #"`code\|pipe` plus \(a \mid b\)"#,
        #"[link](https://example.com/a_(b)) + \(x^{2}\) + ![alt](https://example.com/a.png "title")"#,
        "plain &amp; &lt;tag&gt; ~~struck~~ <kbd>key</kbd> x<sup>2</sup> and H<sub>2</sub>O"
    ])
    func realisticCellsRoundTrip(cell: String) async throws {
        let source = "| Content |\n| :--- |\n| \(cell) |\n\n"
        let baseline = try await parseTable(source, chunkSize: 1)
        // Real tokenizer output is deliberately fragmented again to model
        // presentation data arriving in adjacent chunks of the same style.
        var fragmented = baseline
        fragmented.headerCells = baseline.headerCells?.map(fragment)
        fragmented.rows = baseline.rows.map { $0.map(fragment) }
        let exported = PicoHostedTableMarkdown.render(fragmented)
        for chunkSize in [1, 3, 7] {
            let reparsed = try await parseTable(exported, chunkSize: chunkSize)
            #expect(reparsed.alignments == baseline.alignments)
            #expect(reparsed.rows.count == baseline.rows.count)
            for (actualRow, expectedRow) in zip(reparsed.rows, baseline.rows) {
                #expect(actualRow.count == expectedRow.count)
                for (actual, expected) in zip(actualRow, expectedRow) {
                    #expect(normalized(actual) == normalized(expected), Comment(rawValue: exported))
                }
            }
        }
    }

    @Test("Pipe and slash escaping preserves the table shape and cell values")
    func escapesTableDelimiters() async throws {
        let values = ["one|two", #"one\|two"#, #"two\\|three"#, "`quoted`", "a & b", "<literal>"]
        let table = TableSnapshot(headerCells: values.enumerated().map { [InlineRun(text: "Column \($0.offset)")] },
                                  alignments: [.left, .center, .right, .none, .left, .none],
                                  rows: [values.map { [InlineRun(text: $0)] }], isHeaderConfirmed: true)
        let exported = PicoHostedTableMarkdown.render(table)
        let reparsed = try await parseTable(exported, chunkSize: 1)
        let cells = try #require(reparsed.rows.first)
        #expect(cells.count == values.count)
        #expect(cells.map { $0.map(\.text).joined() } == values)
        #expect(reparsed.alignments == table.alignments?.map { $0 == .none ? .left : $0 })
    }

    private func parseTable(_ markdown: String, chunkSize: Int) async throws -> TableSnapshot {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        let characters = Array(markdown)
        for start in stride(from: 0, to: characters.count, by: chunkSize) {
            let chunk = String(characters[start..<min(start + chunkSize, characters.count)])
            _ = await assembler.apply(await tokenizer.feed(chunk))
        }
        _ = await assembler.apply(await tokenizer.finish())
        let blocks = await assembler.makeSnapshot()
        return try #require(blocks.first(where: { $0.kind == .table })?.table)
    }

    private func fragment(_ runs: [InlineRun]) -> [InlineRun] {
        runs.flatMap { run in
            guard run.math == nil, run.image == nil, run.tag == nil else { return [run] }
            return run.text.map { character in
                var fragment = run
                fragment.text = String(character)
                return fragment
            }
        }
    }

    private func normalized(_ runs: [InlineRun]) -> [InlineRun] {
        var result: [InlineRun] = []
        for run in runs {
            if let last = result.last, last.canCoalesce(with: run) {
                result[result.count - 1].text += run.text
            } else { result.append(run) }
        }
        return result
    }
}
#endif
