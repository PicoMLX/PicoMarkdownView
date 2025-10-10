import XCTest
@testable import PicoMarkdownView

@available(macOS 15, iOS 18, *)
final class StreamingRendererBenchmarks: XCTestCase {
    private lazy var sampleMarkdown: String = {
        guard let url = Bundle.module.url(forResource: "sample1", withExtension: "md") else {
            fatalError("Missing benchmark sample")
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    func testStreamingAppendBenchmark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BENCHMARKS"] == "1",
                           "Set BENCHMARKS=1 to run performance benchmarks")

        let chunkSize = 128
        let iterations = 100
        let chunks = makeChunks(of: sampleMarkdown, size: chunkSize)
        let clock = BenchmarkClock()

        let duration = clock.measure(times: iterations) {
            let renderer = StreamingMarkdownRenderer()
            chunks.forEach { chunk in
                _ = renderer.appendMarkdown(chunk)
            }
        }

        let average = duration / iterations
        let totalMilliseconds = duration.secondsValue * 1_000
        let averageMicroseconds = average.secondsValue * 1_000_000

        print("[Bench] streaming_append iterations=\(iterations) chunks=\(chunks.count) chunkSize=\(chunkSize) total_ms=\(String(format: "%.3f", totalMilliseconds)) avg_us=\(String(format: "%.3f", averageMicroseconds))")
    }

    private func makeChunks(of text: String, size: Int) -> [String] {
        var chunks: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[index..<end]))
            index = end
        }
        return chunks
    }
}

@available(macOS 15, iOS 18, *)
private extension Duration {
    var secondsValue: Double {
        let comps = components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1_000_000_000_000_000_000
    }
}
