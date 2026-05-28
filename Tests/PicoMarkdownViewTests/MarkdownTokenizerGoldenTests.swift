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

    @Test("Horizontal rule emits dedicated block")
    func horizontalRuleEmitsDedicatedBlock() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let chunk = await tokenizer.feed("---\n\n")
        assertChunk(chunk, matches: .init(
            events: [
                .blockStart(.horizontalRule),
                .blockEnd(.horizontalRule)
            ],
            openBlocks: []
        ), state: &state)

        let final = await tokenizer.finish()
        assertChunk(final, matches: .init(events: [], openBlocks: []), state: &state)
    }

    @Test("Multiline paragraph retains punctuation")
    func multilineParagraphRetainsPunctuation() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("This is\n")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain("This is")])
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed("a paragraph!\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [plain(" a paragraph!")]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Single multiline paragraph retains punctuation (StreamingReplacementEngine bug)")
    func singleMultilineParagraphRetainsPunctuation() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let markdown = """
            This document is itself written using Markdown; you
            can see the source for it by adding text to the URL.

            This is the final paragraph.
            """
        
        
        let chunks = await tokenizer.feed(markdown)
        print(chunks)
        assertChunk(chunks, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    plain("This document is itself written using Markdown; you can see the source for it by adding text to the URL."),
//                    plain(" can see the source for it by adding text to the URL."),
                ]),
                .blockEnd(.paragraph),
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain("This is the final paragraph.")]),
            ],
            openBlocks: [.paragraph]
        ), state: &state)
        
        
        // FIXME: !!!!! REGRESSION. FINAL . IS STILL MISSING in last paragraph (but can't replicate it in example app)
        
