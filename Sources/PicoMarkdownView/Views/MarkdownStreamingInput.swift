import Foundation

public struct MarkdownStreamingInput: Sendable {
    enum Payload {
        case replacement(String)
        case chunks([String])
        case stream
    }

    let id: UUID
    let payload: Payload
    let streamFactory: (@Sendable () async -> AsyncStream<String>)?

    private init(id: UUID = UUID(), payload: Payload, streamFactory: (@Sendable () async -> AsyncStream<String>)? = nil) {
        self.id = id
        self.payload = payload
        self.streamFactory = streamFactory
    }

    // Use a stable ID for text replacements to prevent task restarts on text changes
    private static let stableTextID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public static func text(_ value: String) -> MarkdownStreamingInput {
        MarkdownStreamingInput(id: stableTextID, payload: .replacement(value))
    }

    public static func chunks(_ values: [String]) -> MarkdownStreamingInput {
        MarkdownStreamingInput(payload: .chunks(values))
    }

    public static func stream(_ factory: @escaping @Sendable () async -> AsyncStream<String>) -> MarkdownStreamingInput {
        MarkdownStreamingInput(payload: .stream, streamFactory: factory)
    }
}
