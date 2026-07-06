#if canImport(JavaScriptCore)
import Foundation
import Testing
@testable import PicoMarkdownView

/// End-to-end checks of `PrismCodeHighlighter` (normalization → tokenizer →
/// theme colors). Apple platforms only — compiles out without JavaScriptCore.
@Suite
struct PrismCodeHighlighterTests {
    @Test("Unknown languages render with a single uniform foreground color")
    func unknownLanguageIsUniform() async {
        let code = "let x = 1 // not actually highlighted"
        let attributed = await PrismCodeHighlighter()
            .highlight(code, language: "notareallanguage", theme: .prismDefault())
        let ns = NSAttributedString(attributed)
        #expect(ns.string == code)

        var colorRuns = 0
        ns.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: ns.length)) { _, _, _ in
            colorRuns += 1
        }
        #expect(colorRuns == 1)
    }

    @Test("Aliased fence info highlights and preserves the code verbatim", arguments: [
        "C++", "Swift", "golang", "pas"
    ])
    func aliasedLanguageHighlights(fenceInfo: String) async {
        let code = "x = 1 + 2"
        let attributed = await PrismCodeHighlighter()
            .highlight(code, language: fenceInfo, theme: .prismDefault())
        let ns = NSAttributedString(attributed)
        #expect(ns.string == code)

        var colorRuns = 0
        ns.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: ns.length)) { _, _, _ in
            colorRuns += 1
        }
        #expect(colorRuns > 1, "\(fenceInfo) should produce differentiated token colors")
    }
}
#endif
