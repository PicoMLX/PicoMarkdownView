import Foundation
import Testing
@testable import PicoMarkdownView

@Suite
struct MarkdownAssemblerTests {
    @Test("Paragraph runs coalesce and diffs emit")
    func paragraphCoalescing() async {
        let assembler = MarkdownAssembler()

        let firstEvents = ChunkResult(
            events: [
                .blockStart(id: 1, kind: .paragraph),
                .blockAppendInline(id: 1, runs: [InlineRun(text: "Hello ")])
            ],
            openBlocks: [OpenBlockState(id: 1, kind: .paragraph)]
        )

        let firstDiff = await assembler.apply(firstEvents)
        #expect(firstDiff.documentVersion == 1)
        #expect(firstDiff.changes == [
            .blockStarted(id: 1, kind: .paragraph, position: 0),
            .runsAppended(id: 1, added: 1)
        ])

        let secondEvents = ChunkResult(
            events: [
                .blockAppendInline(id: 1, runs: [InlineRun(text: "world")])
            ],
            openBlocks: [OpenBlockState(id: 1, kind: .paragraph)]
        )

        let secondDiff = await assembler.apply(secondEvents)
        #expect(secondDiff.documentVersion == 2)
        #expect(secondDiff.changes == [
            .runsAppended(id: 1, added: 1)
        ])

        let thirdEvents = ChunkResult(
            events: [
                .blockEnd(id: 1)
            ],
            openBlocks: []
        )

        let thirdDiff = await assembler.apply(thirdEvents)
        #expect(thirdDiff.documentVersion == 3)
        #expect(thirdDiff.changes == [
            .blockEnded(id: 1)
        ])

        let snapshot = await assembler.block(1)
        #expect(snapshot.inlineRuns == [InlineRun(text: "Hello world")])
        #expect(snapshot.isClosed)
    }

    @Test("Fenced code appends bytes and truncation respects limits")
    func fencedCodeAndTruncation() async {
        let assembler = MarkdownAssembler(config: AssemblerConfig(maxClosedBlocks: 1, maxBytesApprox: nil, coalescePlainRuns: true))

        let first = ChunkResult(
            events: [
                .blockStart(id: 10, kind: .fencedCode(language: "swift")),
                .blockAppendFencedCode(id: 10, textChunk: "print(1)\n"),
                .blockEnd(id: 10)
            ],
            openBlocks: []
        )

        let firstDiff = await assembler.apply(first)
        #expect(firstDiff.documentVersion == 1)
        #expect(firstDiff.changes == [
            .blockStarted(id: 10, kind: .fencedCode(language: "swift"), position: 0),
            .codeAppended(id: 10, addedBytes: 9),
            .blockEnded(id: 10)
        ])

        let second = ChunkResult(
            events: [
                .blockStart(id: 11, kind: .paragraph),
                .blockAppendInline(id: 11, runs: [InlineRun(text: "next")]),
                .blockEnd(id: 11)
            ],
            openBlocks: []
        )

        let secondDiff = await assembler.apply(second)
        #expect(secondDiff.documentVersion == 2)
        #expect(secondDiff.changes.contains(.blockStarted(id: 11, kind: .paragraph, position: 1)))
        #expect(secondDiff.changes.contains(.runsAppended(id: 11, added: 1)))
        #expect(secondDiff.changes.contains(.blockEnded(id: 11)))
        #expect(secondDiff.changes.contains(.blocksDiscarded(range: 0..<1)))

        let count = await assembler.blockCount()
        #expect(count == 1)
        #expect(await assembler.blockID(at: 0) == 11)
    }

    @Test("Multiple fence appends accumulate and report diffs")
    func fencedCodeMultipleAppends() async {
        let assembler = MarkdownAssembler()

        let initializer = ChunkResult(
            events: [
                .blockStart(id: 2, kind: .fencedCode(language: "swift")),
                .blockAppendFencedCode(id: 2, textChunk: "let a = 1\n")
            ],
            openBlocks: [OpenBlockState(id: 2, kind: .fencedCode(language: "swift"))]
        )

        let firstDiff = await assembler.apply(initializer)
        #expect(firstDiff.changes == [
            .blockStarted(id: 2, kind: .fencedCode(language: "swift"), position: 0),
            .codeAppended(id: 2, addedBytes: 10)
        ])

        let second = ChunkResult(
            events: [
                .blockAppendFencedCode(id: 2, textChunk: "print(a)\n")
            ],
            openBlocks: [OpenBlockState(id: 2, kind: .fencedCode(language: "swift"))]
        )

        let secondDiff = await assembler.apply(second)
        #expect(secondDiff.changes == [
            .codeAppended(id: 2, addedBytes: 9)
        ])

        let final = ChunkResult(
            events: [
                .blockEnd(id: 2)
            ],
            openBlocks: []
        )

        _ = await assembler.apply(final)

        let snapshot = await assembler.block(2)
        #expect(snapshot.codeText == "let a = 1\nprint(a)\n")
        #expect(snapshot.isClosed)
    }

    @Test("Table assembly confirms header and rows")
    func tableAssembly() async {
        let assembler = MarkdownAssembler()

        let first = ChunkResult(
            events: [
                .blockStart(id: 21, kind: .table),
                .tableHeaderCandidate(id: 21, cells: [InlineRun(text: "H1"), InlineRun(text: "H2")])
            ],
            openBlocks: [OpenBlockState(id: 21, kind: .table)]
        )

        let diff1 = await assembler.apply(first)
        #expect(diff1.changes == [
            .blockStarted(id: 21, kind: .table, position: 0)
        ])

        let second = ChunkResult(
            events: [
                .tableHeaderConfirmed(id: 21, alignments: [.left, .center])
            ],
            openBlocks: [OpenBlockState(id: 21, kind: .table)]
        )

        let diff2 = await assembler.apply(second)
        #expect(diff2.changes == [
            .tableHeaderConfirmed(id: 21)
        ])

        let third = ChunkResult(
            events: [
                .tableAppendRow(id: 21, cells: [[InlineRun(text: "a")], [InlineRun(text: "b")]])
            ],
            openBlocks: [OpenBlockState(id: 21, kind: .table)]
        )

        let diff3 = await assembler.apply(third)
        #expect(diff3.changes == [
            .tableRowAppended(id: 21, rowIndex: 0)
        ])

        let fourth = ChunkResult(
            events: [
                .blockEnd(id: 21)
            ],
            openBlocks: []
        )

        _ = await assembler.apply(fourth)

        let snapshot = await assembler.block(21)
        #expect(snapshot.table?.headerCells?.count == 2)
        #expect(snapshot.table?.rows.count == 1)
        #expect(snapshot.table?.alignments == [.left, .center])
        #expect(snapshot.table?.isHeaderConfirmed == true)
        #expect(snapshot.isClosed)
    }

    @Test("makeSnapshot mirrors block order")
    func snapshotOrder() async {
        let assembler = MarkdownAssembler()

        let chunk = ChunkResult(
            events: [
                .blockStart(id: 30, kind: .paragraph),
                .blockStart(id: 31, kind: .paragraph)
            ],
            openBlocks: [
                OpenBlockState(id: 30, kind: .paragraph),
                OpenBlockState(id: 31, kind: .paragraph)
            ]
        )

        _ = await assembler.apply(chunk)
        let snapshot = await assembler.makeSnapshot()
        #expect(snapshot.map { $0.id } == [30, 31])
    }

    @Test("Diff locality keeps unrelated blocks untouched")
    func diffLocality() async {
        let assembler = MarkdownAssembler()

        let start = ChunkResult(
            events: [
                .blockStart(id: 40, kind: .paragraph),
                .blockStart(id: 41, kind: .paragraph)
            ],
            openBlocks: [
                OpenBlockState(id: 40, kind: .paragraph),
                OpenBlockState(id: 41, kind: .paragraph)
            ]
        )

        let startDiff = await assembler.apply(start)
        #expect(startDiff.changes == [
            .blockStarted(id: 40, kind: .paragraph, position: 0),
            .blockStarted(id: 41, kind: .paragraph, position: 1)
        ])

        let appendFirst = ChunkResult(
            events: [
                .blockAppendInline(id: 40, runs: [InlineRun(text: "alpha")])
            ],
            openBlocks: [
                OpenBlockState(id: 40, kind: .paragraph),
                OpenBlockState(id: 41, kind: .paragraph)
            ]
        )

        let diffFirst = await assembler.apply(appendFirst)
        #expect(diffFirst.changes == [
            .runsAppended(id: 40, added: 1)
        ])

        let appendSecond = ChunkResult(
            events: [
                .blockAppendInline(id: 41, runs: [InlineRun(text: "beta")])
            ],
            openBlocks: [
                OpenBlockState(id: 40, kind: .paragraph),
                OpenBlockState(id: 41, kind: .paragraph)
            ]
        )

        let diffSecond = await assembler.apply(appendSecond)
        #expect(diffSecond.changes == [
            .runsAppended(id: 41, added: 1)
        ])

        #expect((await assembler.block(40)).inlineRuns == [InlineRun(text: "alpha")])
        #expect((await assembler.block(41)).inlineRuns == [InlineRun(text: "beta")])
    }

    @Test("Snapshot replay via diffs matches assembler snapshot")
    func snapshotReplayMatches() async {
        let assembler = MarkdownAssembler()

        let chunks: [ChunkResult] = [
            .init(
                events: [
                    .blockStart(id: 50, kind: .paragraph),
                    .blockAppendInline(id: 50, runs: [InlineRun(text: "Hello")])
                ],
                openBlocks: [OpenBlockState(id: 50, kind: .paragraph)]
            ),
            .init(
                events: [
                    .blockAppendInline(id: 50, runs: [InlineRun(text: " world")]),
                    .blockEnd(id: 50),
                    .blockStart(id: 51, kind: .fencedCode(language: "swift")),
                    .blockAppendFencedCode(id: 51, textChunk: "print(1)\n")
                ],
                openBlocks: [
                    OpenBlockState(id: 51, kind: .fencedCode(language: "swift"))
                ]
            ),
            .init(
                events: [
                    .blockAppendFencedCode(id: 51, textChunk: "print(2)\n"),
                    .blockStart(id: 52, kind: .table),
                    .tableHeaderCandidate(id: 52, cells: [InlineRun(text: "H")]),
                    .tableHeaderConfirmed(id: 52, alignments: [.center]),
                    .tableAppendRow(id: 52, cells: [[InlineRun(text: "V")]])
                ],
                openBlocks: [
                    OpenBlockState(id: 51, kind: .fencedCode(language: "swift")),
                    OpenBlockState(id: 52, kind: .table)
                ]
            ),
            .init(
                events: [
                    .blockEnd(id: 51),
                    .blockEnd(id: 52)
                ],
                openBlocks: []
            )
        ]

        var diffs: [AssemblerDiff] = []
        for chunk in chunks {
            diffs.append(await assembler.apply(chunk))
        }

        var replay: [BlockID: BlockSnapshot] = [:]
        var replayOrder: [BlockID] = []

        for diff in diffs {
            for change in diff.changes {
                switch change {
                case .blockStarted(let id, _, let position):
                    let snapshot = await assembler.block(id)
                    if position >= replayOrder.count {
                        replayOrder.append(id)
                    } else {
                        replayOrder.insert(id, at: position)
                    }
                    replay[id] = snapshot
                case .runsAppended(let id, _),
                     .codeAppended(let id, _),
                     .tableHeaderConfirmed(let id),
                     .tableRowAppended(let id, _),
                     .blockEnded(let id):
                    replay[id] = await assembler.block(id)
                case .blocksDiscarded(let range):
                    let removedIDs = Array(replayOrder[range])
                    replayOrder.removeSubrange(range)
                    for removed in removedIDs {
                        replay.removeValue(forKey: removed)
                    }
                }
            }
        }

        let finalSnapshot = await assembler.makeSnapshot()
        let reconstructed = replayOrder.compactMap { replay[$0] }
        #expect(reconstructed == finalSnapshot)
    }
}
