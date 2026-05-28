import Foundation

// MARK: - Public Markdown Streaming API

public typealias BlockID = UInt64

public struct InlineStyle: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let bold = InlineStyle(rawValue: 1 << 0)
    public static let italic = InlineStyle(rawValue: 1 << 1)
    public static let code = InlineStyle(rawValue: 1 << 2)
    public static let link = InlineStyle(rawValue: 1 << 3)
    public static let strikethrough = InlineStyle(rawValue: 1 << 4)
    public static let image = InlineStyle(rawValue: 1 << 5)
    public static let math = InlineStyle(rawValue: 1 << 6)
    public static let keyboard = InlineStyle(rawValue: 1 << 7)
    public static let superscript = InlineStyle(rawValue: 1 << 8)
    public static let subscriptText = InlineStyle(rawValue: 1 << 9)
    public static let footnote = InlineStyle(rawValue: 1 << 10)
    public static let tag = InlineStyle(rawValue: 1 << 11)
}

public struct InlineRun: Sendable, Equatable {
    public var text: String
    public var style: InlineStyle
    public var linkURL: String?
    public var image: InlineImage?
    public var math: MathInlinePayload?
    public var tag: Tag?

    public init(text: String,
                style: InlineStyle = [],
                linkURL: String? = nil,
                image: InlineImage? = nil,
                math: MathInlinePayload? = nil,
                tag: Tag? = nil) {
        self.text = text
        self.style = style
        self.linkURL = linkURL
        self.image = image
        self.math = math
        self.tag = tag
    }

