import Foundation

@available(macOS 15, iOS 18, *)
struct BenchmarkClock {
    private let clock = ContinuousClock()

    func measure(_ block: () -> Void) -> Duration {
        clock.measure(block)
    }

    func measure(times: Int, _ block: () -> Void) -> Duration {
        var total: Duration = .zero
        for _ in 0..<times {
            total += measure(block)
        }
        return total
    }
}
