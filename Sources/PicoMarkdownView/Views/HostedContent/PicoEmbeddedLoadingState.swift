#if os(macOS)
import Foundation
import Observation

/// A source-owned loading deadline survives rendering, detachment and retries.
@MainActor
@Observable
package final class PicoEmbeddedLoadingState {
    package enum Activity: Sendable, Equatable { case receiving, paused, stopped }

    package static let delay: Duration = .milliseconds(350)
    package static let height: CGFloat = 48
    package private(set) var showsPlaceholder = false
    package private(set) var activity: Activity = .receiving
    package private(set) var isLoading = false

    @ObservationIgnored private let timing: PicoEmbeddedLoadingTiming
    @ObservationIgnored private var deadline: ContinuousClock.Instant?
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    package init(timing: PicoEmbeddedLoadingTiming = .continuous) {
        self.timing = timing
    }

    isolated deinit { loadingTask?.cancel() }

    package func startLoading() {
        guard !isLoading else { return }
        isLoading = true
        if deadline == nil { deadline = timing.now().advanced(by: Self.delay) }
        revealWhenDue()
    }

    package func finishLoading() {
        cancelReveal()
        isLoading = false
        showsPlaceholder = false
    }

    package func setActivity(_ activity: Activity) {
        guard self.activity != activity else { return }
        self.activity = activity
        if activity == .stopped, isLoading {
            cancelReveal()
            showsPlaceholder = true
        }
    }

    package func waitForLoadingDelay() async {
        await loadingTask?.value
    }

    private func revealWhenDue() {
        cancelReveal()
        guard let deadline else { return }
        if activity == .stopped || timing.now() >= deadline {
            showsPlaceholder = true
            return
        }
        let generation = generation
        let timing = timing
        loadingTask = Task { @MainActor [weak self] in
            defer {
                if self?.generation == generation { self?.loadingTask = nil }
            }
            do {
                // Compute the remainder when the task actually starts so a
                // busy main actor cannot extend the source's absolute delay.
                let remaining = timing.now().duration(to: deadline)
                if remaining > .zero { try await timing.sleep(remaining) }
            } catch { return }
            guard !Task.isCancelled, let self, self.generation == generation, self.isLoading else { return }
            self.showsPlaceholder = true
        }
    }

    private func cancelReveal() {
        generation &+= 1
        loadingTask?.cancel()
        loadingTask = nil
    }
}

/// Injectable time keeps loading lifecycle checks independent of wall clocks.
package struct PicoEmbeddedLoadingTiming: Sendable {
    package let now: @Sendable () -> ContinuousClock.Instant
    package let sleep: @Sendable (Duration) async throws -> Void

    package init(now: @escaping @Sendable () -> ContinuousClock.Instant,
                 sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    package static let continuous = Self(now: { .now }, sleep: { duration in
        try await Task.sleep(for: duration)
    })
}
#endif
