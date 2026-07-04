import Foundation

/// Maps a raw fence info string to the name of a grammar registered in the
/// bundled Prism build.
///
/// Markdown fence info strings arrive in many shapes — `Swift`, `c++`,
/// `objective-c`, `swift title=example.swift` — while Prism grammar lookup is
/// an exact, case-sensitive match. Normalization takes the first
/// whitespace-delimited word, lowercases it, and applies an alias table for
/// spellings Prism does not register itself.
///
/// Returns `nil` when the block should render as plain text (empty info
/// string or an explicit plain-text name). Unknown languages pass through
/// unchanged; Prism falls back to plain text for grammars it doesn't have.
enum PrismLanguageNormalizer {
    static func normalize(_ infoString: String?) -> String? {
        guard let infoString else { return nil }
        guard let firstWord = infoString
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
        else {
            return nil
        }

        let lowered = firstWord.lowercased()
        if plainTextNames.contains(lowered) {
            return nil
        }
        return aliases[lowered] ?? lowered
    }

    /// Info-string names that explicitly request no highlighting.
    static let plainTextNames: Set<String> = [
        "plaintext", "plain", "text", "txt", "none", "nohighlight", "raw"
    ]

    /// Fence spellings mapped to grammar names in the bundle. Aliases that
    /// Prism components register themselves (`py`, `rb`, `ts`, `yml`, `sh`,
    /// `kt`, `md`, …) are intentionally absent — they already resolve.
    static let aliases: [String: String] = [
        // C family
        "c++": "cpp",
        "cplusplus": "cpp",
        "cxx": "cpp",
        "c#": "csharp",
        "f#": "fsharp",
        "objective-c": "objc",
        "obj-c": "objc",

        // Scripting
        "golang": "go",
        "node": "javascript",
        "nodejs": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "python3": "python",
        "pl": "perl",
        "ex": "elixir",
        "exs": "elixir",
        "erl": "erlang",

        // Shells
        "shell-session": "bash",
        "shellscript": "bash",
        "console": "bash",
        "zsh": "bash",
        "fish": "bash",

        // Build & config
        "make": "makefile",
        "mk": "makefile",
        "gnumakefile": "makefile",
        "dosini": "ini",
        "cfg": "ini",
        "conf": "ini",
        "properties": "ini",
        "tf": "hcl",
        "terraform": "hcl",
        "proto": "protobuf",

        // Windows
        "ps": "powershell",
        "ps1": "powershell",
        "pwsh": "powershell",
        "bat": "batch",
        "cmd": "batch",
        "batchfile": "batch",

        // Classic languages
        "rs": "rust",
        "pas": "pascal",
        "delphi": "pascal",
        "objectpascal": "pascal",
        "object-pascal": "pascal",
        "qbasic": "basic",
        "vb": "vbnet",
        "vba": "vbnet",
        "vb.net": "vbnet",
        "visual-basic": "vbnet",

        // Assembly
        "asm": "nasm",
        "x86asm": "nasm",
        "assembly": "nasm",
        "arm": "armasm",
        "arm-asm": "armasm",

        // Data & query
        "jsonc": "json",
        "json5": "json",
        "gql": "graphql",
        "mysql": "sql",
        "postgres": "sql",
        "postgresql": "sql",
        "sqlite": "sql",

        // Misc
        "htm": "html",
        "patch": "diff",
        "jl": "julia",
        "wat": "wasm"
    ]
}
