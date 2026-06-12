import Foundation

public struct MarkdownStreamingInput: Sendable {
    enum Payload {
        case replacement(String)
        case chunks([String])
        case stream
    }

    /// Identity used by `PicoMarkdownView`'s `.task(id:)` to decide when the
    /// consume task must restart.
    ///
    /// SwiftUI reconstructs view values (and therefore this input) on every
    /// parent body evaluation, so the id must be **deterministic for equal
    /// content**: `.text`/`.chunks` derive it from the payload, which makes a
    /// re-render with unchanged content a no-op instead of a full reparse (or,
    /// worse, a duplicate feed). A `.stream` factory closure has no comparable
    /// content, so it gets a unique id and `PicoMarkdownView` captures the
    /// first input per view identity to keep the id stable across re-renders.
    ///
    /// The hash is `Hasher`-based and therefore only stable within a process —
    /// that is all the id is used for.
    let id: String
    let payload: Payload
    let streamFactory: (@Sendable () async -> AsyncStream<String>)?

    private init(id: String, payload: Payload, streamFactory: (@Sendable () async -> AsyncStream<String>)? = nil) {
        self.id = id
        self.payload = payload
        self.streamFactory = streamFactory
    }

    public static func text(_ value: String) -> MarkdownStreamingInput {
        var hasher = Hasher()
        hasher.combine(value)
        return MarkdownStreamingInput(id: "text-\(value.count)-\(hasher.finalize())",
                                      payload: .replacement(value))
    }

    public static func chunks(_ values: [String]) -> MarkdownStreamingInput {
        var hasher = Hasher()
        hasher.combine(values.count)
        for value in values {
            hasher.combine(value)
        }
        return MarkdownStreamingInput(id: "chunks-\(values.count)-\(hasher.finalize())",
                                      payload: .chunks(values))
    }

    public static func stream(_ factory: @escaping @Sendable () async -> AsyncStream<String>) -> MarkdownStreamingInput {
        MarkdownStreamingInput(id: "stream-\(UUID().uuidString)", payload: .stream, streamFactory: factory)
    }

    var isStream: Bool {
        if case .stream = payload {
            return true
        }
        return false
    }
}
