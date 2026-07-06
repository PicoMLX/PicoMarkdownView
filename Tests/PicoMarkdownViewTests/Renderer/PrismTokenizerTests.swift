#if canImport(JavaScriptCore)
import Testing
@testable import PicoMarkdownView

/// Exercises the real Prism bundle through JavaScriptCore. Apple platforms
/// only — the whole file compiles out where JavaScriptCore is unavailable.
@Suite
struct PrismTokenizerTests {
    @Test("Bundled grammars produce real highlighting and lossless round-trips", arguments: [
        ("basic", "10 PRINT \"HI\"\n20 GOTO 10"),
        ("pascal", "begin writeln('hi'); end."),
        ("c", "int main(void) { return 0; } // c"),
        ("cpp", "#include <vector>\nint main() { return 0; }"),
        ("python", "def f():\n    return 1  # c"),
        ("rust", "fn main() { let x = 1; }"),
        ("swift", "let x = \"hi\" // comment"),
        ("typescript", "const x: number = 1;"),
        ("vbnet", "Dim x As Integer = 1"),
        ("makefile", "all: foo\n\tgcc -o foo foo.c"),
        ("ini", "[section]\nkey=value"),
        ("diff", "--- a\n+++ b\n+add\n-del")
    ])
    func tokenizesBundledGrammars(language: String, code: String) async throws {
        let tokenizer = try #require(PrismTokenizer.shared)
        let tokens = await tokenizer.tokenize(code: code, language: language)
        #expect(Set(tokens.map(\.type)).count > 1, "expected real highlighting for \(language)")
        #expect(tokens.map(\.content).joined() == code, "flattening must not lose characters")
    }

    @Test("Normalized fence aliases reach a bundled grammar", arguments: [
        "C++", "objective-c", "golang", "Swift", "vb.net", "make", "pas", "qbasic"
    ])
    func normalizedAliasesTokenize(fenceInfo: String) async throws {
        let tokenizer = try #require(PrismTokenizer.shared)
        let language = try #require(PrismLanguageNormalizer.normalize(fenceInfo))
        let code = "x = 1"
        let tokens = await tokenizer.tokenize(code: code, language: language)
        #expect(tokens.map(\.content).joined() == code)
        // The grammar must exist: an unknown language yields exactly one plain token.
        #expect(tokens != [PrismToken(content: code, type: .plain)],
                "\(fenceInfo) → \(language) did not resolve to a bundled grammar")
    }

    @Test("Unknown languages fall back to a single plain token")
    func unknownLanguageFallsBackToPlain() async throws {
        let tokenizer = try #require(PrismTokenizer.shared)
        let code = "some text"
        let tokens = await tokenizer.tokenize(code: code, language: "not-a-language")
        #expect(tokens == [PrismToken(content: code, type: .plain)])
    }

    @Test("Grammar-specific types carry standardized aliases")
    func tokensCarryAliases() async throws {
        let tokenizer = try #require(PrismTokenizer.shared)
        let tokens = await tokenizer.tokenize(code: "[s]\nkey=value", language: "ini")
        #expect(tokens.contains { $0.alias == .attributeName },
                "INI keys should alias attr-name for theme fallback")
    }
}
#endif
