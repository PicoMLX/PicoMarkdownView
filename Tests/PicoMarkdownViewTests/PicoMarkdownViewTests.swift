import Testing
@testable import PicoMarkdownView

@Test func example() async throws {
    let stream = await MainActor.run { PicoMarkdownStream() }
    await MainActor.run {
        stream.append(markdown: "Hello ")
        stream.append(markdown: "**World**")
    }

    let rendered = await MainActor.run { stream.renderedText.string }
    #expect(rendered == "Hello World")
}

@Test func resetClearsContent() async throws {
    let stream = await MainActor.run { PicoMarkdownStream(initialText: "Initial") }
    await MainActor.run {
        stream.reset(markdown: "")
    }

    let rendered = await MainActor.run { stream.renderedText.string }
    #expect(rendered.isEmpty)
}

@Test func rendersTablesUsingMonospacedLayout() async throws {
    let markdown = """
    | size | material | color |
    | ---- | -------- | ----- |
    | 9    | leather  | brown |
    | 10   | canvas   | natural |
    """

    let stream = await MainActor.run { PicoMarkdownStream() }
    await MainActor.run {
        stream.append(markdown: markdown)
    }

    let rendered = await MainActor.run { stream.renderedText.string }
    #expect(rendered.contains("| size | material |"))
    #expect(rendered.contains("| 9"))
}

@Test func boundaryDetectionPrefersBlankLines() {
    var buffer = StreamingTextBuffer()
    _ = buffer.append("Paragraph one.\n\n")
    let secondRange = buffer.append("Paragraph two.")

    let boundary = buffer.lastStableBoundary(before: secondRange.lowerBound)
    #expect(String(buffer.text[boundary...]) == "Paragraph two.")
}
