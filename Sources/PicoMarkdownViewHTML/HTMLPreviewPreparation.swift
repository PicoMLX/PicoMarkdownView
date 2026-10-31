#if os(macOS)
import Foundation

/// One source-owned preparation, shared by successive native views of the same
/// attachment. Window detachment cancels presentation, not this reusable result.
@MainActor
final class HTMLPreviewPreparation {
    typealias Prepare = @Sendable (String) async throws -> HTMLPreparedContent

    let source: String
    private let prepare: Prepare
    private var task: Task<HTMLPreparedContent, any Error>?

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
        let task = Task { try await prepare(source) }
        self.task = task
        return task
    }

    isolated deinit { task?.cancel() }
}
#endif
