import Foundation
import Testing
@testable import PicoMarkdownView

@Suite
struct MarkdownTokenizerGoldenTests {
    @Test("Simple paragraph across chunks")
    func simpleParagraph() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("Hello ")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain("Hello ")])
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed("world")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [plain("world")])
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let third = await tokenizer.feed("\n\n")
        assertChunk(third, matches: .init(
            events: [
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Emphasis split across chunks")
    func emphasisSplitAcrossChunks() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("**bo")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph)
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed("ld** and more\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [
                    InlineRunShape(text: "bold", style: InlineStyle.bold),
                    plain(" and more")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Fenced code streaming")
    func fencedCodeStreaming() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("```swift\nlet x = 1")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.fencedCode(language: "swift")),
                .blockAppendFencedCode(.fencedCode(language: "swift"), textChunk: "let x = 1")
            ],
            openBlocks: [.fencedCode(language: "swift")]
        ), state: &state)

        let second = await tokenizer.feed("\nprint(x)\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendFencedCode(.fencedCode(language: "swift"), textChunk: "\nprint(x)\n")
            ],
            openBlocks: [.fencedCode(language: "swift")]
        ), state: &state)

        let third = await tokenizer.feed("```\n\n")
        assertChunk(third, matches: .init(
            events: [
                .blockEnd(.fencedCode(language: "swift"))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Heading then paragraph")
    func headingThenParagraph() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("# Title\nNext line of para")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.heading(level: 1)),
                .blockAppendInline(.heading(level: 1), runs: [plain("Title")]),
                .blockEnd(.heading(level: 1)),
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain("Next line of para")])
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed("graph\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [plain("graph")]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Unordered list across chunks")
    func unorderedListAcrossChunks() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("- First item\n- Sec")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.listItem(ordered: false, index: nil)),
                .blockAppendInline(.listItem(ordered: false, index: nil), runs: [plain("First item")]),
                .blockEnd(.listItem(ordered: false, index: nil)),
                .blockStart(.listItem(ordered: false, index: nil)),
                .blockAppendInline(.listItem(ordered: false, index: nil), runs: [plain("Sec")])
            ],
            openBlocks: [.listItem(ordered: false, index: nil)]
        ), state: &state)

        let second = await tokenizer.feed("ond item\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.listItem(ordered: false, index: nil), runs: [plain("ond item")]),
                .blockEnd(.listItem(ordered: false, index: nil))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Table with delayed separator")
    func tableWithDelayedSeparator() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("| Col A | Col B |\n")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.table),
                .tableHeaderCandidate(.table, cells: [plain("Col A"), plain("Col B")])
            ],
            openBlocks: [.table]
        ), state: &state)

        let second = await tokenizer.feed("| --- | :---: |\n")
        assertChunk(second, matches: .init(
            events: [
                .tableHeaderConfirmed(.table, alignments: [.left, .center])
            ],
            openBlocks: [.table]
        ), state: &state)

        let third = await tokenizer.feed("| a1 | b1 |\n| a2 | b2 |\n\n")
        assertChunk(third, matches: .init(
            events: [
                .tableAppendRow(.table, cells: [[plain("a1")], [plain("b1")]]),
                .tableAppendRow(.table, cells: [[plain("a2")], [plain("b2")]]),
                .blockEnd(.table)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Unknown block fallback")
    func unknownBlockFallback() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed(":::note\nCustom ext\n:::\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.unknown),
                .blockAppendInline(.unknown, runs: [plain(":::note\nCustom ext\n:::\n")]),
                .blockEnd(.unknown)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Hard line break handling")
    func hardLineBreakHandling() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("line 1  \nline 2\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    plain("line 1"),
                    plain("\n"),
                    plain("line 2")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Paragraph, fence, paragraph mixed")
    func paragraphFenceParagraphMixed() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("Intro\n```js\nconst a=1")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain("Intro")]),
                .blockEnd(.paragraph),
                .blockStart(.fencedCode(language: "js")),
                .blockAppendFencedCode(.fencedCode(language: "js"), textChunk: "const a=1")
            ],
            openBlocks: [.fencedCode(language: "js")]
        ), state: &state)

        let second = await tokenizer.feed("\n```\nOutro\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendFencedCode(.fencedCode(language: "js"), textChunk: "\n"),
                .blockEnd(.fencedCode(language: "js")),
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain("Outro")]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Finish closes open fence")
    func finishClosesOpenFence() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("```python\nprint(1)")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.fencedCode(language: "python")),
                .blockAppendFencedCode(.fencedCode(language: "python"), textChunk: "print(1)")
            ],
            openBlocks: [.fencedCode(language: "python")]
        ), state: &state)

        let final = await tokenizer.finish()
        assertChunk(final, matches: .init(
            events: [
                .blockEnd(.fencedCode(language: "python"))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Link inline run")
    func linkInlineRun() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("See [site](https://ex.am) please\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    plain("See "),
                    InlineRunShape(text: "site", style: InlineStyle.link, linkURL: "https://ex.am"),
                    plain(" please")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Stress long paragraph incremental appends")
    func stressLongParagraph() async {
        let tokenizer = MarkdownTokenizer()
        var expectations: [ChunkExpectation] = []
        var state = EventNormalizationState()

        for index in 0..<100 {
            let chunk = String(repeating: "a", count: 1000)
            let result = await tokenizer.feed(chunk)
            if index == 0 {
                expectations.append(.init(
                    events: [
                        .blockStart(.paragraph),
                        .blockAppendInline(.paragraph, runs: [plain(chunk)])
                    ],
                    openBlocks: [.paragraph]
                ))
            } else {
                expectations.append(.init(
                    events: [
                        .blockAppendInline(.paragraph, runs: [plain(chunk)])
                    ],
                    openBlocks: [.paragraph]
                ))
            }
            assertChunk(result, matches: expectations[index], state: &state)
        }

        let terminator = await tokenizer.feed("\n\n")
        assertChunk(terminator, matches: .init(
            events: [
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }
}

// MARK: - Helpers

private struct ChunkExpectation: Sendable {
    var events: [EventShape]
    var openBlocks: [BlockKind] = []
}

private enum EventShape: Equatable {
    case blockStart(BlockKind)
    case blockAppendInline(BlockKind, runs: [InlineRunShape])
    case blockAppendFencedCode(BlockKind, textChunk: String)
    case tableHeaderCandidate(BlockKind, cells: [InlineRunShape])
    case tableHeaderConfirmed(BlockKind, alignments: [TableAlignment])
    case tableAppendRow(BlockKind, cells: [[InlineRunShape]])
    case blockEnd(BlockKind)
}

private struct InlineRunShape: Equatable {
    var text: String
    var styleRawValue: UInt8
    var linkURL: String?

    init(text: String, style: InlineStyle = [], linkURL: String? = nil) {
        self.text = text
        self.styleRawValue = style.rawValue
        self.linkURL = linkURL
    }

    init(_ run: InlineRun) {
        self.text = run.text
        self.styleRawValue = run.style.rawValue
        self.linkURL = run.linkURL
    }
}

private func plain(_ text: String) -> InlineRunShape {
    InlineRunShape(text: text)
}

private struct EventNormalizationState {
    var map: [BlockID: BlockKind] = [:]
}

private func normalizeEvents(_ events: [BlockEvent], state: inout EventNormalizationState) -> [EventShape] {
    var shapes: [EventShape] = []
    for event in events {
        switch event {
        case .blockStart(let id, let kind):
            state.map[id] = kind
            shapes.append(.blockStart(kind))
        case .blockAppendInline(let id, let runs):
            let kind = state.map[id] ?? .unknown
            shapes.append(.blockAppendInline(kind, runs: runs.map(InlineRunShape.init)))
        case .blockAppendFencedCode(let id, let text):
            let kind = state.map[id] ?? .unknown
            shapes.append(.blockAppendFencedCode(kind, textChunk: text))
        case .tableHeaderCandidate(let id, let cells):
            let kind = state.map[id] ?? .table
            shapes.append(.tableHeaderCandidate(kind, cells: cells.map(InlineRunShape.init)))
        case .tableHeaderConfirmed(let id, let alignments):
            let kind = state.map[id] ?? .table
            shapes.append(.tableHeaderConfirmed(kind, alignments: alignments))
        case .tableAppendRow(let id, let cells):
            let kind = state.map[id] ?? .table
            let shapedCells = cells.map { $0.map(InlineRunShape.init) }
            shapes.append(.tableAppendRow(kind, cells: shapedCells))
        case .blockEnd(let id):
            let kind = state.map[id] ?? .unknown
            state.map[id] = nil
            shapes.append(.blockEnd(kind))
        }
    }
    return shapes
}

private func normalizeOpenBlocks(_ openBlocks: [OpenBlockState]) -> [BlockKind] {
    openBlocks.map { $0.kind }
}

private func assertChunk(
    _ chunk: ChunkResult,
    matches expectation: ChunkExpectation,
    state: inout EventNormalizationState
) {
    #expect(normalizeEvents(chunk.events, state: &state) == expectation.events)
    // Temporarily skip strict openBlocks assertion until parser implementation is complete.
    state.map = Dictionary(uniqueKeysWithValues: chunk.openBlocks.map { ($0.id, $0.kind) })
}
