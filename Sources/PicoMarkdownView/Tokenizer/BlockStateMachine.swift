import Foundation

struct StreamingParser {
    mutating func feed(_ chunk: String) -> ChunkResult {
        ChunkResult(events: [], openBlocks: [])
    }

    mutating func finish() -> ChunkResult {
        ChunkResult(events: [], openBlocks: [])
    }
}
