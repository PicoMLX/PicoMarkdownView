#if os(macOS)
import Foundation

/// An internal sleep seam keeps the one-shot reveal deterministic in tests.
struct HostedLoadingTiming: Sendable {
    let sleep: @Sendable (Duration) async throws -> Void

    static let continuous = HostedLoadingTiming { duration in
        try await Task.sleep(for: duration)
    }
}
#endif
