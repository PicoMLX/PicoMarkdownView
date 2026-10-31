import Foundation

/// The macOS preview deadline and renderer debounce share one clock. Kept
/// internal so cancellation tests can advance both without wall-clock races.
struct MermaidPreviewTiming: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (Duration) async throws -> Void

    static let continuous = MermaidPreviewTiming(now: { .now }, sleep: { duration in
        try await Task.sleep(for: duration)
    })
}
