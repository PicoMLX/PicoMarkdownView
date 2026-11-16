import Foundation
import Observation

/// App-owned metadata for a file referenced by a Markdown link.
///
/// The reference identifies the artifact; it is not a local file path. The host
/// owns retrieval, preview and saving. Retain this object and update its metadata
/// as the file becomes available without replacing the Markdown input.
@MainActor
@Observable
public final class PicoFileAttachment: Identifiable {
    public enum State: Sendable, Equatable {
        case creating
        case ready
    }

    public nonisolated let id: String
    public nonisolated let referenceURL: URL
    public var filename: String
    public var typeDescription: String?
    public var byteCount: Int?
    public var state: State

    public init(id: String, referenceURL: URL, filename: String,
                typeDescription: String? = nil, byteCount: Int? = nil,
                state: State = .creating) {
        self.id = id
        self.referenceURL = referenceURL
        self.filename = filename
        self.typeDescription = typeDescription
        self.byteCount = byteCount
        self.state = state
    }
}

/// A request from an explicit file-card control. The host decides how to act.
public struct PicoFileCardAction: Sendable {
    public enum Kind: Sendable, Equatable {
        case preview
        case download
    }

    public let kind: Kind
    public let file: PicoFileAttachment

    public init(kind: Kind, file: PicoFileAttachment) {
        self.kind = kind
        self.file = file
    }
}
