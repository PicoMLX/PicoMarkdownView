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
    public static let strikethrough = InlineStyle(rawValue: 1 << 4)
    public static let image = InlineStyle(rawValue: 1 << 5)
    public static let math = InlineStyle(rawValue: 1 << 6)    
}

public struct InlineRun: Sendable, Equatable {
    public var text: String
    public var style: InlineStyle
    public var linkURL: String?
    public var image: InlineImage?
    public var math: MathInlinePayload?

    public init(text: String,
                style: InlineStyle = [],
                linkURL: String? = nil,
                image: InlineImage? = nil,
                math: MathInlinePayload? = nil) {
        self.text = text
        self.style = style
        self.linkURL = linkURL
        self.image = image
        self.math = math
    }
}

public struct MathInlinePayload: Sendable, Equatable {
    public var tex: String
    public var display: Bool

    public init(tex: String, display: Bool) {
        self.tex = tex
        self.display = display
    }
}

public struct InlineImage: Sendable, Equatable {
    public var source: String
    public var title: String?

    public init(source: String, title: String? = nil) {
        self.source = source
        self.title = title
    }
}

public enum MarkdownMath {
    public static func isMathLanguage(_ language: String?) -> Bool {
        guard let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !lang.isEmpty else {
            return false
        }
        switch lang {
        case "math", "latex":
            return true
        default:
            return false
        }
    }
}

public struct TaskListState: Sendable, Equatable {
    public var checked: Bool

    public init(checked: Bool) {
        self.checked = checked
    }
}

public enum BlockKind: Sendable, Equatable {
    case paragraph
    case heading(level: Int)
    case listItem(ordered: Bool, index: Int?, task: TaskListState?)
    case blockquote
    case fencedCode(language: String?)
    case math(display: Bool)
    case table
    case unknown
}

public extension BlockKind {
    var isMathFence: Bool {
        if case let .fencedCode(language) = self {
            return MarkdownMath.isMathLanguage(language)
        }
        return false
    }
}

public enum TableAlignment: Sendable, Equatable {
    case left, center, right, none
}

public enum BlockEvent: Sendable, Equatable {
    case blockStart(id: BlockID, kind: BlockKind)
    case blockAppendInline(id: BlockID, runs: [InlineRun])
    case blockAppendFencedCode(id: BlockID, textChunk: String)
    case blockAppendMath(id: BlockID, textChunk: String)
    case tableHeaderCandidate(id: BlockID, cells: [InlineRun])
    case tableHeaderConfirmed(id: BlockID, alignments: [TableAlignment])
    case tableAppendRow(id: BlockID, cells: [[InlineRun]])
    case blockEnd(id: BlockID)
}

public struct OpenBlockState: Sendable, Equatable {
    public var id: BlockID
    public var kind: BlockKind
    public var parentID: BlockID?
    public var depth: Int

    public init(id: BlockID, kind: BlockKind, parentID: BlockID? = nil, depth: Int = 0) {
        self.id = id
        self.kind = kind
        self.parentID = parentID
        self.depth = depth
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

public protocol StreamingMarkdownTokenizer: Actor {
    func feed(_ chunk: String) -> ChunkResult
    func finish() -> ChunkResult
}

public actor MarkdownTokenizer: StreamingMarkdownTokenizer {
    private var parser: StreamingParser

    public init(maxLookBehind: Int? = nil) {
        parser = StreamingParser(maxLookBehind: maxLookBehind ?? StreamingParser.defaultMaxLookBehind)
    }

    public func feed(_ chunk: String) -> ChunkResult {
        parser.feed(chunk)
    }

    public func finish() -> ChunkResult {
        parser.finish()
    }
}
