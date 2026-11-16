#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownView
@testable import PicoMarkdownViewJSONRender

@MainActor
struct JSONRenderIntegrationTests {
    @Test("A streamed spec mounts on closure and keeps its source and attachment across later prose")
    func closedSpecRetainsAttachment() async throws {
        let renderer = PicoEmbeddedBlockRenderer.jsonRender { _ in
            Issue.record("Mounting a spec must never dispatch an app action")
        }
        let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [renderer])
        let controller = TextKitStreamingController()
        let view = try #require(controller.makeTextKit2View(configuration: .default()) as? StreamingTextKit2View)
        let source = Self.buttonSpec
        let fence = "```json-render\n" + source + "\n```"

        let open = try #require(await pipeline.feed("Before.\n\n```json-render\n" + source + "\n"))
        controller.update(textView: view, blocks: open.blocks, diffs: [open.diff], replaceToken: 1, configuration: .default())
        #expect(try attachments(in: view).isEmpty)
        #expect(view.string.contains(source))

        let closed = try #require(await pipeline.feed("```\n\n"))
        controller.update(textView: view, blocks: closed.blocks, diffs: [closed.diff], replaceToken: 1, configuration: .default())
        let attachment = try #require(try attachments(in: view).first)
        #expect(attachment.interaction == .interactive)
        #expect(!view.string.contains(source))

        let tail = try #require(await pipeline.feed("After.\n\n"))
        controller.update(textView: view, blocks: tail.blocks, diffs: [tail.diff], replaceToken: 1, configuration: .default())
        #expect(try attachments(in: view).first === attachment)
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        let copied = view.markdownForSelection()
        #expect(copied.contains("Before."))
        #expect(copied.contains(fence))
        #expect(copied.contains("After."))
    }

    @Test("Malformed, unsupported and auto-dispatch specs remain source", arguments: [
        "{\"root\":",
        #"{"root":"missing","elements":{}}"#,
        #"{"root":"image","elements":{"image":{"type":"Image","props":{"src":"https://example.com/remote.png"}}}}"#,
        #"{"root":"text","elements":{"text":{"type":"Text","props":{"text":"Content"},"watch":{"/item":{"action":"sendMessage","params":{"message":"Automatic"}}}}}}"#,
        #"{"root":"card","elements":{"card":{"type":"Card","props":{},"children":["text"]},"text":{"type":"Text","props":{"text":"Content"},"visible":{"$state":"/item","$item":"/other","eq":true}}},"state":{"item":true}}"#
    ])
    func invalidSpecPreservesSource(source: String) async throws {
        let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [.jsonRender])
        let update = try #require(await pipeline.feed("```json-render\n" + source + "\n```\n\n"))
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        controller.update(textView: view, blocks: update.blocks, diffs: [update.diff], replaceToken: 1, configuration: .default())
        #expect(try attachments(in: view).isEmpty)
        #expect(view.string.contains(source))
    }

    @Test("A valid spec stays source unless explicitly registered for its fence", arguments: ["json-render", "json"])
    func fenceOptIn(language: String) async throws {
        let renderers: [PicoEmbeddedBlockRenderer] = language == "json" ? [.jsonRender] : []
        let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: renderers)
        let update = try #require(await pipeline.feed("```\(language)\n" + Self.buttonSpec + "\n```\n\n"))
        #expect(update.blocks.allSatisfy { $0.embeddedBlock == nil })
        #expect(update.blocks.contains { String($0.content.characters).contains(Self.buttonSpec) })
    }

    @Test("App callbacks require explicit opt-in and can only bind directly to the button press")
    func userActionPolicy() {
        #expect(PicoJSONRenderSpec.decode(Self.buttonSpec) == nil)
        #expect(PicoJSONRenderSpec.decode(Self.buttonSpec, allowsHostActions: true) != nil)
        let chainedAction = #"{"root":"button","elements":{"button":{"type":"Button","props":{"label":"Continue"},"on":{"press":{"action":"sendMessage","params":{"message":"Continue"},"onSuccess":{"action":"sendMessage","params":{"message":"Again"}}}}}}}"#
        #expect(PicoJSONRenderSpec.decode(chainedAction, allowsHostActions: true) == nil)
    }

    @Test("Specs cannot exceed the source budget or expand the same child repeatedly")
    func rejectsOversizedAndReusedContent() {
        let oversized = Self.buttonSpec + String(repeating: " ", count: PicoJSONRenderSpec.maximumSourceBytes)
        #expect(PicoJSONRenderSpec.decode(oversized, allowsHostActions: true) == nil)

        let repeated = #"{"root":"stack","elements":{"stack":{"type":"Stack","props":{},"children":["item","item"]},"item":{"type":"Text","props":{"text":"Repeated"}}}}"#
        #expect(PicoJSONRenderSpec.decode(repeated) == nil)
    }

    private static let buttonSpec = #"{"root":"button","elements":{"button":{"type":"Button","props":{"label":"Continue"},"on":{"press":{"action":"sendMessage","params":{"message":"Continue planning"}}}}}}"#

    private func attachments(in view: NSTextView) throws -> [PicoHostedAttachment] {
        let storage = try #require(view.textStorage)
        var attachments: [PicoHostedAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { attachments.append(attachment) }
        }
        return attachments
    }
}
#endif
