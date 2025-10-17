import Foundation

public protocol CodeSyntaxHighlighter: Sendable {
    func highlight(_ code: String, language: String?, theme: CodeBlockTheme) -> AttributedString
}

public struct PlainCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    public init() {}

    public func highlight(_ code: String, language: String?, theme: CodeBlockTheme) -> AttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: theme.font,
            .foregroundColor: theme.foregroundColor
        ]
        let nsString = NSAttributedString(string: code, attributes: attributes)
        return AttributedString(nsString)
    }
}

public struct AnyCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    private let _highlight: @Sendable (_ code: String, _ language: String?, _ theme: CodeBlockTheme) -> AttributedString

    public init<H: CodeSyntaxHighlighter>(_ highlighter: H) {
        _highlight = highlighter.highlight
    }

    public func highlight(_ code: String, language: String?, theme: CodeBlockTheme) -> AttributedString {
        _highlight(code, language, theme)
    }
}
