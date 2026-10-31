#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("Hosted image Markdown round trips")
@MainActor
struct MacHostedImageMarkdownTests {
    @Test("Image selection copying preserves literal entities in URL, title and alternative text",
           arguments: HostedImageMarkdownFixture.all)
    @available(macOS 27.0, *)
    func imageSelectionRoundTrips(fixture: HostedImageMarkdownFixture) async throws {
        let pipeline = MarkdownStreamingPipeline(imageProvider: MarkdownRoundTripImageProvider())
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        for update in [await pipeline.feed(fixture.markdown + "\n\n"), await pipeline.finish()] {
            guard let update else { continue }
            controller.update(textView: view, blocks: update.blocks, diffs: [update.diff],
                              replaceToken: 1, configuration: .default())
        }
        let baseline = try #require(await imageRun(in: pipeline))
        #expect(baseline.image?.source == fixture.source)
        #expect(baseline.image?.title == fixture.title)
        #expect(baseline.text == fixture.alt)
        let storage = try #require(view.textStorage)
        var hosted: [PicoHostedAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { hosted.append(attachment) }
        }
        let attachment = try #require(hosted.first)
        #expect(hosted.count == 1)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.contains(attachment.markdownRepresentation()))
        #expect(!copied.contains("\u{FFFC}"))

        let reparsed = MarkdownStreamingPipeline()
        // Small chunks also exercise entity decoding across chunk boundaries.
        for character in copied { _ = await reparsed.feed(String(character)) }
        _ = await reparsed.finish()
        let actual = try #require(await imageRun(in: reparsed))
        #expect(actual.image?.source == baseline.image?.source, Comment(rawValue: copied))
        #expect(actual.image?.title == baseline.image?.title, Comment(rawValue: copied))
        #expect(actual.text == baseline.text, Comment(rawValue: copied))
    }

    @Test("The shared table serializer preserves image destinations and titles",
           arguments: HostedImageMarkdownFixture.all)
    func tableImageRoundTrips(fixture: HostedImageMarkdownFixture) async throws {
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed("| Image |\n| --- |\n| " + fixture.markdown + " |\n\n")
        _ = await pipeline.finish()
        let table = try #require(await pipeline.blocksSnapshot().first { $0.table != nil }?.snapshot.table)
        let baseline = try #require(table.rows.first?.first?.first { $0.image != nil })
        let copied = PicoHostedTableMarkdown.render(table)
        let reparsed = MarkdownStreamingPipeline()
        for character in copied { _ = await reparsed.feed(String(character)) }
        _ = await reparsed.finish()
        let actualTable = try #require(await reparsed.blocksSnapshot().first { $0.table != nil }?.snapshot.table)
        let actual = try #require(actualTable.rows.first?.first?.first { $0.image != nil })
        #expect(actual.image?.source == baseline.image?.source, Comment(rawValue: copied))
        #expect(actual.image?.title == baseline.image?.title, Comment(rawValue: copied))
        #expect(actual.text == baseline.text, Comment(rawValue: copied))
    }

    private func imageRun(in pipeline: MarkdownStreamingPipeline) async -> InlineRun? {
        await pipeline.blocksSnapshot().lazy.compactMap { block in
            block.snapshot.inlineRuns?.first { $0.image != nil }
        }.first
    }
}

enum HostedImageMarkdownFixture: String, CaseIterable, Sendable {
    case namedEntities, numericEntities, quotesAndBackslashes, ordinaryAmpersands
    static var all: [Self] { Array(allCases) }

    var markdown: String {
        switch self {
        case .namedEntities:
            #"![x](https://example.com/a?x=&amp;amp; "&amp;copy;")"#
        case .numericEntities:
            #"![numeric &amp;#169;](https://example.com/a?x=&amp;#169; "&amp;#xA9;")"#
        case .quotesAndBackslashes:
            #"![quoted title](https://example.com/a?q=&amp;quot;&amp;b=2 "Title \"quote\" \\ path &amp;quot;")"#
        case .ordinaryAmpersands:
            #"![ordinary &amp; alt](https://example.com/a?one=1&two=2 "Ordinary A & B")"#
        }
    }

    var source: String {
        switch self {
        case .namedEntities: "https://example.com/a?x=&amp;"
        case .numericEntities: "https://example.com/a?x=&#169;"
        case .quotesAndBackslashes: "https://example.com/a?q=&quot;&b=2"
        case .ordinaryAmpersands: "https://example.com/a?one=1&two=2"
        }
    }

    var title: String {
        switch self {
        case .namedEntities: "&copy;"
        case .numericEntities: "&#xA9;"
        case .quotesAndBackslashes: #"Title "quote" \ path &quot;"#
        case .ordinaryAmpersands: "Ordinary A & B"
        }
    }

    var alt: String {
        switch self {
        case .namedEntities: "x"
        case .numericEntities: "numeric &#169;"
        case .quotesAndBackslashes: "quoted title"
        case .ordinaryAmpersands: "ordinary & alt"
        }
    }
}

private actor MarkdownRoundTripImageProvider: MarkdownImageProvider {
    func image(for url: URL) async -> MarkdownImageResult? {
        let size = CGSize(width: 128, height: 64)
        return MarkdownImageResult(image: NSImage(size: size), size: size)
    }
}
#endif
