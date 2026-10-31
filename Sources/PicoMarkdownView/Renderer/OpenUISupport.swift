import Foundation

/// A JSON value received from an OpenUI action without converting values to strings.
public enum PicoOpenUIValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PicoOpenUIValue])
    case object([String: PicoOpenUIValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([PicoOpenUIValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: PicoOpenUIValue].self) { self = .object(value) }
        else {
            throw DecodingError.typeMismatch(Self.self, .init(codingPath: decoder.codingPath,
                debugDescription: "Expected a JSON value"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// The semantic event emitted by OpenUI's renderer.
///
/// The application decides whether an event continues a conversation, opens a
/// URL, or performs another action. PicoMarkdownView does not execute it.
public struct PicoOpenUIActionEvent: Codable, Sendable, Equatable {
    public let type: String
    public let params: [String: PicoOpenUIValue]
    public let humanFriendlyMessage: String
    public let formState: [String: PicoOpenUIValue]?
    public let formName: String?

    public init(type: String, params: [String: PicoOpenUIValue], humanFriendlyMessage: String,
                formState: [String: PicoOpenUIValue]? = nil, formName: String? = nil) {
        self.type = type
        self.params = params
        self.humanFriendlyMessage = humanFriendlyMessage
        self.formState = formState
        self.formName = formName
    }
}

struct RenderedOpenUIContent: Sendable, Equatable {
    let source: String
    let language: String?
    var fontSize: CGFloat = 16
}

extension MarkdownRenderTheme {
    /// Enables completed OpenUI fences as interactive child views on macOS.
    /// The iOS renderer retains its existing code-block presentation.
    public func withOpenUIRendering(_ enabled: Bool = true) -> MarkdownRenderTheme {
        MarkdownRenderTheme(bodyFont: bodyFont,
                            codeFont: codeFont,
                            blockquoteColor: blockquoteColor,
                            linkColor: linkColor,
                            headingFonts: headingFonts,
                            imageMaxWidth: imageMaxWidth,
                            codeBlockTheme: codeBlockTheme,
                            codeHighlighter: codeHighlighter,
                            mermaidRenderingMode: mermaidRenderingMode,
                            svgRenderingEnabled: svgRenderingEnabled,
                            openUIRenderingEnabled: enabled)
    }
}
