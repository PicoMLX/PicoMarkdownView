import SwiftUI
import Observation

/// Explicit non-Markdown inputs eligible for an embedded presentation.
public enum PicoEmbeddedBlockSelector: Sendable, Hashable {
    case htmlBlock
    case fencedCode(language: String)

    func matches(_ kind: BlockKind) -> Bool {
        switch (self, kind) {
        case (.htmlBlock, .htmlBlock): return true
        case let (.fencedCode(expected), .fencedCode(actual)):
            let expected = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !expected.isEmpty, expected != "*", let actual else { return false }
            return actual.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expected
        default: return false
        }
    }
}

/// Source is immutable; layout follows the surrounding native text document.
@MainActor
@Observable
public final class PicoEmbeddedBlockContext {
    public let source: String
    public let kind: PicoEmbeddedBlockSelector
    public let language: String?
    public private(set) var availableWidth: CGFloat = 1
    public private(set) var isSelected = false
    public private(set) var bodyFontSize: CGFloat

#if os(macOS)
    package let loadingState: PicoEmbeddedLoadingState?

    init(source: String, kind: PicoEmbeddedBlockSelector, bodyFontSize: CGFloat,
         loadingState: PicoEmbeddedLoadingState? = nil) {
        self.loadingState = loadingState
        self.source = source
        self.kind = kind
        if case let .fencedCode(language) = kind { self.language = language }
        else { self.language = nil }
        self.bodyFontSize = bodyFontSize
    }
#else
    init(source: String, kind: PicoEmbeddedBlockSelector, bodyFontSize: CGFloat) {
        self.source = source
        self.kind = kind
        if case let .fencedCode(language) = kind { self.language = language }
        else { self.language = nil }
        self.bodyFontSize = bodyFontSize
    }
#endif

    func update(availableWidth: CGFloat, isSelected: Bool) {
        let width = availableWidth.isFinite ? max(1, availableWidth) : 1
        if abs(self.availableWidth - width) > 0.5 { self.availableWidth = width }
        if self.isSelected != isSelected { self.isSelected = isSelected }
    }

    func update(bodyFontSize: CGFloat) {
        if self.bodyFontSize != bodyFontSize { self.bodyFontSize = bodyFontSize }
    }
}

/// Opt-in presentation of closed HTML blocks or explicitly named code fences.
/// Registrations are considered in order; the first match owns the block.
/// The factory runs on the main actor on macOS only. Return nil to keep the
/// native source presentation. The core always owns Markdown copying.
public struct PicoEmbeddedBlockRenderer: Sendable {
    let identity = UUID()
    public let selectors: [PicoEmbeddedBlockSelector]
    /// Package adapters may reserve a source-backed row before the closed factory runs.
    package var showsLoadingPlaceholder = false
    let makeView: @MainActor @Sendable (PicoEmbeddedBlockContext) -> AnyView?

    public init(selectors: [PicoEmbeddedBlockSelector],
                makeView: @escaping @MainActor @Sendable (PicoEmbeddedBlockContext) -> AnyView?) {
        self.selectors = selectors
        self.makeView = makeView
    }

    func matches(_ kind: BlockKind) -> Bool { selectors.contains { $0.matches(kind) } }
}

struct RenderedEmbeddedBlock: Sendable, Equatable {
    let renderer: PicoEmbeddedBlockRenderer
    let source: String
    let kind: PicoEmbeddedBlockSelector
    let bodyFontSize: CGFloat
    var isClosed = true

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.renderer.identity == rhs.renderer.identity && lhs.source == rhs.source
            && lhs.kind == rhs.kind && lhs.bodyFontSize == rhs.bodyFontSize && lhs.isClosed == rhs.isClosed
    }

    /// Source export cannot be overridden by a presentation provider.
    var markdown: String {
        guard case let .fencedCode(language) = kind else { return source }
        let marker: Character = language.contains("`") ? "~" : "`"
        var longest = 0
        var run = 0
        for character in source {
            if character == marker { run += 1; longest = max(longest, run) }
            else { run = 0 }
        }
        let fence = String(repeating: String(marker), count: max(3, longest + 1))
        let body = source.isEmpty || source.hasSuffix("\n") ? source : source + "\n"
        return fence + language + "\n" + body + fence
    }
}
