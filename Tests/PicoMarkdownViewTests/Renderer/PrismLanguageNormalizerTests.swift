import Testing
@testable import PicoMarkdownView

@Suite
struct PrismLanguageNormalizerTests {
    @Test("Aliases and casing normalize to bundled grammar names", arguments: [
        ("swift", "swift"),
        ("Swift", "swift"),
        ("SWIFT", "swift"),
        ("c++", "cpp"),
        ("C++", "cpp"),
        ("c#", "csharp"),
        ("f#", "fsharp"),
        ("objective-c", "objc"),
        ("golang", "go"),
        ("node", "javascript"),
        ("shell-session", "bash"),
        ("zsh", "bash"),
        ("make", "makefile"),
        ("properties", "ini"),
        ("rs", "rust"),
        ("vb.net", "vbnet"),
        ("VB", "vbnet"),
        ("bat", "batch"),
        ("proto", "protobuf"),
        ("terraform", "hcl"),
        ("asm", "nasm"),
        ("arm", "armasm"),
        ("pas", "pascal"),
        ("Delphi", "pascal"),
        ("qbasic", "basic"),
        ("jsonc", "json"),
        ("postgres", "sql"),
        ("patch", "diff"),
        ("ps1", "powershell")
    ])
    func normalizesAliases(input: String, expected: String) {
        #expect(PrismLanguageNormalizer.normalize(input) == expected)
    }

    @Test("Only the first word of the info string is used", arguments: [
        ("swift title=example.swift", "swift"),
        ("js {1,3-4}", "js"),
        ("C++ linenums", "cpp"),
        ("  ruby  ", "ruby"),
        ("\tpython\t", "python")
    ])
    func usesFirstWord(input: String, expected: String) {
        #expect(PrismLanguageNormalizer.normalize(input) == expected)
    }

    @Test("Unknown languages pass through lowercased", arguments: [
        ("unknown-lang", "unknown-lang"),
        ("Fortran", "fortran")
    ])
    func passesThroughUnknown(input: String, expected: String) {
        #expect(PrismLanguageNormalizer.normalize(input) == expected)
    }

    @Test("Plain-text names disable highlighting", arguments: [
        "plaintext", "PLAINTEXT", "plain", "text", "TXT", "none", "nohighlight", "raw"
    ])
    func plainNamesReturnNil(input: String) {
        #expect(PrismLanguageNormalizer.normalize(input) == nil)
    }

    @Test("Nil, empty, and whitespace-only info strings return nil")
    func emptyInputsReturnNil() {
        #expect(PrismLanguageNormalizer.normalize(nil) == nil)
        #expect(PrismLanguageNormalizer.normalize("") == nil)
        #expect(PrismLanguageNormalizer.normalize("   ") == nil)
        #expect(PrismLanguageNormalizer.normalize("\t\n") == nil)
    }
}
