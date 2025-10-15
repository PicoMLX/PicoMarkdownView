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

    @Test("Coalescing disabled keeps runs separate")
    func coalescingDisabledKeepsRunsSeparate() async {
        let assembler = MarkdownAssembler(config: AssemblerConfig(coalescePlainRuns: false))

        let start = await assembler.apply(.init(
            events: [
                .blockStart(id: 3, kind: .paragraph)
            ],
            openBlocks: [OpenBlockState(id: 3, kind: .paragraph)]
        ))
        #expect(start.documentVersion == 1)
        #expect(start.changes == [
            .blockStarted(id: 3, kind: .paragraph, position: 0)
        ])

        let firstAppend = await assembler.apply(.init(
            events: [
                .blockAppendInline(id: 3, runs: [InlineRun(text: "Hello ")])
            ],
            openBlocks: [OpenBlockState(id: 3, kind: .paragraph)]
        ))
        #expect(firstAppend.documentVersion == 2)
        #expect(firstAppend.changes == [
            .runsAppended(id: 3, added: 1)
        ])

        let secondAppend = await assembler.apply(.init(
            events: [
                .blockAppendInline(id: 3, runs: [InlineRun(text: "world")])
            ],
            openBlocks: [OpenBlockState(id: 3, kind: .paragraph)]
        ))
        #expect(secondAppend.documentVersion == 3)
        #expect(secondAppend.changes == [
            .runsAppended(id: 3, added: 1)
        ])

        let end = await assembler.apply(.init(
            events: [
                .blockEnd(id: 3)
            ],
            openBlocks: []
        ))
        #expect(end.documentVersion == 4)
        #expect(end.changes == [
            .blockEnded(id: 3)
        ])

        let snapshot = await assembler.block(3)
        #expect(snapshot.inlineRuns == [InlineRun(text: "Hello "), InlineRun(text: "world")])
    }

    @Test("Assembler records parent-child relationships for nested blocks")
    func assemblerHierarchy() async {
        let assembler = MarkdownAssembler()

        let parentStart = ChunkResult(
            events: [
                .blockStart(id: 100, kind: .listItem(ordered: false, index: nil, task: nil)),
                .blockAppendInline(id: 100, runs: [InlineRun(text: "Parent"), InlineRun(text: "\n")])
            ],
            openBlocks: [OpenBlockState(id: 100, kind: .listItem(ordered: false, index: nil, task: nil))]
        )

        _ = await assembler.apply(parentStart)

        let childStart = ChunkResult(
            events: [
                .blockStart(id: 101, kind: .listItem(ordered: false, index: nil, task: nil)),
                .blockAppendInline(id: 101, runs: [InlineRun(text: "Child"), InlineRun(text: "\n")])
            ],
            openBlocks: [
                OpenBlockState(id: 100, kind: .listItem(ordered: false, index: nil, task: nil)),
                OpenBlockState(id: 101, kind: .listItem(ordered: false, index: nil, task: nil))
            ]
        )

        _ = await assembler.apply(childStart)

        let childEnd = ChunkResult(
            events: [
                .blockEnd(id: 101)
            ],
            openBlocks: [OpenBlockState(id: 100, kind: .listItem(ordered: false, index: nil, task: nil))]
        )

        _ = await assembler.apply(childEnd)

        let parentEnd = ChunkResult(
            events: [
                .blockEnd(id: 100)
            ],
            openBlocks: []
        )

        _ = await assembler.apply(parentEnd)

        let snapshots = await assembler.makeSnapshot()
        guard let parent = snapshots.first(where: { $0.id == 100 }) else {
            Issue.record("Parent snapshot missing")
            return
        }
        guard let child = snapshots.first(where: { $0.id == 101 }) else {
            Issue.record("Child snapshot missing")
            return
        }

        #expect(parent.parentID == nil)
        #expect(parent.depth == 0)
        #expect(parent.childIDs == [101])
        #expect(child.parentID == 100)
        #expect(child.depth == 1)
        #expect(child.childIDs.isEmpty)
    }

    @Test("Style and link changes prevent coalescing")
    func noCoalesceAcrossStyles() async {
        let assembler = MarkdownAssembler()

        _ = await assembler.apply(.init(
            events: [
                .blockStart(id: 4, kind: .paragraph)
            ],
            openBlocks: [OpenBlockState(id: 4, kind: .paragraph)]
        ))

        _ = await assembler.apply(.init(
            events: [
                .blockAppendInline(id: 4, runs: [InlineRun(text: "a")])
            ],
            openBlocks: [OpenBlockState(id: 4, kind: .paragraph)]
        ))

        _ = await assembler.apply(.init(
            events: [
                .blockAppendInline(id: 4, runs: [InlineRun(text: "b", style: [.link], linkURL: "https://example.com")])
            ],
            openBlocks: [OpenBlockState(id: 4, kind: .paragraph)]
        ))

        _ = await assembler.apply(.init(
            events: [
                .blockAppendInline(id: 4, runs: [InlineRun(text: "c")])
            ],
            openBlocks: [OpenBlockState(id: 4, kind: .paragraph)]
        ))

        _ = await assembler.apply(.init(
            events: [
                .blockEnd(id: 4)
            ],
            openBlocks: []
        ))

        let snapshot = await assembler.block(4)
        #expect(snapshot.inlineRuns == [
            InlineRun(text: "a"),
            InlineRun(text: "b", style: [.link], linkURL: "https://example.com"),
            InlineRun(text: "c")
        ])
    }

    @Test("Fenced code addedBytes matches UTF-8 length")
    func utf8AddedBytesMatches() async {
        let assembler = MarkdownAssembler()
        let text = "print(\"👋\")\n"

        let diff = await assembler.apply(.init(
            events: [
                .blockStart(id: 5, kind: .fencedCode(language: "swift")),
                .blockAppendFencedCode(id: 5, textChunk: text)
            ],
            openBlocks: [OpenBlockState(id: 5, kind: .fencedCode(language: "swift"))]
        ))

        #expect(diff.documentVersion == 1)
        #expect(diff.changes == [
            .blockStarted(id: 5, kind: .fencedCode(language: "swift"), position: 0),
            .codeAppended(id: 5, addedBytes: text.utf8.count)
        ])

        _ = await assembler.apply(.init(
            events: [
                .blockEnd(id: 5)
            ],
            openBlocks: []
        ))

        let snapshot = await assembler.block(5)
        #expect(snapshot.codeText == text)
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

    @Test("Illegal events are ignored without advancing version")
    func illegalEventsAreIgnored() async {
        let assembler = MarkdownAssembler()

        let orphan = await assembler.apply(.init(
            events: [
                .blockAppendInline(id: 99, runs: [InlineRun(text: "orphan")])
            ],
            openBlocks: []
        ))

        #expect(orphan.changes.isEmpty)
        #expect(orphan.documentVersion == 0)
        #expect(await assembler.blockCount() == 0)

        let start = await assembler.apply(.init(
            events: [
                .blockStart(id: 100, kind: .paragraph)
            ],
            openBlocks: [OpenBlockState(id: 100, kind: .paragraph)]
        ))
        #expect(start.documentVersion == 1)

        let end = await assembler.apply(.init(
            events: [
                .blockEnd(id: 100)
            ],
            openBlocks: []
        ))
        #expect(end.documentVersion == 2)

        let afterClose = await assembler.apply(.init(
            events: [
                .blockAppendInline(id: 100, runs: [InlineRun(text: "ignored")])
            ],
            openBlocks: []
        ))

        #expect(afterClose.changes.isEmpty)
        #expect(afterClose.documentVersion == 2)
        #expect((await assembler.block(100)).inlineRuns == nil)
    }

    @Test("documentVersion advances only when state mutates")
    func documentVersionOnlyAdvancesOnMutation() async {
        let assembler = MarkdownAssembler()

        let empty = await assembler.apply(.init(events: [], openBlocks: []))
        #expect(empty.documentVersion == 0)
        #expect(empty.changes.isEmpty)

        let start = await assembler.apply(.init(
            events: [
                .blockStart(id: 200, kind: .paragraph)
            ],
            openBlocks: [OpenBlockState(id: 200, kind: .paragraph)]
        ))
        #expect(start.documentVersion == 1)

        let append = await assembler.apply(.init(
            events: [
                .blockAppendInline(id: 200, runs: [InlineRun(text: "text")])
            ],
            openBlocks: [OpenBlockState(id: 200, kind: .paragraph)]
        ))
        #expect(append.documentVersion == 2)

        let idle = await assembler.apply(.init(events: [], openBlocks: []))
        #expect(idle.documentVersion == 2)
        #expect(idle.changes.isEmpty)
    }

    @Test("Block start inserts at computed position")
    func blockStartInsertionPosition() async {
        let assembler = MarkdownAssembler()

        _ = await assembler.apply(.init(
            events: [
                .blockStart(id: 300, kind: .paragraph)
            ],
            openBlocks: [OpenBlockState(id: 300, kind: .paragraph)]
        ))

        _ = await assembler.apply(.init(
            events: [
                .blockStart(id: 301, kind: .paragraph)
            ],
            openBlocks: [
                OpenBlockState(id: 300, kind: .paragraph),
                OpenBlockState(id: 301, kind: .paragraph)
            ]
        ))

        let insert = await assembler.apply(.init(
            events: [
                .blockStart(id: 302, kind: .paragraph)
            ],
            openBlocks: [
                OpenBlockState(id: 300, kind: .paragraph),
                OpenBlockState(id: 302, kind: .paragraph),
                OpenBlockState(id: 301, kind: .paragraph)
            ]
        ))

        #expect(insert.changes == [
            .blockStarted(id: 302, kind: .paragraph, position: 1)
        ])

        let order = await assembler.makeSnapshot().map { $0.id }
        #expect(order == [300, 302, 301])
    }

    @Test("Truncation reports accurate ranges")
    func truncationReportingUsesAccurateRanges() async {
        let assembler = MarkdownAssembler(config: AssemblerConfig(maxClosedBlocks: 2))

        func emitBlock(_ id: BlockID) async -> AssemblerDiff {
            await assembler.apply(.init(
                events: [
                    .blockStart(id: id, kind: .paragraph),
                    .blockAppendInline(id: id, runs: [InlineRun(text: "x")]),
                    .blockEnd(id: id)
                ],
                openBlocks: []
            ))
        }

        let first = await emitBlock(400)
        #expect(!first.changes.contains { if case .blocksDiscarded = $0 { return true } else { return false } })

        let second = await emitBlock(401)
        #expect(!second.changes.contains { if case .blocksDiscarded = $0 { return true } else { return false } })

        let third = await emitBlock(402)
        #expect(third.changes.last == .blocksDiscarded(range: 0..<1))
        #expect(await assembler.makeSnapshot().map { $0.id } == [401, 402])

        let fourth = await emitBlock(403)
        #expect(fourth.changes.last == .blocksDiscarded(range: 0..<1))
        #expect(await assembler.makeSnapshot().map { $0.id } == [402, 403])
    }

    @Test("Table tracks multiple appended rows")
    func tableHandlesMultipleRows() async {
        let assembler = MarkdownAssembler()

        _ = await assembler.apply(.init(
            events: [
                .blockStart(id: 500, kind: .table),
                .tableHeaderCandidate(id: 500, cells: [InlineRun(text: "H1"), InlineRun(text: "H2")])
            ],
            openBlocks: [OpenBlockState(id: 500, kind: .table)]
        ))

        _ = await assembler.apply(.init(
            events: [
                .tableHeaderConfirmed(id: 500, alignments: [.left, .right])
            ],
            openBlocks: [OpenBlockState(id: 500, kind: .table)]
        ))

        let row1 = await assembler.apply(.init(
            events: [
                .tableAppendRow(id: 500, cells: [[InlineRun(text: "r1c1")], [InlineRun(text: "r1c2")]])
            ],
            openBlocks: [OpenBlockState(id: 500, kind: .table)]
        ))
        #expect(row1.changes == [
            .tableRowAppended(id: 500, rowIndex: 0)
        ])

        let row2 = await assembler.apply(.init(
            events: [
                .tableAppendRow(id: 500, cells: [[InlineRun(text: "r2c1")], [InlineRun(text: "r2c2")]])
            ],
            openBlocks: [OpenBlockState(id: 500, kind: .table)]
        ))
        #expect(row2.changes == [
            .tableRowAppended(id: 500, rowIndex: 1)
        ])

        let row3 = await assembler.apply(.init(
            events: [
                .tableAppendRow(id: 500, cells: [[InlineRun(text: "r3c1")], [InlineRun(text: "r3c2")]])
            ],
            openBlocks: [OpenBlockState(id: 500, kind: .table)]
        ))
        #expect(row3.changes == [
            .tableRowAppended(id: 500, rowIndex: 2)
        ])

        _ = await assembler.apply(.init(
            events: [
                .blockEnd(id: 500)
            ],
            openBlocks: []
        ))

        let snapshot = await assembler.block(500)
        #expect(snapshot.table?.rows.count == 3)
    }
}
