import Foundation
import Testing
@testable import PicoMarkdownView

@Suite
struct MarkdownAssemblerBenchmarks {
    @Test("Assembler sample1 benchmark", arguments: [128, 512, 1024])
    func assemblerSample1Benchmark(chunkSize: Int) async throws {
        guard ProcessInfo.processInfo.environment["RUN_BENCHMARKS"] == "1" else {
            return
        }

        let url = try #require(Bundle.module.url(forResource: "sample1", withExtension: "md"))
        let contents = try String(contentsOf: url, encoding: .utf8)

        try await runBenchmark(on: contents, chunkSize: chunkSize, iterations: 25)
    }

    private func runBenchmark(on text: String, chunkSize: Int, iterations: Int) async throws {
        var aggregate = Metrics()
        let clock = ContinuousClock()

        for iteration in 0..<iterations {
            let tokenizer = MarkdownTokenizer()
            let assembler = MarkdownAssembler()

            var index = text.startIndex
            while index < text.endIndex {
                let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
                let chunk = String(text[index..<end])
                let result = await tokenizer.feed(chunk)

                let applyStart = clock.now
                let diff = await assembler.apply(result)
                let elapsed = applyStart.duration(to: clock.now)

                aggregate.update(with: result, diff: diff, duration: elapsed, chunkBytes: chunk.utf8.count)
                index = end
            }

            let finalResult = await tokenizer.finish()
            if !finalResult.events.isEmpty || !finalResult.openBlocks.isEmpty {
                let applyStart = clock.now
                let diff = await assembler.apply(finalResult)
                let elapsed = applyStart.duration(to: clock.now)
                aggregate.update(with: finalResult, diff: diff, duration: elapsed, chunkBytes: 0)
            }

            aggregate.finishIteration(iteration: iteration)
        }

        aggregate.printReport(chunkSize: chunkSize, iterations: iterations)

        if let average = aggregate.averageDurationPerApply {
            #expect(average < Duration.milliseconds(10))
        }
        #expect(aggregate.totalEvents > 0)
        #expect(aggregate.maxBufferedBytes > 0)
    }
}

private struct Metrics {
    private(set) var totalEvents: Int = 0
    private(set) var totalDiffChanges: Int = 0
    private(set) var totalRunsAppended: Int = 0
    private(set) var totalCodeBytes: Int = 0
    private(set) var totalChunkBytes: Int = 0
    private(set) var totalDuration: Duration = .zero
    private(set) var applyCount: Int = 0
    private(set) var maxOpenBlocks: Int = 0
    private(set) var maxActiveBlocks: Int = 0
    private(set) var maxBufferedBytes: Int = 0
    private var activeOrder: [BlockID] = []
    private var activeBlocks: Set<BlockID> = []
    private var blockByteCounts: [BlockID: Int] = [:]
    private var totalBufferedBytes: Int = 0

    var averageDurationPerApply: Duration? {
        guard applyCount > 0 else { return nil }
        return totalDuration / applyCount
    }

    mutating func update(with result: ChunkResult, diff: AssemblerDiff, duration: Duration, chunkBytes: Int) {
        applyCount += 1
        totalDuration += duration
        totalEvents += result.events.count
        totalDiffChanges += diff.changes.count
        totalChunkBytes += chunkBytes
        maxOpenBlocks = max(maxOpenBlocks, result.openBlocks.count)

        for event in result.events {
            switch event {
            case .blockAppendInline(let id, let runs):
                addBytes(runs.reduce(into: 0) { $0 += $1.text.utf8.count }, to: id)
            case .blockAppendFencedCode(let id, let textChunk):
                addBytes(textChunk.utf8.count, to: id)
            case .tableHeaderCandidate(let id, let cells):
                let added = cells.reduce(into: 0) { total, cell in
                    total += cell.text.utf8.count
                }
                addBytes(added, to: id)
            case .tableAppendRow(let id, let cells):
                let added = cells.reduce(into: 0) { total, column in
                    for run in column {
                        total += run.text.utf8.count
                    }
                }
                addBytes(added, to: id)
            default:
                break
            }
        }

        for change in diff.changes {
            switch change {
            case .blockStarted(let id, _, let position):
                let insertIndex = min(position, activeOrder.count)
                activeOrder.insert(id, at: insertIndex)
                activeBlocks.insert(id)
                maxActiveBlocks = max(maxActiveBlocks, activeOrder.count)
            case .runsAppended(_, let added):
                totalRunsAppended += added
            case .codeAppended(_, let addedBytes):
                totalCodeBytes += addedBytes
            case .blocksDiscarded(let range):
                removeBlocks(in: range)
            default:
                break
            }
        }

        maxBufferedBytes = max(maxBufferedBytes, totalBufferedBytes)
    }

    mutating func finishIteration(iteration: Int) {
        // No-op hook for future per-iteration processing; retained for clarity.
        _ = iteration
    }

    mutating func addBytes(_ amount: Int, to id: BlockID) {
        guard amount > 0 else { return }
        blockByteCounts[id, default: 0] += amount
        totalBufferedBytes += amount
    }

    mutating func removeBlocks(in range: Range<Int>) {
        guard range.lowerBound < activeOrder.count else { return }
        let upper = min(range.upperBound, activeOrder.count)
        guard range.lowerBound < upper else { return }
        let removedIDs = Array(activeOrder[range.lowerBound..<upper])
        activeOrder.removeSubrange(range.lowerBound..<upper)
        for id in removedIDs {
            activeBlocks.remove(id)
            if let bytes = blockByteCounts.removeValue(forKey: id) {
                totalBufferedBytes -= bytes
            }
        }
        if totalBufferedBytes < 0 { totalBufferedBytes = 0 }
    }

    func printReport(chunkSize: Int, iterations: Int) {
        let avgDuration = averageDurationPerApply.map { format($0) } ?? "n/a"
        print("Assembler sample1 chunkSize=\(chunkSize) iterations=\(iterations) applies=\(applyCount) avg=\(avgDuration) totalEvents=\(totalEvents) maxBufferedBytes=\(maxBufferedBytes) maxOpenBlocks=\(maxOpenBlocks) maxActiveBlocks=\(maxActiveBlocks)")
    }

    private func format(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
        return String(format: "%.6f s", seconds)
    }
}
