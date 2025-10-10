import Foundation
import Markdown

struct TextMutation {
    let range: NSRange
    let replacement: NSAttributedString
}

/// Translates streamed markdown chunks into attributed text while
/// only re-rendering the minimally necessary suffix of the document.
final class StreamingMarkdownRenderer {
    private var buffer = StreamingTextBuffer()
    private let storage = NSMutableAttributedString()
    private let markdownRenderer: MarkdownAttributedStringRenderer
    private let fallbackAttributes: [NSAttributedString.Key: Any]

    init(configuration: MarkdownRenderingConfiguration = .default()) {
        self.markdownRenderer = MarkdownAttributedStringRenderer(configuration: configuration)
        self.fallbackAttributes = [
            .font: configuration.baseFont
        ]
    }

    /// Appends a markdown chunk and returns the performed text mutation.
    @discardableResult
    func appendMarkdown(_ chunk: String) -> TextMutation {
        buffer.append(chunk)
        let previousLength = storage.length
        let replacement = parseMarkdown(buffer.text)
        storage.setAttributedString(replacement)
        return TextMutation(
            range: NSRange(location: 0, length: previousLength),
            replacement: replacement
        )
    }

    /// Resets the renderer with a fresh markdown document.
    @discardableResult
    func load(markdown text: String) -> TextMutation {
        buffer = StreamingTextBuffer()
        storage.setAttributedString(NSAttributedString())
        return appendMarkdown(text)
    }

    var attributedText: NSAttributedString {
        (storage.copy() as? NSAttributedString) ?? NSAttributedString()
    }

    private func parseMarkdown(_ text: String) -> NSAttributedString {
        let document = Document(parsing: text, options: [.parseBlockDirectives, .parseSymbolLinks])
        let rendered = markdownRenderer.render(document: document)
        if rendered.length == 0 && !text.isEmpty {
            return NSAttributedString(string: text, attributes: fallbackAttributes)
        }
        return rendered
    }
}
