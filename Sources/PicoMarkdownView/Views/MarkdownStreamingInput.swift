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
    /// content, so it gets a unique id; `PicoMarkdownView` substitutes a
    /// per-view-identity token as the task id for stream inputs so re-renders
    /// don't restart consumption.
    ///
    /// The hash is `Hasher`-based and therefore only stable within a process —
    /// that is all the id is used for.
    let id: String
    let payload: Payload
    let streamFactory: (@Sendable () async -> AsyncStream<String>)?
    /// Whether a `.stream` input's id was derived from a caller-provided
    /// identity (stable across re-renders) rather than minted per
    /// construction. `PicoMarkdownView` keys its consume task off `id`
    /// directly when this is true, so changing the caller's stream identity
    /// restarts consumption with the new factory.
    let hasStableStreamID: Bool

    private init(id: String,
                 payload: Payload,
                 streamFactory: (@Sendable () async -> AsyncStream<String>)? = nil,
                 hasStableStreamID: Bool = false) {
        self.id = id
        self.payload = payload
        self.streamFactory = streamFactory
        self.hasStableStreamID = hasStableStreamID
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

    /// - Parameter id: Optional caller-provided identity for the stream.
    ///   Provide one when the same view identity may receive different
    ///   streams over time (e.g. regenerating a response in place): changing
    ///   the identity restarts consumption with the new factory, while equal
    ///   identities survive re-renders without a restart. When omitted, the
    ///   stream is consumed once per view identity.
    public static func stream(_ factory: @escaping @Sendable () async -> AsyncStream<String>,
                              id: AnyHashable? = nil) -> MarkdownStreamingInput {
        if let id {
            var hasher = Hasher()
            hasher.combine(id)
            return MarkdownStreamingInput(id: "stream-client-\(hasher.finalize())",
                                          payload: .stream,
                                          streamFactory: factory,
                                          hasStableStreamID: true)
        }
        return MarkdownStreamingInput(id: "stream-\(UUID().uuidString)", payload: .stream, streamFactory: factory)
    }

    var isStream: Bool {
        if case .stream = payload {
            return true
        }
        return false
    }
}
