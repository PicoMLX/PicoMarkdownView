#if os(macOS)
import Foundation

/// An internal sleep seam keeps the one-shot reveal deterministic in tests.
struct SVGLoadingTiming: Sendable {
    let sleep: @Sendable (Duration) async throws -> Void

    static let continuous = SVGLoadingTiming { duration in
        try await Task.sleep(for: duration)
    }
}
#endif