    /// Whether two runs can be merged into one by concatenating their ``text``
    /// while preserving every observable attribute. Centralised here so the
    /// tokenizer, assembler, and renderer share a single source of truth; if a
    /// new payload is added to ``InlineRun``, only this check needs to grow.
    ///
    /// Callers that also need to enforce line-break boundaries (e.g. don't
    /// merge across a hard line break) must apply that as a separate guard on
    /// top of this check.
    public func canCoalesce(with other: InlineRun) -> Bool {
        style == other.style
            && linkURL == other.linkURL
            && image == other.image
            && math == other.math
            && tag == other.tag
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

/// Payload describing a recognized inline tag (mention / hashtag / ticker /
/// custom prefix). Emitted on `InlineRun` when `style` contains `.tag`.
///
/// ## Character rules
/// The default tokenizer terminates a tag at:
///
/// - **Hard stop** — the tag ends *before* this character; the character
///   stays in the surrounding text. Set: any Unicode whitespace,
///   ``(`` ``)`` ``[`` ``]`` ``{`` ``}`` ``<`` ``>`` ``"`` ``'`` ``/`` ``\``
///   ``|`` `` ` `` ``*`` ``_`` ``~``, and the opening character of any other
///   registered ``TagPrefix``.
///
/// - **Trailing strip** — these may appear *mid*-tag but are stripped from
///   the trailing edge: ``.`` ``,`` ``:`` ``;`` ``!`` ``?``. So
///   ``@behlool!`` matches identifier ``"behlool"``; ``@behlool.doe``
///   matches identifier ``"behlool.doe"``.
///
/// Anything else (emoji, CJK, accented letters, digits, underscores, hyphens)
/// flows into the tag's identifier.
///
/// ## Markdown-link form
/// In addition to the bare form (``@behlool``), the parser also recognises
/// ``@[Display Text](identifier)`` — the same syntax as a markdown link with
/// a tag prefix glued to the front. This lets sources emit display names
/// with spaces, and decouples the rendered text from the lookup key:
///
/// ```
/// @[John Doe](u-2345)
/// ```
///
/// Emits:
/// ```
/// Tag(prefix: "@", identifier: "u-2345",
///     displayText: "@John Doe", rawText: "@[John Doe](u-2345)")
/// ```
public struct Tag: Sendable, Equatable {
    /// The prefix that opened this tag, e.g. ``"@"``, ``"#"``, ``"$"``.
    /// For paired delimiters (``[[wiki]]``) this is the opening pair, e.g. ``"[["``.
    public var prefix: String

    /// The bare identifier suitable for lookup — no leading prefix, no
    /// trailing punctuation. For ``@behlool!`` this is ``"behlool"``;
    /// for ``@[John Doe](u-2345)`` this is ``"u-2345"``.
    public var identifier: String

    /// What the user sees rendered, including the prefix. For ``@behlool``
    /// this is ``"@behlool"``; for ``@[John Doe](u-2345)`` this is ``"@John Doe"``.
    public var displayText: String

    /// The original matched substring, exactly as it appeared in the source
    /// (including the prefix and any bracket/paren syntax). Useful for
    /// diagnostics, copy, and round-tripping.
    public var rawText: String

    public init(prefix: String,
                identifier: String,
                displayText: String,
                rawText: String) {
        self.prefix = prefix
        self.identifier = identifier
        self.displayText = displayText
        self.rawText = rawText
    }
}

/// Declares a tag-opening delimiter the inline parser should recognise.
///
/// Single-char prefixes (``@``, ``#``, ``$``) are constructed with
/// ``init(opening:)``. Paired delimiters (``[[wiki]]``) are constructed
/// with ``paired(open:close:)``.
///
/// The defaults registered automatically by ``MarkdownTokenizer`` are
/// ``mention`` (``@``) and ``hashtag`` (``#``). ``ticker`` (``$``) is
/// **not** registered by default because it collides with the math
/// delimiter; opt in by passing it explicitly if your content does not
/// contain TeX.
public struct TagPrefix: Sendable, Equatable, Hashable {
    /// The opening delimiter (1+ characters).
    public let opening: String

    /// For paired delimiters, the closing delimiter. ``nil`` for single-
    /// or multi-char openings whose extent is determined by the
    /// character-rule terminator (whitespace, hard-stop, trailing-strip).
    public let closing: String?

    public init(opening: String, closing: String? = nil) {
        precondition(!opening.isEmpty,
                     "TagPrefix opening delimiter cannot be empty")
        if let closing {
            precondition(!closing.isEmpty,
                         "TagPrefix closing delimiter cannot be empty (use nil for single-char prefixes)")
        }
        self.opening = opening
        self.closing = closing
    }

    /// ``@`` user mentions.
    public static let mention = TagPrefix(opening: "@")

    /// ``#`` hashtags / topics.
    public static let hashtag = TagPrefix(opening: "#")

    /// ``$`` stock tickers. **Not in defaults** — registers a collision
    /// with TeX/KaTeX inline math (``$x = mc^2$``). Enable only when the
    /// content does not include math.
    public static let ticker = TagPrefix(opening: "$")

    /// Paired delimiter such as ``[[wiki-links]]``.
    public static func paired(open: String, close: String) -> TagPrefix {
        TagPrefix(opening: open, closing: close)
    }
}

extension TagPrefix {
    /// The default prefix set used when none is supplied: mention + hashtag.
    public static let defaults: Set<TagPrefix> = [.mention, .hashtag]
}

/// Characters that *terminate* a tag (the tag ends before this character;
/// the character itself stays in the surrounding text). Whitespace is also
/// a terminator but is handled via ``Character.isWhitespace`` rather than
/// the explicit set.
///
/// Exposed as `internal` so the renderer and tests can refer to a single
/// source of truth without copying the rule.
enum TagCharacterRules {
    /// Hard-stop characters — tag ends *before* this character.
    static let hardStop: Set<Character> = [
        "(", ")", "[", "]", "{", "}", "<", ">",
        "\"", "'",
        "/", "\\", "|",
        "*", "_", "~",
        "`"
    ]

    /// Trailing-strip characters — allowed mid-tag, stripped if they sit
    /// at the trailing edge of the matched identifier.
    static let trailingStrip: Set<Character> = [
        ".", ",", ":", ";", "!", "?"
    ]
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
    case footnoteDefinition(id: String, index: Int)
    case table
    case horizontalRule
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

    /// Create a tokenizer.
    ///
    /// - Parameters:
    ///   - maxLookBehind: Bounded look-behind window (default 1024 chars).
    ///   - tagPrefixes: Inline tag prefixes the parser should recognise.
    ///     Defaults to ``TagPrefix/defaults`` (mention + hashtag). Pass an
    ///     empty set to disable inline-tag recognition, or augment with
    ///     ``TagPrefix/ticker`` (``$``) or ``TagPrefix/paired(open:close:)``
    ///     for things like ``[[wiki-links]]``.
    public init(maxLookBehind: Int? = nil,
                tagPrefixes: Set<TagPrefix> = TagPrefix.defaults) {
        parser = StreamingParser(maxLookBehind: maxLookBehind ?? StreamingParser.defaultMaxLookBehind,
                                  tagPrefixes: tagPrefixes)
    }

    public func feed(_ chunk: String) -> ChunkResult {
        parser.feed(chunk)
    }

    public func finish() -> ChunkResult {
        parser.finish()
    }
}
