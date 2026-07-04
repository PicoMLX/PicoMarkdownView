import Testing
@testable import PicoMarkdownView

@Suite
struct CodeBlockThemingTests {
    /// Token types GitHub intentionally leaves in the plain foreground.
    private static let uncoloredByDesign: Set<PrismTokenType> = [
        .plain, .punctuation, .mark, .shortArgument,
        .interpolation, .interpolationPunctuation
    ]

    @Test("GitHub palette covers every predefined token type")
    func gitHubPaletteIsComplete() {
        let palette = CodeBlockTheme.gitHub().tokenColors
        let missing = PrismTokenType.allPredefined.filter { type in
            palette[type] == nil && !Self.uncoloredByDesign.contains(type)
        }
        #expect(missing.isEmpty,
                "Add palette entries (or allowlist) for: \(missing.map(\.rawValue))")
    }

    @Test("GitHub palette colors differ between light and dark")
    func gitHubPaletteIsAdaptive() {
        let theme = CodeBlockTheme.gitHub()
        #expect(theme.foregroundColor.light != theme.foregroundColor.dark)
        #expect(theme.backgroundColor.light != theme.backgroundColor.dark)
        let keyword = theme.tokenColors[.keyword]?.color
        #expect(keyword != nil && keyword?.light != keyword?.dark)
    }

    @Test("Presets keep distinct identities")
    func presetsAreDistinct() {
        #expect(CodeBlockTheme.gitHub() != CodeBlockTheme.prismDefault())
        #expect(CodeBlockTheme.gitHub() != CodeBlockTheme.monospaced())
        #expect(CodeBlockTheme.monospaced().tokenColors.isEmpty)
    }
}
