#if os(macOS)
import Foundation
import Observation

/// One source-owned preparation, shared by successive native views of the same
/// attachment. Window detachment cancels presentation, not this reusable result.
@MainActor
@Observable
final class HTMLPreviewPreparation {
    typealias Prepare = @Sendable (String) async throws -> HTMLPreparedContent

    let source: String
    private let prepare: Prepare
    @ObservationIgnored private var task: Task<HTMLPreparedContent, any Error>?
    private(set) var preparedContent: HTMLPreparedContent?
    private(set) var measuredHeight: CGFloat?

    func retainMeasurement(_ height: CGFloat) {
        guard measuredHeight != height else { return }
        measuredHeight = height
    }

    init(source: String, prepare: @escaping Prepare = { source in
        try await HTMLPreviewPolicy.prepareOffMainActor(source: source)
    }) {
        self.source = source
        self.prepare = prepare
    }

    func resultTask() -> Task<HTMLPreparedContent, any Error> {
        if let task { return task }
        let source = source
        let prepare = prepare
        let task = Task { [weak self] in
            let content = try await prepare(source)
            self?.preparedContent = content
            return content
        }
        self.task = task
        return task
    }

    isolated deinit { task?.cancel() }
}
#endif
