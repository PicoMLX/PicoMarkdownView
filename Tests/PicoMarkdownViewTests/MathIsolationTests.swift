import Testing
@testable import PicoMarkdownView

@Suite
struct MathIsolationTests {
    struct Equation: Sendable {
        let source: String
        let tex: String
        var display: Bool = false
    }

    static let equations = [
        Equation(source: #"$\frac{1}{\sqrt{x}}$"#, tex: #"\frac{1}{\sqrt{x}}"#),
        Equation(source: #"$\sum_{i=1}^{n} i$"#, tex: #"\sum_{i=1}^{n} i"#),
        Equation(source: #"$a_{b} * c + [x] + @person$"#, tex: #"a_{b} * c + [x] + @person"#),
        Equation(source: #"$x + \$y$"#, tex: #"x + \$y"#),
        Equation(source: #"$x\\$"#, tex: #"x\\"#),
        Equation(source: #"$$\frac{a}{b}$$"#, tex: #"\frac{a}{b}"#, display: true),
        Equation(source: "$\u{03B1}+\u{03B2}$", tex: "\u{03B1}+\u{03B2}"),
        Equation(source: #"\(\text{`code`} + a_b + [link](url)\)"#, tex: #"\text{`code`} + a_b + [link](url)"#),
        Equation(source: #"\[a_b * c + $x$\]"#, tex: #"a_b * c + $x$"#, display: true)
    ]

    @Test("Math is opaque to Markdown at every chunk split", arguments: equations)
    func mathIsOpaque(equation: Equation) async {
        let markdown = "Equation: " + equation.source + "\n\n"
        let expected = [InlineRun(text: "Equation: "),
                        InlineRun(text: equation.tex, style: [.math], math: MathInlinePayload(tex: equation.tex, display: equation.display))]
        #expect(await parse([markdown]).runs == expected)
        let characters = Array(markdown)
        for split in 0...characters.count {
            let chunks = [String(characters[..<split]), String(characters[split...])]
            #expect(await parse(chunks).runs == expected, "Split at \(split)")
        }
        let chunks = characters.map(String.init)
        let first = await parse(chunks)
        #expect(first.runs == expected)
        #expect(await parse(chunks).events == first.events)
    }

    @Test("Table math emits no raw TeX or duplicated plain runs")
    func tableMathHasNoRawText() async {
        let tokenizer = MarkdownTokenizer()
        var events: [BlockEvent] = []
        for chunk in ["| Formula | Value |\n", "| --- | --- |\n", #"| $\frac{1}{\sqrt{x}}$ | $\sum_{i=1}^{n} i$ |"# + "\n\n"] {
            events += await tokenizer.feed(chunk).events
        }
        events += await tokenizer.finish().events
        let rows = events.compactMap { event -> [[InlineRun]]? in
            if case .tableAppendRow(_, let cells) = event { return cells }
            return nil
        }
        #expect(rows.count == 1)
        #expect(rows.first == Self.equations.prefix(2).map { equation in
            [InlineRun(text: equation.tex, style: [.math], math: MathInlinePayload(tex: equation.tex, display: false))]
        })
        #expect(!events.contains { if case .blockAppendInline = $0 { return true }; return false })
    }

    @Test("Unclosed math retains its literal TeX without corrections")
    func unclosedMathIsLiteral() async {
        let result = await parse(["Equation: $", #"\frac{a}{b} * [x]"#])
        #expect(result.runs == [InlineRun(text: #"Equation: $\frac{a}{b} * [x]"#)])
    }

    @Test("Long math remains local and emits only when closed")
    func longMathEmitsOnce() async {
        let tokenizer = MarkdownTokenizer()
        _ = await tokenizer.feed("Equation: $")
        let chunk = String(repeating: "a_1 + ", count: 32)
        for _ in 0..<100 {
            let result = await tokenizer.feed(chunk)
            #expect(result.events.isEmpty)
            #expect(result.openBlocks.count == 1)
        }
        let result = await tokenizer.feed("$\n\n")
        let mathRuns = result.events.flatMap { event -> [InlineRun] in
            if case .blockAppendInline(_, let runs) = event { return runs.filter { $0.math != nil } }
            return []
        }
        #expect(mathRuns == [InlineRun(text: String(repeating: chunk, count: 100), style: [.math],
            math: MathInlinePayload(tex: String(repeating: chunk, count: 100), display: false))])
        #expect(result.openBlocks.isEmpty)
        #expect(await tokenizer.finish().events.isEmpty)
    }

    private func parse(_ chunks: [String]) async -> (runs: [InlineRun], events: [BlockEvent]) {
        let tokenizer = MarkdownTokenizer()
        var events: [BlockEvent] = []
        for chunk in chunks { events += await tokenizer.feed(chunk).events }
        events += await tokenizer.finish().events
        var normalized: [InlineRun] = []
        for event in events {
            guard case .blockAppendInline(_, let runs) = event else { continue }
            for run in runs {
                if let last = normalized.last, last.canCoalesce(with: run) {
                    normalized[normalized.count - 1].text += run.text
                } else { normalized.append(run) }
            }
        }
        return (normalized, events)
    }
}
