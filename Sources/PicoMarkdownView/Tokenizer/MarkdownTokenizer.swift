import Foundation

// MARK: - Public Markdown Streaming API

public typealias BlockID = UInt64

public struct InlineStyle: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let bold = InlineStyle(rawValue: 1 << 0)
    public static let italic = InlineStyle(rawValue: 1 << 1)
    public static let code = InlineStyle(rawValue: 1 << 2)
    public static let link = InlineStyle(rawValue: 1 << 3)
}

public struct InlineRun: Sendable, Equatable {
    public var text: String
    public var style: InlineStyle
    public var linkURL: String?

    public init(text: String, style: InlineStyle = [], linkURL: String? = nil) {
        self.text = text
        self.style = style
        self.linkURL = linkURL
    }
}

public enum BlockKind: Sendable, Equatable {
    case paragraph
    case heading(level: Int)
    case listItem(ordered: Bool, index: Int?)
    case blockquote
    case fencedCode(language: String?)
    case table
    case unknown
}

public enum TableAlignment: Sendable, Equatable {
    case left, center, right, none
}

public enum BlockEvent: Sendable, Equatable {
    case blockStart(id: BlockID, kind: BlockKind)
    case blockAppendInline(id: BlockID, runs: [InlineRun])
    case blockAppendFencedCode(id: BlockID, textChunk: String)
    case tableHeaderCandidate(id: BlockID, cells: [InlineRun])
    case tableHeaderConfirmed(id: BlockID, alignments: [TableAlignment])
    case tableAppendRow(id: BlockID, cells: [[InlineRun]])
    case blockEnd(id: BlockID)
}

public struct OpenBlockState: Sendable, Equatable {
    public var id: BlockID
    public var kind: BlockKind

    public init(id: BlockID, kind: BlockKind) {
        self.id = id
        self.kind = kind
    }
}

public struct ChunkResult: Sendable, Equatable {
    public var events: [BlockEvent]
    public var openBlocks: [OpenBlockState]

    public init(events: [BlockEvent], openBlocks: [OpenBlockState]) {
        self.events = events
        self.openBlocks = openBlocks
    }
}

public protocol StreamingMarkdownTokenizer {
    mutating func feed(_ chunk: String) -> ChunkResult
    mutating func finish() -> ChunkResult
}

public actor MarkdownTokenizer: StreamingMarkdownTokenizer {
    private var parser = StreamingParser()

    public init() {}

    public func feed(_ chunk: String) -> ChunkResult {
        parser.feed(chunk)
    }

    public func finish() -> ChunkResult {
        parser.finish()
    }
}
