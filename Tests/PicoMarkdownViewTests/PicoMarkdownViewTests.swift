import Testing
@testable import PicoMarkdownView

@Test func example() {
    let renderer = StreamingMarkdownRenderer()
    renderer.appendMarkdown("Hello ")
    renderer.appendMarkdown("**World**")

    #expect(renderer.attributedText.string == "Hello World")
}

@Test func resetClearsContent() {
    let renderer = StreamingMarkdownRenderer()
    renderer.load(markdown: "Initial")
    renderer.load(markdown: "")

    #expect(renderer.attributedText.string.isEmpty)
}

@Test func rendersTablesUsingMonospacedLayout() {
    let markdown = """
    | size | material | color |
    | ---- | -------- | ----- |
    | 9    | leather  | brown |
    | 10   | canvas   | natural |
    """

    let renderer = StreamingMarkdownRenderer()
    renderer.appendMarkdown(markdown)

    let rendered = renderer.attributedText.string
    #expect(rendered.contains("| size | material |"))
    #expect(rendered.contains("| 9"))
}

@Test func rendererHandlesNonAppendGracefully() {
    let renderer = StreamingMarkdownRenderer()
    renderer.appendMarkdown("Hello World")
    renderer.load(markdown: "Hello")

    #expect(renderer.attributedText.string == "Hello")
}

@Test func boundaryDetectionPrefersBlankLines() {
    var buffer = StreamingTextBuffer()
    _ = buffer.append("Paragraph one.\n\n")
    let secondRange = buffer.append("Paragraph two.")

    let boundary = buffer.lastStableBoundary(before: secondRange.lowerBound)
    #expect(String(buffer.text[boundary...]) == "Paragraph two.")
}