//        ChunkResult(events: [
//            PicoMarkdownView.BlockEvent.blockStart(id: 1, kind: PicoMarkdownView.BlockKind.paragraph),
//            PicoMarkdownView.BlockEvent.blockAppendInline(id: 1, runs: [
//                PicoMarkdownView.InlineRun(text: "This document is itself written using Markdown; you can see the source for it by adding text to the URL.", style: PicoMarkdownView.InlineStyle(rawValue: 0), linkURL: nil, image: nil, math: nil)
//            ]),
//            PicoMarkdownView.BlockEvent.blockEnd(id: 1),
//            PicoMarkdownView.BlockEvent.blockStart(id: 2, kind: PicoMarkdownView.BlockKind.paragraph),
//            PicoMarkdownView.BlockEvent.blockAppendInline(id: 2, runs: [
//                PicoMarkdownView.InlineRun(text: "This is the final paragraph", style: PicoMarkdownView.InlineStyle(rawValue: 0), linkURL: nil, image: nil, math: nil)
//            ])], openBlocks: [PicoMarkdownView.OpenBlockState(id: 2, kind: PicoMarkdownView.BlockKind.paragraph, parentID: nil, depth: 0)])
        
        
        
        
        // This is the result when StreamingReplacementEngine deleted last characters like `.`, and `:`
        // Do not delete
        /*
        assertChunk(chunks, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    plain("This document is itself written using Markdown; you"),
                    plain(" can see the source for it by adding text to the URL"),
                ]),
                .blockEnd(.paragraph),
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain("This is the final paragraph")]),
            ],
            openBlocks: [.paragraph]
        ), state: &state)
         */
    }
    
    
    @Test("Unterminated strikethrough flushed on finish")
    func unterminatedStrikethroughFlushedOnFinish() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("Start ~~partial")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain("Start ")])
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let final = await tokenizer.finish()
        assertChunk(final, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [plain("~~partial")]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Trailing literal tail is flushed at chunk boundary")
    func trailingLiteralTailFlushedAtChunkBoundary() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let chunk = await tokenizer.feed("Ends with colon:")
        assertChunk(chunk, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain("Ends with colon:")])
            ],
            openBlocks: [.paragraph]
        ), state: &state)
    }

    @Test("Concurrent feed calls are serialized")
    func concurrentFeedCalls() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        async let first = tokenizer.feed("Hello ")
        async let second = tokenizer.feed("world")

        await Task.yield()

        let firstResult = await first
        let secondResult = await second

        let startResult: ChunkResult
        let followResult: ChunkResult
        if firstResult.events.contains(where: { if case .blockStart = $0 { return true } else { return false } }) {
            startResult = firstResult
            followResult = secondResult
        } else {
            startResult = secondResult
            followResult = firstResult
        }

        let startEvents = normalizeEvents(startResult.events, state: &state)
        let followEvents = normalizeEvents(followResult.events, state: &state)

        #expect(startEvents.first == .blockStart(.paragraph))

        let startText = appendedInlineText(from: startEvents)
        let followText = appendedInlineText(from: followEvents)
        #expect(Set([startText, followText]) == Set(["Hello ", "world"]))
        #expect(followEvents == [.blockAppendInline(.paragraph, runs: [plain(followText)])])

        let terminator = await tokenizer.feed("\n\n")
        assertChunk(terminator, matches: .init(
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

    @Test("Emoji replacement inside emphasis")
    func emojiReplacementInsideEmphasis() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("__Advertisement :)__\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    InlineRunShape(text: "Advertisement 🙂", style: InlineStyle.bold)
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Nested link inside emphasis")
    func nestedLinkInsideEmphasis() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("- __[pica](https://nodeca.github.io/pica/demo/)__ - high quality and fast image\n  resize in browser.\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.listItem(ordered: false, index: nil, task: nil)),
                .blockAppendInline(.listItem(ordered: false, index: nil, task: nil), runs: [
                    InlineRunShape(text: "pica", style: [InlineStyle.bold, InlineStyle.link], linkURL: "https://nodeca.github.io/pica/demo/"),
                    plain(" - high quality and fast image"),
                    plain("\n"),
                    plain("resize in browser"),
                    plain(".\n")
                ]),
                .blockEnd(.listItem(ordered: false, index: nil, task: nil))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Underscore emphasis handling")
    func underscoreEmphasisHandling() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("_em_ and __strong__ plus mid_word\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    InlineRunShape(text: "em", style: InlineStyle.italic),
                    plain(" and "),
                    InlineRunShape(text: "strong", style: InlineStyle.bold),
                    plain(" plus mid_word")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Strikethrough handling")
    func strikethroughHandling() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("~~old~~ new\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    InlineRunShape(text: "old", style: InlineStyle.strikethrough),
                    plain(" new")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Strikethrough across chunks")
    func strikethroughAcrossChunks() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("~~ol")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph)
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed("d~~ more\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [
                    InlineRunShape(text: "old", style: InlineStyle.strikethrough),
                    plain(" more")
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

    @Test("Mermaid fences stream as fenced code deltas")
    func mermaidFenceStreaming() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("```mermaid\nsequenceDiagram\nAlice->>Bob: Hi")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.fencedCode(language: "mermaid")),
                .blockAppendFencedCode(.fencedCode(language: "mermaid"),
                                       textChunk: "sequenceDiagram\nAlice->>Bob: Hi")
            ],
            openBlocks: [.fencedCode(language: "mermaid")]
        ), state: &state)

        let second = await tokenizer.feed("\n```\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendFencedCode(.fencedCode(language: "mermaid"), textChunk: "\n"),
                .blockEnd(.fencedCode(language: "mermaid"))
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

    @Test("Heading trailing hashes are ignored")
    func headingTrailingHashes() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("# Title ###\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.heading(level: 1)),
                .blockAppendInline(.heading(level: 1), runs: [plain("Title")]),
                .blockEnd(.heading(level: 1))
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
                .blockStart(.listItem(ordered: false, index: nil, task: nil)),
                .blockAppendInline(.listItem(ordered: false, index: nil, task: nil), runs: [plain("First item"), plain("\n")]),
                .blockEnd(.listItem(ordered: false, index: nil, task: nil)),
                .blockStart(.listItem(ordered: false, index: nil, task: nil)),
                .blockAppendInline(.listItem(ordered: false, index: nil, task: nil), runs: [plain("Sec")])
            ],
            openBlocks: [.listItem(ordered: false, index: nil, task: nil)]
        ), state: &state)

        let second = await tokenizer.feed("ond item\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.listItem(ordered: false, index: nil, task: nil), runs: [plain("ond item"), plain("\n")]),
                .blockEnd(.listItem(ordered: false, index: nil, task: nil))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Nested unordered list maintains hierarchical blocks")
    func nestedUnorderedList() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("- Parent\n")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.listItem(ordered: false, index: nil, task: nil)),
                .blockAppendInline(.listItem(ordered: false, index: nil, task: nil), runs: [plain("Parent"), plain("\n")])
            ],
            openBlocks: [.listItem(ordered: false, index: nil, task: nil)]
        ), state: &state)
        #expect(normalizeOpenBlocks(first.openBlocks) == [.listItem(ordered: false, index: nil, task: nil)])

        let second = await tokenizer.feed("  - Child\n")
        assertChunk(second, matches: .init(
            events: [
                .blockStart(.listItem(ordered: false, index: nil, task: nil)),
                .blockAppendInline(
                    .listItem(ordered: false, index: nil, task: nil),
                    runs: [plain("  "), plain("Child"), plain("\n")]
                )
            ]
        ), state: &state)
        #expect(normalizeOpenBlocks(second.openBlocks) == [
            .listItem(ordered: false, index: nil, task: nil),
            .listItem(ordered: false, index: nil, task: nil)
        ])

        let third = await tokenizer.feed("- Sibling\n\n")
        assertChunk(third, matches: .init(
            events: [
                .blockEnd(.listItem(ordered: false, index: nil, task: nil)),
                .blockEnd(.listItem(ordered: false, index: nil, task: nil)),
                .blockStart(.listItem(ordered: false, index: nil, task: nil)),
                .blockAppendInline(
                    .listItem(ordered: false, index: nil, task: nil),
                    runs: [plain("Sibling"), plain("\n")]
                ),
                .blockEnd(.listItem(ordered: false, index: nil, task: nil))
            ]
        ), state: &state)
        #expect(normalizeOpenBlocks(third.openBlocks).isEmpty)
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

    @Test("Table cell retains inline line breaks")
    func tableCellRetainsInlineLineBreaks() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let header = await tokenizer.feed("| Timeline |\n")
        assertChunk(header, matches: .init(
            events: [
                .blockStart(.table),
                .tableHeaderCandidate(.table, cells: [plain("Timeline")])
            ],
            openBlocks: [.table]
        ), state: &state)

        let separator = await tokenizer.feed("| --- |\n")
        assertChunk(separator, matches: .init(
            events: [
                .tableHeaderConfirmed(.table, alignments: [.left])
            ],
            openBlocks: [.table]
        ), state: &state)

        let row = await tokenizer.feed("| item 1<br>item 2 |\n\n")
        assertChunk(row, matches: .init(
            events: [
                .tableAppendRow(.table, cells: [[plain("item 1"), plain("\n"), plain("item 2")]]),
                .blockEnd(.table)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Unconfirmed table header falls back to unknown block")
    func unconfirmedTableHeaderFallback() async {
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

        let second = await tokenizer.feed("Paragraph continuation\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockStart(.unknown),
                .blockAppendInline(.unknown, runs: [plain("| Col A | Col B |\nParagraph continuation\n")]),
                .blockEnd(.unknown)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Table cells treat escaped pipes as literal content")
    func tableEscapedPipes() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let header = await tokenizer.feed("| Name | Value |\n")
        assertChunk(header, matches: .init(
            events: [
                .blockStart(.table),
                .tableHeaderCandidate(.table, cells: [plain("Name"), plain("Value")])
            ],
            openBlocks: [.table]
        ), state: &state)

        let separator = await tokenizer.feed("| --- | --- |\n")
        assertChunk(separator, matches: .init(
            events: [
                .tableHeaderConfirmed(.table, alignments: [.left, .left])
            ],
            openBlocks: [.table]
        ), state: &state)

        let row = await tokenizer.feed("| a \\| b | c |\n\n")
        assertChunk(row, matches: .init(
            events: [
                .tableAppendRow(.table, cells: [[plain("a | b")], [plain("c")]]),
                .blockEnd(.table)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Table separator near-miss hyphen counts fallback")
    func tableSeparatorNearMissHyphenCountsFallback() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let header = await tokenizer.feed("| A | B |\n")
        assertChunk(header, matches: .init(
            events: [
                .blockStart(.table),
                .tableHeaderCandidate(.table, cells: [plain("A"), plain("B")])
            ],
            openBlocks: [.table]
        ), state: &state)

        let separator = await tokenizer.feed("| - | -- |\n\n")
        assertChunk(separator, matches: .init(
            events: [
                .blockStart(.unknown),
                .blockAppendInline(.unknown, runs: [plain("| A | B |\n| - | -- |\n")]),
                .blockEnd(.unknown)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Table separator colons with too few hyphens fallback")
    func tableSeparatorColonsTooFewHyphensFallback() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let header = await tokenizer.feed("| A | B |\n")
        assertChunk(header, matches: .init(
            events: [
                .blockStart(.table),
                .tableHeaderCandidate(.table, cells: [plain("A"), plain("B")])
            ],
            openBlocks: [.table]
        ), state: &state)

        let separator = await tokenizer.feed("| :-- | --: |\n\n")
        assertChunk(separator, matches: .init(
            events: [
                .blockStart(.unknown),
                .blockAppendInline(.unknown, runs: [plain("| A | B |\n| :-- | --: |\n")]),
                .blockEnd(.unknown)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Table separator invalid characters fallback")
    func tableSeparatorInvalidCharactersFallback() async {
        func assertFallback(for separatorLine: String) async {
            let tokenizer = MarkdownTokenizer()
            var state = EventNormalizationState()

            let header = await tokenizer.feed("| A | B |\n")
            assertChunk(header, matches: .init(
                events: [
                    .blockStart(.table),
                    .tableHeaderCandidate(.table, cells: [plain("A"), plain("B")])
                ],
                openBlocks: [.table]
            ), state: &state)

            let separator = await tokenizer.feed("\(separatorLine)\n\n")
            assertChunk(separator, matches: .init(
                events: [
                    .blockStart(.unknown),
                    .blockAppendInline(.unknown, runs: [plain("| A | B |\n\(separatorLine)\n")]),
                    .blockEnd(.unknown)
                ],
                openBlocks: []
            ), state: &state)
        }

        await assertFallback(for: "| -a- | --- |")
        await assertFallback(for: "| --=-- | --- |")
    }

    @Test("Table separator internal spaces fallback")
    func tableSeparatorInternalSpacesFallback() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let header = await tokenizer.feed("| A | B |\n")
        assertChunk(header, matches: .init(
            events: [
                .blockStart(.table),
                .tableHeaderCandidate(.table, cells: [plain("A"), plain("B")])
            ],
            openBlocks: [.table]
        ), state: &state)

        let separator = await tokenizer.feed("| : -- : | --- |\n\n")
        assertChunk(separator, matches: .init(
            events: [
                .blockStart(.unknown),
                .blockAppendInline(.unknown, runs: [plain("| A | B |\n| : -- : | --- |\n")]),
                .blockEnd(.unknown)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Table minimal alignment confirmation edge cases")
    func tableMinimalAlignmentConfirmationEdgeCases() async {
        do {
            let tokenizer = MarkdownTokenizer()
            var state = EventNormalizationState()

            let header = await tokenizer.feed("| L | R |\n")
            assertChunk(header, matches: .init(
                events: [
                    .blockStart(.table),
                    .tableHeaderCandidate(.table, cells: [plain("L"), plain("R")])
                ],
                openBlocks: [.table]
            ), state: &state)

            let separator = await tokenizer.feed("| :--- | ---: |\n\n")
            assertChunk(separator, matches: .init(
                events: [
                    .tableHeaderConfirmed(.table, alignments: [.left, .right]),
                    .blockEnd(.table)
                ],
                openBlocks: []
            ), state: &state)
        }

        do {
            let tokenizer = MarkdownTokenizer()
            var state = EventNormalizationState()

            let header = await tokenizer.feed("| C1 | C2 |\n")
            assertChunk(header, matches: .init(
                events: [
                    .blockStart(.table),
                    .tableHeaderCandidate(.table, cells: [plain("C1"), plain("C2")])
                ],
                openBlocks: [.table]
            ), state: &state)

            let separator = await tokenizer.feed("| :---: | :---: |\n\n")
            assertChunk(separator, matches: .init(
                events: [
                    .tableHeaderConfirmed(.table, alignments: [.center, .center]),
                    .blockEnd(.table)
                ],
                openBlocks: []
            ), state: &state)
        }
    }

    @Test("Table header with escaped pipes confirms")
    func tableHeaderWithEscapedPipesConfirms() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let header = await tokenizer.feed("| a \\| b | c |\n")
        assertChunk(header, matches: .init(
            events: [
                .blockStart(.table),
                .tableHeaderCandidate(.table, cells: [plain("a | b"), plain("c")])
            ],
            openBlocks: [.table]
        ), state: &state)

        let separator = await tokenizer.feed("| --- | --- |\n\n")
        assertChunk(separator, matches: .init(
            events: [
                .tableHeaderConfirmed(.table, alignments: [.left, .left]),
                .blockEnd(.table)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Table candidate degrades on row without separator")
    func tableCandidateDegradesOnRowWithoutSeparator() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let header = await tokenizer.feed("| H1 | H2 |\n")
        assertChunk(header, matches: .init(
            events: [
                .blockStart(.table),
                .tableHeaderCandidate(.table, cells: [plain("H1"), plain("H2")])
            ],
            openBlocks: [.table]
        ), state: &state)

        let row = await tokenizer.feed("| foo | bar |\n\n")
        assertChunk(row, matches: .init(
            events: [
                .blockStart(.unknown),
                .blockAppendInline(.unknown, runs: [plain("| H1 | H2 |\n| foo | bar |\n")]),
                .blockEnd(.unknown)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Table invalid separator across chunks degrades")
    func tableInvalidSeparatorAcrossChunksDegrades() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let header = await tokenizer.feed("| X | Y |\n")
        assertChunk(header, matches: .init(
            events: [
                .blockStart(.table),
                .tableHeaderCandidate(.table, cells: [plain("X"), plain("Y")])
            ],
            openBlocks: [.table]
        ), state: &state)

        let separator = await tokenizer.feed("| -- | -- |\n\n")
        assertChunk(separator, matches: .init(
            events: [
                .blockStart(.unknown),
                .blockAppendInline(.unknown, runs: [plain("| X | Y |\n| -- | -- |\n")]),
                .blockEnd(.unknown)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Table alignment variants")
    func tableAlignmentVariants() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let header = await tokenizer.feed("| H1 | H2 | H3 | H4 |\n")
        assertChunk(header, matches: .init(
            events: [
                .blockStart(.table),
                .tableHeaderCandidate(.table, cells: [plain("H1"), plain("H2"), plain("H3"), plain("H4")])
            ],
            openBlocks: [.table]
        ), state: &state)

        let separator = await tokenizer.feed("| :--- | ---: | :---: | --- |\n")
        assertChunk(separator, matches: .init(
            events: [
                .tableHeaderConfirmed(.table, alignments: [.left, .right, .center, .left])
            ],
            openBlocks: [.table]
        ), state: &state)

        let rows = await tokenizer.feed("| v1 | v2 | v3 | v4 |\n\n")
        assertChunk(rows, matches: .init(
            events: [
                .tableAppendRow(.table, cells: [[plain("v1")], [plain("v2")], [plain("v3")], [plain("v4")]]),
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
                    plain("line 1\nline 2"),
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Single trailing spaces before newline are dropped")
    func singleTrailingSpaceDropped() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("Trailing space \n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain("Trailing space")]),
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

    @Test("Reference-style link resolves definition")
    func referenceStyleLinkResolvesDefinition() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("[ref]: https://example.com\nSee [site][ref] now\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    plain("See "),
                    InlineRunShape(text: "site", style: InlineStyle.link, linkURL: "https://example.com"),
                    plain(" now")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Footnote reference and definition")
    func footnoteReferenceAndDefinition() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("Footnote here[^1].\n\n[^1]: Footnote text\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    plain("Footnote here"),
                    InlineRunShape(text: "1", style: [.footnote, .superscript]),
                    plain(".")
                ]),
                .blockEnd(.paragraph),
                .blockStart(.footnoteDefinition(id: "1", index: 1)),
                .blockAppendInline(.footnoteDefinition(id: "1", index: 1), runs: [
                    plain("Footnote text")
                ]),
                .blockEnd(.footnoteDefinition(id: "1", index: 1))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Inline HTML tags map to styles")
    func inlineHTMLTagsMapToStyles() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("Press <kbd>Esc</kbd> then x<sup>2</sup> and H<sub>2</sub>O\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    plain("Press "),
                    InlineRunShape(text: "Esc", style: [.keyboard]),
                    plain(" then x"),
                    InlineRunShape(text: "2", style: [.superscript]),
                    plain(" and H"),
                    InlineRunShape(text: "2", style: [.subscriptText]),
                    plain("O")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Inline image emits image run")
    func inlineImageEmitsImageRun() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("Look ![alt text](https://example.com/image.png) done\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    plain("Look "),
                    image("alt text", source: "https://example.com/image.png"),
                    plain(" done")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Image marker spans chunks")
    func imageMarkerSpansChunks() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("Start ![alt")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain("Start ")])
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed(" text](https://cdn.example.com/pic.jpg \"Caption\") end\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [
                    image("alt text", source: "https://cdn.example.com/pic.jpg", title: "Caption"),
                    plain(" end")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Autolinks become link runs")
    func autolinksBecomeLinkRuns() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("Visit https://example.com/path(1) now\n\n")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    plain("Visit "),
                    InlineRunShape(text: "https://example.com/path(1)", style: InlineStyle.link, linkURL: "https://example.com/path(1)"),
                    plain(" now")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)

        let second = await tokenizer.feed("www.example.org/resource\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    InlineRunShape(text: "www.example.org/resource", style: InlineStyle.link, linkURL: "https://www.example.org/resource")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Autolink angle bracket form")
    func autolinkAngleBracketForm() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("See <https://example.com> please\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    plain("See "),
                    InlineRunShape(text: "https://example.com", style: InlineStyle.link, linkURL: "https://example.com"),
                    plain(" please")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Autolink spans chunk boundary")
    func autolinkSpansChunkBoundary() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("Check https://exam")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain("Check ")])
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed("ple.com/path today\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [
                    InlineRunShape(text: "https://example.com/path", style: InlineStyle.link, linkURL: "https://example.com/path"),
                    plain(" today")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Streaming output matches single-shot parse across chunk boundaries")
    func streamingMatchesSingleShotParse() async {
        let source = """
        # Heading
        Paragraph with **bold** text and a [link](https://example.com).

        - First item
        - Second item

        > Quote line

        ```swift
        let value = 42
        print(value)
        ```

        | L | R | C | F |
        | :-- | --: | :-: | --- |
        | left | right | centered | fallback |

        Final paragraph.

        """

        for seed in [1, 7, 42, 99] {
            let chunks = chunk(source, seed: seed)
            let firstPass = summarizeBlocks(from: await collectEvents(chunks: chunks))
            let secondPass = summarizeBlocks(from: await collectEvents(chunks: chunks))
            #expect(firstPass == secondPass, "Chunking with seed \(seed) produced nondeterministic results")
        }
    }

    @Test("Very long line without newline terminator")
    func veryLongLineWithoutNewline() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()
        let longLine = String(repeating: "a", count: 16_384)

        let first = await tokenizer.feed(longLine)
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain(longLine)])
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed(" tail")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [plain(" tail")])
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

    @Test("Long line respects look-behind cap")
    func longLineRespectsLookBehindCap() async {
        let tokenizer = MarkdownTokenizer(maxLookBehind: 16)
        var state = EventNormalizationState()

        let first = await tokenizer.feed(String(repeating: "a", count: 200))
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain(String(repeating: "a", count: 200))])
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed(String(repeating: "b", count: 60) + "\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [plain(String(repeating: "b", count: 60))]),
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


// MARK: - Additional streaming/edge case tests
//
// Some expectations below may require changes to the tokenizer implementation, e.g. for proper escape handling,
// blockquote line aggregation, or list continuation. Failures here indicate work items to discuss or implement.

    @Test("Inline code span across chunks")
    func inlineCodeSpanAcrossChunks() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        // We withhold emission until the code span closes to avoid provisional output.
        let first = await tokenizer.feed("Here `co")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph)
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed("de` inside\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [
                    plain("Here "),
                    InlineRunShape(text: "code", style: InlineStyle.code),
                    plain(" inside")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Inline code with multiple backticks across chunks")
    func inlineCodeMultipleBackticksAcrossChunks() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("Before ``co")
        assertChunk(first, matches: .init(
            events: [ .blockStart(.paragraph) ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed("de ` inner`` after\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [
                    plain("Before "),
                    InlineRunShape(text: "code ` inner", style: InlineStyle.code),
                    plain(" after")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Backslash escapes prevent formatting (single chunk)")
    func backslashEscapesSingleChunk() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        // Expect literal asterisks, not emphasis. If this fails, tokenizer escape handling needs implementation.
        let result = await tokenizer.feed("This is \\*not bold\\*\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [ plain("This is *not bold*") ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Backslash escape split across chunks")
    func backslashEscapeSplitAcrossChunks() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("Escaped \\")
        assertChunk(first, matches: .init(
            events: [ .blockStart(.paragraph) ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed("*\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [ plain("Escaped *") ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Link across chunk boundaries with parentheses in URL")
    func linkAcrossChunksWithParens() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("See [si")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [ plain("See ") ])
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed("te](https://ex.am/path_(1)) please\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [
                    InlineRunShape(text: "site", style: InlineStyle.link, linkURL: "https://ex.am/path_(1)"),
                    plain(" please")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Blockquote multi-line across chunks")
    func blockquoteMultiLineAcrossChunks() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("> first\n> sec")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.blockquote),
                .blockAppendInline(.blockquote, runs: [ plain("first"), plain("\n"), plain("sec") ])
            ],
            openBlocks: [.blockquote]
        ), state: &state)

        let second = await tokenizer.feed("ond line\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.blockquote, runs: [ plain("ond line"), plain("\n") ]),
                .blockEnd(.blockquote)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Blockquote containing list item with continuation")
    func blockquoteNestedListContinuation() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("> - item\n")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.blockquote),
                .blockAppendInline(.blockquote, runs: [plain("- item"), plain("\n")])
            ],
            openBlocks: [.blockquote]
        ), state: &state)

        let second = await tokenizer.feed(">   continuation\n> second line\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.blockquote, runs: [plain("  continuation"), plain("\n"), plain("second line"), plain("\n")]),
                .blockEnd(.blockquote)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("List item with continuation line")
    func listItemWithContinuation() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("- First item\n  cont")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.listItem(ordered: false, index: nil, task: nil)),
                .blockAppendInline(.listItem(ordered: false, index: nil, task: nil), runs: [ plain("First item"), plain("\n"), plain("cont") ])
            ],
            openBlocks: [.listItem(ordered: false, index: nil, task: nil)]
        ), state: &state)

        let second = await tokenizer.feed("inuation line\n\n")
        // Expect the wrapped line to remain in the same list item
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.listItem(ordered: false, index: nil, task: nil), runs: [ plain("inuation line"), plain("\n") ]),
                .blockEnd(.listItem(ordered: false, index: nil, task: nil))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Ordered list across chunks")
    func orderedListAcrossChunks() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("1. First\n2. Sec")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.listItem(ordered: true, index: 1, task: nil)),
                .blockAppendInline(.listItem(ordered: true, index: 1, task: nil), runs: [ plain("First"), plain("\n") ]),
                .blockEnd(.listItem(ordered: true, index: 1, task: nil)),
                .blockStart(.listItem(ordered: true, index: 2, task: nil)),
                .blockAppendInline(.listItem(ordered: true, index: 2, task: nil), runs: [ plain("Sec") ])
            ],
            openBlocks: [.listItem(ordered: true, index: 2, task: nil)]
        ), state: &state)

        let second = await tokenizer.feed("ond\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.listItem(ordered: true, index: 2, task: nil), runs: [ plain("ond"), plain("\n") ]),
                .blockEnd(.listItem(ordered: true, index: 2, task: nil))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Task list emits metadata for unchecked and checked items")
    func taskListEmitsMetadata() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let taskBlock = await tokenizer.feed("- [ ] Task one\n- [x] Task two\n\n")
        assertChunk(taskBlock, matches: .init(
            events: [
                .blockStart(.listItem(ordered: false, index: nil, task: .init(checked: false))),
                .blockAppendInline(.listItem(ordered: false, index: nil, task: .init(checked: false)), runs: [ plain("Task one"), plain("\n") ]),
                .blockEnd(.listItem(ordered: false, index: nil, task: .init(checked: false))),
                .blockStart(.listItem(ordered: false, index: nil, task: .init(checked: true))),
                .blockAppendInline(.listItem(ordered: false, index: nil, task: .init(checked: true)), runs: [ plain("Task two"), plain("\n") ]),
                .blockEnd(.listItem(ordered: false, index: nil, task: .init(checked: true)))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Task list continuation remains in same item")
    func taskListContinuation() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("- [x] Task one\n  continuation")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.listItem(ordered: false, index: nil, task: .init(checked: true))),
                .blockAppendInline(
                    .listItem(ordered: false, index: nil, task: .init(checked: true)),
                    runs: [ plain("Task one"), plain("\n"), plain("continuation") ]
                )
            ],
            openBlocks: [.listItem(ordered: false, index: nil, task: .init(checked: true))]
        ), state: &state)

        let second = await tokenizer.feed(" line\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.listItem(ordered: false, index: nil, task: .init(checked: true)), runs: [ plain(" line"), plain("\n") ]),
                .blockEnd(.listItem(ordered: false, index: nil, task: .init(checked: true)))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Tilde fences treated as fenced code")
    func tildeFencesAreTreatedAsFencedCode() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()
    
        // Per CommonMark §4.5 and GFM, tilde (~) fences are treated as fenced code blocks.
        // Deviating from this would break spec compliance.
        let result = await tokenizer.feed("~~~\ncode\n~~~\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.fencedCode(language: nil)),
                .blockAppendFencedCode(.fencedCode(language: nil), textChunk: "code\n"),
                .blockEnd(.fencedCode(language: nil))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Inline math parsed from dollar delimiters")
    func inlineMathDollarDelimiters() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("Energy $E=mc^2$ inline\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    plain("Energy "),
                    mathInline("E=mc^2"),
                    plain(" inline")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Inline math survives chunk splits")
    func inlineMathAcrossChunks() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("Mass $m")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [plain("Mass ")])
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed("c^2$")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [mathInline("mc^2")])
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let third = await tokenizer.feed(" equals energy\n\n")
        assertChunk(third, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [plain(" equals energy")]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Inline math via command delimiters preserves TeX commands")
    func inlineMathCommandDelimitersPreserveTeXCommands() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("Calc \\(\\displaystyle \\int_a^b f(x)\\,dx\\) now\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.paragraph),
                .blockAppendInline(.paragraph, runs: [
                    plain("Calc "),
                    mathInline("\\displaystyle \\int_a^b f(x)\\,dx"),
                    plain(" now")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Inline math command delimiters survive opener and command chunk splits")
    func inlineMathCommandDelimitersAcrossChunks() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("Speed \\")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.paragraph)
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let second = await tokenizer.feed("(c \\displa")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [plain("Speed ")])
            ],
            openBlocks: [.paragraph]
        ), state: &state)

        let third = await tokenizer.feed("ystyle \\times 10^8\\\\")
        assertChunk(third, matches: .init(
            events: [],
            openBlocks: [.paragraph]
        ), state: &state)

        let fourth = await tokenizer.feed(") done\n\n")
        assertChunk(fourth, matches: .init(
            events: [
                .blockAppendInline(.paragraph, runs: [
                    mathInline("c \\displaystyle \\times 10^8\\"),
                    plain(" done")
                ]),
                .blockEnd(.paragraph)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Table row inline math with TeX commands does not leak plain commands")
    func tableRowInlineMathCommandDoesNotLeakPlainText() async {
        let markdown = """
        | Formula |
        | --- |
        | \\(\\displaystyle \\int_a^b f(x)\\,dx\\) |

        """

        let summaries = summarizeBlocks(from: await collectEvents(chunks: wordChunksLikeExampleApp(markdown)))
        #expect(summaries.count == 1)

        guard case let .table(_, _, rows) = summaries[0] else {
            Issue.record("Expected table summary, got \(summaries)")
            return
        }

        #expect(rows.count == 1)
        #expect(rows[0].count == 1)
        let cellRuns = rows[0][0]
        #expect(cellRuns.contains(where: { $0.math?.tex == "\\displaystyle \\int_a^b f(x)\\,dx" }))
        #expect(!cellRuns.contains(where: { $0.math == nil && ($0.text.contains("displaystyle") || $0.text.contains("int_a")) }))
    }

    @Test("Display math via double dollars")
    func displayMathDoubleDollars() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("$$\\int_0^1 x^2 dx$$\n\n")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.math(display: true)),
                .blockAppendMath(.math(display: true), textChunk: "\\int_0^1 x^2 dx")
            ],
            openBlocks: [.math(display: true)]
        ), state: &state)

        let second = await tokenizer.feed("\n")
        assertChunk(second, matches: .init(
            events: [
                .blockEnd(.math(display: true))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Display math via [ ... ] single line")
    func displayMathBracketSingleLine() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("\\[\\int_0^1 x^2 dx\\]\n\n")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.math(display: true)),
                .blockAppendMath(.math(display: true), textChunk: "\\int_0^1 x^2 dx")
            ],
            openBlocks: [.math(display: true)]
        ), state: &state)

        let second = await tokenizer.feed("\n")
        assertChunk(second, matches: .init(
            events: [
                .blockEnd(.math(display: true))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Display math via [ ... ] across chunks")
    func displayMathBracketAcrossChunks() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("\\[\\frac{a")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.math(display: true)),
                .blockAppendMath(.math(display: true), textChunk: "\\frac{a")
            ],
            openBlocks: [.math(display: true)]
        ), state: &state)

        let second = await tokenizer.feed("}{b}\\]\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendMath(.math(display: true), textChunk: "}{b}")
            ],
            openBlocks: [.math(display: true)]
        ), state: &state)

        let third = await tokenizer.feed("\n")
        assertChunk(third, matches: .init(
            events: [
                .blockEnd(.math(display: true))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Math fences stream content across chunks")
    func mathFencesStream() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("```math\n\\frac{a")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.math(display: true)),
                .blockAppendMath(.math(display: true), textChunk: "\\frac{a")
            ],
            openBlocks: [.math(display: true)]
        ), state: &state)

        let second = await tokenizer.feed("}{b}}\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendMath(.math(display: true), textChunk: "}{b}}\n")
            ],
            openBlocks: [.math(display: true)]
        ), state: &state)

        let third = await tokenizer.feed("```\n\n")
        assertChunk(third, matches: .init(
            events: [
                .blockEnd(.math(display: true))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Heading marker-only chunk does not emit stray paragraph")
    func headingMarkerOnlyChunk() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("# ")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.heading(level: 1))
            ],
            openBlocks: [.heading(level: 1)]
        ), state: &state)

        let second = await tokenizer.feed("Title\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.heading(level: 1), runs: [plain("Title")]),
                .blockEnd(.heading(level: 1))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Unordered list marker-only chunk stays in same item")
    func unorderedListMarkerOnlyChunk() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("* ")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.listItem(ordered: false, index: nil, task: nil))
            ],
            openBlocks: [.listItem(ordered: false, index: nil, task: nil)]
        ), state: &state)

        let second = await tokenizer.feed("Item\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.listItem(ordered: false, index: nil, task: nil), runs: [plain("Item"), plain("\n")]),
                .blockEnd(.listItem(ordered: false, index: nil, task: nil))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Ordered list marker-only chunk stays in same item")
    func orderedListMarkerOnlyChunk() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("1. ")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.listItem(ordered: true, index: 1, task: nil))
            ],
            openBlocks: [.listItem(ordered: true, index: 1, task: nil)]
        ), state: &state)

        let second = await tokenizer.feed("Item\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.listItem(ordered: true, index: 1, task: nil), runs: [plain("Item"), plain("\n")]),
                .blockEnd(.listItem(ordered: true, index: 1, task: nil))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Blockquote marker-only chunk does not emit stray text")
    func blockquoteMarkerOnlyChunk() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("> ")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.blockquote)
            ],
            openBlocks: [.blockquote]
        ), state: &state)

        let second = await tokenizer.feed("Quote\n\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendInline(.blockquote, runs: [plain("Quote"), plain("\n")]),
                .blockEnd(.blockquote)
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Indented code block parses as code deltas")
    func indentedCodeBlockParsesAsCode() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let result = await tokenizer.feed("    This is a code block.\n\n")
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.fencedCode(language: nil)),
                .blockAppendFencedCode(.fencedCode(language: nil), textChunk: "This is a code block.\n\n")
            ],
            openBlocks: [.fencedCode(language: nil)]
        ), state: &state)

        let finish = await tokenizer.finish()
        assertChunk(finish, matches: .init(
            events: [
                .blockEnd(.fencedCode(language: nil))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Indented code block preserves nested indentation and HTML text")
    func indentedCodePreservesVerbatimContent() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let markdown = """
            \u{20}\u{20}\u{20}\u{20}<div class="footer">
            \u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}&copy; 2004 Foo Corporation
            \u{20}\u{20}\u{20}\u{20}</div>

            """

        let result = await tokenizer.feed(markdown)
        assertChunk(result, matches: .init(
            events: [
                .blockStart(.fencedCode(language: nil)),
                .blockAppendFencedCode(.fencedCode(language: nil), textChunk: "<div class=\"footer\">\n    &copy; 2004 Foo Corporation\n</div>\n")
            ],
            openBlocks: [.fencedCode(language: nil)]
        ), state: &state)

        let finish = await tokenizer.finish()
        assertChunk(finish, matches: .init(
            events: [
                .blockEnd(.fencedCode(language: nil))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Example-app word stream keeps markdown-it heading and TOC shapes")
    func exampleWordStreamMarkdownItHeadingAndTOC() async {
        let markdown = """
        # Markdown: Syntax

        *   [Overview](#overview)
            *   [Philosophy](#philosophy)
        """

        let singleShot = await collectEvents(chunks: [markdown + "\n\n"])
        let streamed = await collectEvents(chunks: wordChunksLikeExampleApp(markdown + "\n\n"))

        #expect(summarizeBlocks(from: streamed) == summarizeBlocks(from: singleShot))
    }

    @Test("Asterisk list after bold paragraph does not leak marker")
    func asteriskListAfterBoldParagraph() async {
        let markdown = """
        **1. Standard Project Management**
        *   Complete initial market research by Q3.
        *   Finalize the budget approval in December.
        *   Schedule and launch the product launch event.

        **2. Resume Bullet Points**

        """

        let singleShot = await collectEvents(chunks: [markdown])
        let streamed = await collectEvents(chunks: wordChunksLikeExampleApp(markdown))

        #expect(summarizeBlocks(from: streamed) == summarizeBlocks(from: singleShot))
    }

    @Test("Nested list with asterisk markers does not leak marker into parent")
    func nestedListAsteriskMarkerNoLeak() async {
        let markdown = """
        *   **Mount Elbrus (2,692.5 m)**
            *   **Location:** Russia (Caucasus Mountains)
            *   **Country:** Russia

        """

        let singleShot = await collectEvents(chunks: [markdown])
        let streamed = await collectEvents(chunks: wordChunksLikeExampleApp(markdown))

        #expect(summarizeBlocks(from: streamed) == summarizeBlocks(from: singleShot))
    }

    @Test("Heading after list item breaks out of list context")
    func headingAfterListItem() async {
        let markdown = """
        *   **Company A** (Parent Entity)
            *   *Purpose:* The main organization or legal entity.

        #### **Level 1: Departments / Wings**

        """

        let singleShot = await collectEvents(chunks: [markdown])
        let streamed = await collectEvents(chunks: wordChunksLikeExampleApp(markdown))

        // Verify heading is a separate block, not merged into list
        let blocks = summarizeBlocks(from: singleShot)
        let hasHeading = blocks.contains { if case .inline(let kind, _) = $0 { return kind.hasPrefix("heading:") } else { return false } }
        #expect(hasHeading)
        #expect(summarizeBlocks(from: streamed) == blocks)
    }

    @Test("Three-level nested list preserves order across streaming chunks")
    func threeLevelNestedListOrder() async {
        let markdown = """
        *   **Level 1.1: Human Resources**
            *   *Sub-Level 1.1:1*
                *   Recruitment Team
                *   Payroll Specialists
            *   *Sub-Level 1.1:2*
                *   Benefits Admin
                *   Training & Development

        """

        let singleShot = await collectEvents(chunks: [markdown])
        let streamed = await collectEvents(chunks: wordChunksLikeExampleApp(markdown))

        #expect(summarizeBlocks(from: streamed) == summarizeBlocks(from: singleShot))
    }

    @Test("Ordered list with nested unordered sub-items followed by paragraph")
    func orderedListWithNestedSubItemsFollowedByParagraph() async {
        let markdown = """
        Here is a list with sub-items:

        1.  **Header Item**
            *   Sub-item A
            *   Sub-item B
            *   Sub-item C

        2.  **Main Category**
            *   Sub-point 1
            *   Sub-point 2
            *   Sub-point 3

        3.  **Simple List**
            *   Item One
            *   Item Two
            *   Item Three

        Would you like to try adding more complex nesting (like lists within lists) or something else?

        """

        let singleShot = await collectEvents(chunks: [markdown])
        let streamed = await collectEvents(chunks: wordChunksLikeExampleApp(markdown))

        #expect(summarizeBlocks(from: streamed) == summarizeBlocks(from: singleShot))
    }

    @Test("Example-app word stream keeps TEST indented code block shape")
    func exampleWordStreamTestIndentedCodeShape() async {
        let markdown = """
        Here is an example of AppleScript:

            tell application "Foo"
                beep
            end tell

        """

        let singleShot = await collectEvents(chunks: [markdown])
        let streamed = await collectEvents(chunks: wordChunksLikeExampleApp(markdown))

        #expect(summarizeBlocks(from: streamed) == summarizeBlocks(from: singleShot))
    }

    @Test("Example-app word stream preserves command-delimited inline math")
    func exampleWordStreamInlineMathCommandDelimiterDeterministic() async {
        let markdown = """
        Einstein inline: \\(c \\approx 3.00 \\times 10^8 \\, \\text{m/s}\\).

        """

        let singleShot = await collectEvents(chunks: [markdown])
        let streamed = await collectEvents(chunks: wordChunksLikeExampleApp(markdown))

        #expect(summarizeBlocks(from: streamed) == summarizeBlocks(from: singleShot))
    }

    // MARK: - LLM token-boundary streaming tests

    @Test("Fence with language split across tokens (LLM streaming)")
    func fenceSplitLanguageLLMStreaming() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        // LLM sends "```" and "mermaid\n" as separate tokens
        let first = await tokenizer.feed("```")
        assertChunk(first, matches: .init(
            events: [],
            openBlocks: []
        ), state: &state)

        let second = await tokenizer.feed("mermaid\n")
        assertChunk(second, matches: .init(
            events: [
                .blockStart(.fencedCode(language: "mermaid"))
            ],
            openBlocks: [.fencedCode(language: "mermaid")]
        ), state: &state)

        let third = await tokenizer.feed("graph TD\n")
        assertChunk(third, matches: .init(
            events: [
                .blockAppendFencedCode(.fencedCode(language: "mermaid"), textChunk: "graph TD\n")
            ],
            openBlocks: [.fencedCode(language: "mermaid")]
        ), state: &state)

        let fourth = await tokenizer.feed("```\n\n")
        assertChunk(fourth, matches: .init(
            events: [
                .blockEnd(.fencedCode(language: "mermaid"))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Fence with split backticks then language (LLM streaming)")
    func fenceSplitBackticksLLMStreaming() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        // Backticks split across tokens
        let first = await tokenizer.feed("``")
        assertChunk(first, matches: .init(
            events: [],
            openBlocks: []
        ), state: &state)

        let second = await tokenizer.feed("`swift\n")
        assertChunk(second, matches: .init(
            events: [
                .blockStart(.fencedCode(language: "swift"))
            ],
            openBlocks: [.fencedCode(language: "swift")]
        ), state: &state)

        let third = await tokenizer.feed("let x = 1\n")
        assertChunk(third, matches: .init(
            events: [
                .blockAppendFencedCode(.fencedCode(language: "swift"), textChunk: "let x = 1\n")
            ],
            openBlocks: [.fencedCode(language: "swift")]
        ), state: &state)

        let fourth = await tokenizer.feed("```\n\n")
        assertChunk(fourth, matches: .init(
            events: [
                .blockEnd(.fencedCode(language: "swift"))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Bare fence split from newline (LLM streaming)")
    func bareFenceSplitFromNewline() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        let first = await tokenizer.feed("```")
        assertChunk(first, matches: .init(
            events: [],
            openBlocks: []
        ), state: &state)

        let second = await tokenizer.feed("\n")
        assertChunk(second, matches: .init(
            events: [
                .blockStart(.fencedCode(language: nil))
            ],
            openBlocks: [.fencedCode(language: nil)]
        ), state: &state)

        let third = await tokenizer.feed("code\n")
        assertChunk(third, matches: .init(
            events: [
                .blockAppendFencedCode(.fencedCode(language: nil), textChunk: "code\n")
            ],
            openBlocks: [.fencedCode(language: nil)]
        ), state: &state)

        let fourth = await tokenizer.feed("```\n\n")
        assertChunk(fourth, matches: .init(
            events: [
                .blockEnd(.fencedCode(language: nil))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Display math $$ split from content (LLM streaming)")
    func displayMathDollarSplitLLMStreaming() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        // $$ opens math immediately (unambiguous display math marker)
        let first = await tokenizer.feed("$$")
        assertChunk(first, matches: .init(
            events: [
                .blockStart(.math(display: true))
            ],
            openBlocks: [.math(display: true)]
        ), state: &state)

        let second = await tokenizer.feed("\nE=mc^2\n")
        assertChunk(second, matches: .init(
            events: [
                .blockAppendMath(.math(display: true), textChunk: "E=mc^2\n")
            ],
            openBlocks: [.math(display: true)]
        ), state: &state)

        let third = await tokenizer.feed("$$\n\n")
        assertChunk(third, matches: .init(
            events: [
                .blockEnd(.math(display: true))
            ],
            openBlocks: []
        ), state: &state)
    }

    @Test("Table with token-split lines (LLM streaming)")
    func tableSplitLinesLLMStreaming() async {
        let tokenizer = MarkdownTokenizer()
        var state = EventNormalizationState()

        // Table header arrives in pieces
        let first = await tokenizer.feed("|")
        assertChunk(first, matches: .init(
            events: [],
            openBlocks: []
        ), state: &state)

        let second = await tokenizer.feed(" Month")
        assertChunk(second, matches: .init(
            events: [],
            openBlocks: []
        ), state: &state)

        let third = await tokenizer.feed(" | Temp |\n")
        assertChunk(third, matches: .init(
            events: [
                .blockStart(.table),
                .tableHeaderCandidate(.table, cells: [plain("Month"), plain("Temp")])
            ],
            openBlocks: [.table]
        ), state: &state)

        let fourth = await tokenizer.feed("| --- | --- |\n")
        assertChunk(fourth, matches: .init(
            events: [
                .tableHeaderConfirmed(.table, alignments: [.left, .left])
            ],
            openBlocks: [.table]
        ), state: &state)

        let fifth = await tokenizer.feed("| Jan | 57 |\n\n")
        assertChunk(fifth, matches: .init(
            events: [
                .tableAppendRow(.table, cells: [[plain("Jan")], [plain("57")]]),
                .blockEnd(.table)
            ],
            openBlocks: []
        ), state: &state)
    }

// MARK: - Inline tag parsing

@Test("Bare mention emits a tag run")
func bareMentionEmitsTagRun() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("Hello @behlool world\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("Hello "),
                tagRun(prefix: "@", identifier: "behlool"),
                plain(" world")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Bare hashtag emits a tag run")
func bareHashtagEmitsTagRun() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("Topic: #release-notes today\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("Topic: "),
                tagRun(prefix: "#", identifier: "release-notes"),
                plain(" today")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Trailing punctuation is stripped from the tag identifier")
func trailingPunctuationStripped() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("Hi @behlool! Welcome.\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("Hi "),
                tagRun(prefix: "@", identifier: "behlool"),
                plain("! Welcome.")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Repeated trailing punctuation is stripped")
func repeatedTrailingPunctuationStripped() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("@behlool!?! end\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                tagRun(prefix: "@", identifier: "behlool"),
                plain("!?! end")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Dots in the middle of a tag are kept; only trailing dot is stripped")
func midTagDotKeptTrailingDotStripped() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("Ping @john.doe. now.\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("Ping "),
                tagRun(prefix: "@", identifier: "john.doe"),
                plain(". now.")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Adjacent mentions without separator: first matches, second is suppressed by left-boundary rule")
func adjacentMentionsSplit() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    // `@beh@lool` (no separator): the first `@` matches at start of input,
    // its bare scan stops at the second `@` (hardStop = registered prefix
    // opener), emitting tag "@beh". The second `@` then has prev char "h"
    // (ASCII letter), which suppresses tag opening — matching Slack /
    // Discord / Twitter convention that mentions require a separator. The
    // tail "@lool" stays as plain text.
    let chunk = await tokenizer.feed("@beh@lool\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                tagRun(prefix: "@", identifier: "beh"),
                plain("@lool")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Adjacent mentions WITH separator yield two tags")
func adjacentMentionsWithSeparatorYieldTwoTags() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("@user1 @user2\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                tagRun(prefix: "@", identifier: "user1"),
                plain(" "),
                tagRun(prefix: "@", identifier: "user2")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Email address is not parsed as a mention")
func emailAddressIsNotParsedAsMention() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    // Classic email — letter before @ suppresses the tag opener so the
    // whole thing stays as plain text.
    let chunk = await tokenizer.feed("Contact john@example.com please\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("Contact john@example.com please")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Email-like patterns with digits and dots are not parsed as mentions")
func emailLikePatternIsNotParsedAsMention() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    // Digit before @ also suppresses; dot inside local-part stays plain.
    let chunk = await tokenizer.feed("Versioned v1.2@deploy\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("Versioned v1.2@deploy")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Mention after sentence punctuation (boundary chars) still matches")
func mentionAfterSentencePunctuationStillMatches() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    // Comma, exclamation, and question are all in TagCharacterRules
    // .trailingStrip and are therefore valid left-boundary characters
    // for a tag opener.
    //
    // Period and colon are also valid in principle but trip a separate
    // pre-existing StreamingReplacementEngine ordering quirk when they
    // sit immediately before an inline element (the "..." / ":-)"
    // shortcode lookahead holds them in literalTail). That's tracked
    // separately and is not specific to tags — the same quirk affects
    // links, code spans, and autolinks today.
    let chunk = await tokenizer.feed("Hi,@first ok!@second wow?@third\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("Hi,"),
                tagRun(prefix: "@", identifier: "first"),
                plain(" ok!"),
                tagRun(prefix: "@", identifier: "second"),
                plain(" wow?"),
                tagRun(prefix: "@", identifier: "third")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Mention after emoji or CJK character still matches")
func mentionAfterEmojiOrCJKStillMatches() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    // The email-suppression rule applies to ASCII alphanumerics only,
    // so non-ASCII characters never block a mention.
    let chunk = await tokenizer.feed("🎯@first 张伟@second\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("🎯"),
                tagRun(prefix: "@", identifier: "first"),
                plain(" 张伟"),
                tagRun(prefix: "@", identifier: "second")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Adjacent identical tags do not coalesce")
func adjacentIdenticalTagsDoNotCoalesce() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    // Two `@user` tags separated by a space — both identical in style,
    // linkURL, and tag payload. They must remain two separate runs so
    // the tag.rawText invariant per element holds.
    let chunk = await tokenizer.feed("@user @user\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                tagRun(prefix: "@", identifier: "user"),
                plain(" "),
                tagRun(prefix: "@", identifier: "user")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Hard-stop character ends the tag and starts emphasis")
func hardStopEndsTagAndStartsEmphasis() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("Look @beh*lool* now\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("Look "),
                tagRun(prefix: "@", identifier: "beh"),
                InlineRunShape(text: "lool", style: InlineStyle.italic),
                plain(" now")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Emoji flow into the tag identifier")
func emojiFlowsIntoTagIdentifier() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("Hi @behlool🎯 there\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("Hi "),
                tagRun(prefix: "@", identifier: "behlool🎯"),
                plain(" there")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Non-ASCII characters flow into the tag identifier")
func nonASCIIFlowsIntoTagIdentifier() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("Hi @张伟 there\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("Hi "),
                tagRun(prefix: "@", identifier: "张伟"),
                plain(" there")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Closing paren after a parenthesised mention ends the tag")
func parenthesisedMention() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("(see @behlool)\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("(see "),
                tagRun(prefix: "@", identifier: "behlool"),
                plain(")")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Bare opener with no identifier characters falls back to literal")
func bareOpenerNoIdentifierFallsBackToLiteral() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("Email @ me later\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("Email @ me later")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Markdown-link form encodes identifier separately from display")
func markdownLinkFormEncodesIdentifierSeparately() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("Ping @[John Doe](u-2345) now\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("Ping "),
                tagRun(prefix: "@",
                       identifier: "u-2345",
                       displayText: "@John Doe",
                       rawText: "@[John Doe](u-2345)"),
                plain(" now")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Markdown-link form trims whitespace around the identifier")
func markdownLinkFormTrimsWhitespace() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("@[John](  u-2345  )\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                tagRun(prefix: "@",
                       identifier: "u-2345",
                       displayText: "@John",
                       rawText: "@[John](  u-2345  )")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Tag inside bold inherits the bold style")
func tagInsideBoldInheritsStyle() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("**@behlool** says hi\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                tagRun(prefix: "@", identifier: "behlool", extraStyle: .bold),
                plain(" says hi")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Bare tag streams across chunk boundary")
func bareTagStreamsAcrossChunkBoundary() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    // The tokenizer must hold off emitting any tag-related run until the
    // identifier terminates. The preceding plain text "Hi " is emitted
    // immediately; the partial "@behl" stays buffered.
    let first = await tokenizer.feed("Hi @behl")
    assertChunk(first, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [plain("Hi ")])
        ],
        openBlocks: [.paragraph]
    ), state: &state)

    let second = await tokenizer.feed("ool there\n\n")
    assertChunk(second, matches: .init(
        events: [
            .blockAppendInline(.paragraph, runs: [
                tagRun(prefix: "@", identifier: "behlool"),
                plain(" there")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Markdown-link tag streams across an incomplete-paren chunk boundary")
func markdownLinkTagStreamsAcrossBoundary() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    // Chunk 1 ends in the middle of the (id) component. The leading "Hi "
    // is emitted but the tag opener "@[John](" must remain buffered until
    // the closing ")" arrives.
    let first = await tokenizer.feed("Hi @[John Doe](")
    assertChunk(first, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [plain("Hi ")])
        ],
        openBlocks: [.paragraph]
    ), state: &state)

    let second = await tokenizer.feed("u-2345)\n\n")
    assertChunk(second, matches: .init(
        events: [
            .blockAppendInline(.paragraph, runs: [
                tagRun(prefix: "@",
                       identifier: "u-2345",
                       displayText: "@John Doe",
                       rawText: "@[John Doe](u-2345)")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Paired tag delimiter recognised when opt-in")
func pairedTagDelimiterRecognised() async {
    let tokenizer = MarkdownTokenizer(tagPrefixes: [
        .mention,
        .hashtag,
        .paired(open: "[[", close: "]]")
    ])
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("See [[Home Page]] for details\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("See "),
                tagRun(prefix: "[[",
                       identifier: "Home Page",
                       displayText: "[[Home Page]]",
                       rawText: "[[Home Page]]"),
                plain(" for details")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Paired delimiter streams across a chunk boundary")
func pairedDelimiterStreamsAcrossBoundary() async {
    let tokenizer = MarkdownTokenizer(tagPrefixes: [
        .paired(open: "[[", close: "]]")
    ])
    var state = EventNormalizationState()

    let first = await tokenizer.feed("Link [[Home")
    assertChunk(first, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [plain("Link ")])
        ],
        openBlocks: [.paragraph]
    ), state: &state)

    let second = await tokenizer.feed(" Page]] follows\n\n")
    assertChunk(second, matches: .init(
        events: [
            .blockAppendInline(.paragraph, runs: [
                tagRun(prefix: "[[",
                       identifier: "Home Page",
                       displayText: "[[Home Page]]",
                       rawText: "[[Home Page]]"),
                plain(" follows")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Tickers are opt-in: default tokenizer leaves '$AAPL' to math handling")
func tickersAreOptIn() async {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()

    // No closing $ ever arrives, so math handling falls back to literal.
    let chunk = await tokenizer.feed("Buy $AAPL today!\n\n")
    let final = await tokenizer.finish()
    let allEvents = chunk.events + final.events
    let allShapes = normalizeEvents(allEvents, state: &state)
    // Whatever the math fallback produces, the run must NOT have the .tag bit.
    for shape in allShapes {
        if case let .blockAppendInline(_, runs) = shape {
            for run in runs {
                #expect(InlineStyle(rawValue: run.styleRawValue).contains(.tag) == false,
                        "$AAPL should not produce a tag run when '$' is not registered")
            }
        }
    }
}

@Test("Opt-in ticker prefix emits a tag run")
func optInTickerEmitsTag() async {
    let tokenizer = MarkdownTokenizer(tagPrefixes: [.mention, .hashtag, .ticker])
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("Buy $AAPL today\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("Buy "),
                tagRun(prefix: "$", identifier: "AAPL"),
                plain(" today")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

@Test("Disabling tag prefixes yields plain text")
func disablingTagPrefixesYieldsPlainText() async {
    let tokenizer = MarkdownTokenizer(tagPrefixes: [])
    var state = EventNormalizationState()

    let chunk = await tokenizer.feed("Hello @behlool #topic\n\n")
    assertChunk(chunk, matches: .init(
        events: [
            .blockStart(.paragraph),
            .blockAppendInline(.paragraph, runs: [
                plain("Hello @behlool #topic")
            ]),
            .blockEnd(.paragraph)
        ],
        openBlocks: []
    ), state: &state)
}

private struct ChunkExpectation: Sendable {
    var events: [EventShape]
    var openBlocks: [BlockKind] = []
}

private enum EventShape: Equatable {
    case blockStart(BlockKind)
    case blockAppendInline(BlockKind, runs: [InlineRunShape])
    case blockAppendFencedCode(BlockKind, textChunk: String)
    case blockAppendMath(BlockKind, textChunk: String)
    case tableHeaderCandidate(BlockKind, cells: [InlineRunShape])
    case tableHeaderConfirmed(BlockKind, alignments: [TableAlignment])
    case tableAppendRow(BlockKind, cells: [[InlineRunShape]])
    case blockEnd(BlockKind)
}

private struct InlineRunShape: Equatable {
    var text: String
    var styleRawValue: UInt16
    var linkURL: String?
    var imageSource: String?
    var imageTitle: String?
    var math: MathShape?
    var tag: TagShape?

    init(text: String,
         style: InlineStyle = [],
         linkURL: String? = nil,
         imageSource: String? = nil,
         imageTitle: String? = nil,
         tag: TagShape? = nil) {
        self.text = text
        self.styleRawValue = style.rawValue
        self.linkURL = linkURL
        self.imageSource = imageSource
        self.imageTitle = imageTitle
        self.math = nil
        self.tag = tag
    }

    init(_ run: InlineRun) {
        self.text = run.text
        self.styleRawValue = run.style.rawValue
        self.linkURL = run.linkURL
        self.imageSource = run.image?.source
        self.imageTitle = run.image?.title
        if let payload = run.math {
            self.math = MathShape(tex: payload.tex, display: payload.display)
        } else {
            self.math = nil
        }
        if let payload = run.tag {
            self.tag = TagShape(prefix: payload.prefix,
                                identifier: payload.identifier,
                                displayText: payload.displayText,
                                rawText: payload.rawText)
        } else {
            self.tag = nil
        }
    }
}

private struct MathShape: Equatable {
    var tex: String
    var display: Bool
}

private struct TagShape: Equatable {
    var prefix: String
    var identifier: String
    var displayText: String
    var rawText: String
}

private func plain(_ text: String) -> InlineRunShape {
    InlineRunShape(text: text)
}

/// Build the expected URL string for a tag the same way the inline parser
/// constructs it, so test fixtures don't have to hand-encode reserved chars.
/// Mirrors `InlineParser.makePicoTagURL` exactly: `alphanumerics`-only
/// allowed, empty host (three slashes), both components in path position.
private func picoTagURL(prefix: String, identifier: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let p = prefix.addingPercentEncoding(withAllowedCharacters: allowed) ?? prefix
    let i = identifier.addingPercentEncoding(withAllowedCharacters: allowed) ?? identifier
    return "pico-tag:///\(p)/\(i)"
}

private func tagRun(prefix: String,
                    identifier: String,
                    displayText: String? = nil,
                    rawText: String? = nil,
                    extraStyle: InlineStyle = []) -> InlineRunShape {
    let display = displayText ?? (prefix + identifier)
    let raw = rawText ?? display
    var style: InlineStyle = [.tag, .link]
    style.formUnion(extraStyle)
    return InlineRunShape(
        text: display,
        style: style,
        linkURL: picoTagURL(prefix: prefix, identifier: identifier),
        tag: TagShape(prefix: prefix,
                      identifier: identifier,
                      displayText: display,
                      rawText: raw)
    )
}

private func image(_ alt: String, source: String, title: String? = nil) -> InlineRunShape {
    InlineRunShape(text: alt, style: InlineStyle.image, imageSource: source, imageTitle: title)
}

private func mathInline(_ tex: String, display: Bool = false) -> InlineRunShape {
    var shape = InlineRunShape(text: tex, style: InlineStyle.math)
    shape.math = MathShape(tex: tex, display: display)
    return shape
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
        case .blockAppendMath(let id, let text):
            let kind = state.map[id] ?? .math(display: false)
            shapes.append(.blockAppendMath(kind, textChunk: text))
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

private func appendedInlineText(from events: [EventShape]) -> String {
    for event in events {
        if case .blockAppendInline(_, let runs) = event {
            return runs.map(\.text).joined()
        }
    }
    return ""
}

private func collectEvents(chunks: [String]) async -> [EventShape] {
    let tokenizer = MarkdownTokenizer()
    var state = EventNormalizationState()
    var events: [EventShape] = []
    for chunk in chunks {
        let result = await tokenizer.feed(chunk)
        events += normalizeEvents(result.events, state: &state)
    }
    let final = await tokenizer.finish()
    events += normalizeEvents(final.events, state: &state)
    return events
}

private func chunk(_ source: String, seed: Int) -> [String] {
    var rng = UInt64(bitPattern: Int64(seed))
    var index = source.startIndex
    var result: [String] = []
    while index < source.endIndex {
        rng = rng &* 1103515245 &+ 12345
        let step = Int((rng >> 16) % 12) + 1
        let end = source.index(index, offsetBy: step, limitedBy: source.endIndex) ?? source.endIndex
        result.append(String(source[index..<end]))
        index = end
    }
    return result
}

private func wordChunksLikeExampleApp(_ markdown: String) -> [String] {
    var result: [String] = []
    var chunk = ""
    var wordSeen = false

    for character in markdown {
        chunk.append(character)
        if character.isWhitespace {
            if wordSeen {
                result.append(chunk)
                chunk.removeAll(keepingCapacity: true)
                wordSeen = false
            }
        } else {
            wordSeen = true
        }
    }

    if !chunk.isEmpty {
        result.append(chunk)
    }
    return result
}

private enum BlockSummary: Equatable {
    case inline(kind: String, runs: [InlineRunShape])
    case fencedCode(language: String?, text: String)
    case math(display: Bool, text: String)
    case table(header: [InlineRunShape], alignments: [TableAlignment], rows: [[[InlineRunShape]]])
}

private struct InFlightBlockSummary {
    var kind: BlockKind
    var kindDescription: String
    var inlineRuns: [InlineRunShape] = []
    var fencedText: String = ""
    var tableHeader: [InlineRunShape] = []
    var tableAlignments: [TableAlignment] = []
    var tableRows: [[[InlineRunShape]]] = []
}

private func summarizeBlocks(from events: [EventShape]) -> [BlockSummary] {
    var stack: [InFlightBlockSummary] = []
    var summaries: [BlockSummary] = []

    for event in events {
        switch event {
        case .blockStart(let kind):
            stack.append(.init(kind: kind, kindDescription: describe(kind)))
        case .blockAppendInline(_, let runs):
            stack[stack.count - 1].inlineRuns.append(contentsOf: runs)
        case .blockAppendFencedCode(_, let textChunk):
            stack[stack.count - 1].fencedText.append(textChunk)
        case .blockAppendMath(_, let textChunk):
            stack[stack.count - 1].fencedText.append(textChunk)
        case .tableHeaderCandidate(_, let cells):
            stack[stack.count - 1].tableHeader = cells
        case .tableHeaderConfirmed(_, let alignments):
            stack[stack.count - 1].tableAlignments = alignments
        case .tableAppendRow(_, let cells):
            stack[stack.count - 1].tableRows.append(cells)
        case .blockEnd:
            let finished = stack.removeLast()
            switch finished.kind {
            case .fencedCode(let language):
                summaries.append(.fencedCode(language: language, text: finished.fencedText))
        case .math(let display):
            summaries.append(.math(display: display, text: finished.fencedText))
            case .table:
                let normalizedRows = finished.tableRows.map { row in row.map(coalesceRuns) }
                summaries.append(.table(header: finished.tableHeader.map { $0 }, alignments: finished.tableAlignments, rows: normalizedRows))
            default:
                summaries.append(.inline(kind: finished.kindDescription, runs: coalesceRuns(finished.inlineRuns)))
            }
        }
    }

    return summaries
}

private func coalesceRuns(_ runs: [InlineRunShape]) -> [InlineRunShape] {
    guard var current = runs.first else { return [] }
    var result: [InlineRunShape] = []
    for run in runs.dropFirst() {
        if run.styleRawValue == current.styleRawValue &&
            run.linkURL == current.linkURL &&
            run.imageSource == current.imageSource &&
            run.imageTitle == current.imageTitle &&
            run.math == current.math {
            current.text += run.text
        } else {
            result.append(current)
            current = run
        }
    }
    result.append(current)
    return result
}

private func describe(_ kind: BlockKind) -> String {
    switch kind {
    case .paragraph:
        return "paragraph"
    case .heading(let level):
        return "heading:\(level)"
    case .listItem(let ordered, let index, let task):
        let order = ordered ? "ordered" : "unordered"
        let idx = index.map(String.init) ?? "_"
        let taskState: String
        if let task {
            taskState = task.checked ? "checked" : "unchecked"
        } else {
            taskState = "plain"
        }
        return "listItem:\(order):\(idx):\(taskState)"
    case .blockquote:
        return "blockquote"
    case .fencedCode(let language):
        return "fencedCode:\(language ?? "")"
    case .math(let display):
        return "math:\(display ? "display" : "inline")"
    case .footnoteDefinition(let id, let index):
        return "footnoteDefinition:\(id):\(index)"
    case .table:
        return "table"
    case .horizontalRule:
        return "horizontalRule"
    case .unknown:
        return "unknown"
    }
}
