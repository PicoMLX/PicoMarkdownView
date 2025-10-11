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

    private func runBenchmark(on text: String, chunkSize: Int, iterations: Int) async throws {
        let clock = ContinuousClock()
        let start = clock.now

        for _ in 0..<iterations {
            let tokenizer = MarkdownTokenizer()
            var index = text.startIndex
            while index < text.endIndex {
                let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
                let chunk = String(text[index..<end])
                _ = await tokenizer.feed(chunk)
                index = end
            }
            _ = await tokenizer.finish()
        }

        let total = start.duration(to: clock.now)
        let average = total / iterations
        print("Tokenizer sample1 chunkSize=\(chunkSize) iterations=\(iterations) total=\(format(total)) average=\(format(average))")
    }

    private func format(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
        return String(format: "%.6f s", seconds)
    }
}
