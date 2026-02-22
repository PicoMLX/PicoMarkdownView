import Foundation
import Testing
@testable import PicoMarkdownView

@Suite
struct MarkdownTokenizerBenchmarks {
    @Test("Tokenizer sample1 benchmark", arguments: [128, 512, 1024])
    func tokenizerSample1Benchmark(chunkSize: Int) async throws {
        guard ProcessInfo.processInfo.environment["RUN_BENCHMARKS"] == "1" else {
            return
        }

        let url = try #require(Bundle.module.url(forResource: "sample1", withExtension: "md"))
        let contents = try String(contentsOf: url, encoding: .utf8)

        try await runBenchmark(on: contents, chunkSize: chunkSize, iterations: 50)
    }

    @Test("Tokenizer sample1 example word-stream benchmark")
    func tokenizerSample1ExampleWordStreamBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["RUN_BENCHMARKS"] == "1" else {
            return
        }

        let url = try #require(Bundle.module.url(forResource: "sample1", withExtension: "md"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        let chunks = wordChunksLikeExampleApp(contents)
        try await runBenchmark(onChunks: chunks, iterations: 50, label: "Tokenizer sample1 example-word-stream")
    }

    private func runBenchmark(on text: String, chunkSize: Int, iterations: Int) async throws {
        try await runBenchmark(onChunks: chunk(text, size: chunkSize),
                               iterations: iterations,
                               label: "Tokenizer sample1 chunkSize=\(chunkSize)")
    }

    private func runBenchmark(onChunks chunks: [String], iterations: Int, label: String) async throws {
        let clock = ContinuousClock()
        let start = clock.now

        for _ in 0..<iterations {
            let tokenizer = MarkdownTokenizer()
            for chunk in chunks {
                _ = await tokenizer.feed(chunk)
            }
            _ = await tokenizer.finish()
        }

        let total = start.duration(to: clock.now)
        let average = total / iterations
        print("\(label) iterations=\(iterations) total=\(format(total)) average=\(format(average)) chunks=\(chunks.count)")
    }

    private func format(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
        return String(format: "%.6f s", seconds)
    }

    private func chunk(_ text: String, size: Int) -> [String] {
        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[index..<end]))
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
}
