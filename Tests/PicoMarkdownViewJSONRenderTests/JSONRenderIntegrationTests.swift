#if os(macOS)
import AppKit
import JSONRenderCatalog
import JSONRenderCore
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
        #"{"root":"widget","elements":{"widget":{"type":"UnknownWidget","props":{"text":"Content"}}}}"#,
        #"{"root":"text","elements":{"text":{"type":"Text","props":{"text":"Content"},"watch":{"/item":{"action":"sendMessage","params":{"message":"Automatic"}}}}},"state":{"item":true}}"#,
        #"{"root":"card","elements":{"card":{"type":"Card","props":{},"children":["text"]},"text":{"type":"Text","props":{"text":"Content"},"visible":{"$state":"/item","$item":"/other","eq":true}}},"state":{"item":true}}"#
    ])
    func invalidSpecPreservesSource(source: String) async throws {
        let view = try await renderFence(source)
        #expect(try attachments(in: view).isEmpty)
        #expect(view.string.contains(source))
    }

    @Test("Every component and alias from the Vercel native registry can be hosted")
    func hostsFullNativeCatalog() async throws {
        let components = NativeCatalog.registry(animatesAppearance: false).components.keys.sorted()
        var elements = ["root": UIElement(type: "Stack", props: [:], children: components)]
        for component in components {
            elements[component] = UIElement(type: component, props: sampleProps(for: component))
        }

        let source = try encode(Spec(root: "root", elements: elements, state: ["label": "Catalog text"]))
        let view = try await renderFence(source)
        #expect(try attachments(in: view).count == 1)
        #expect(!view.string.contains(source))
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
    func userActionPolicy() async throws {
        let passiveButton = try #require(PicoJSONRenderSpec.decode(Self.buttonSpec)?.elements["button"])
        #expect(passiveButton.on == nil)
        #expect(passiveButton.props["disabled"] == true)
        let activeButton = try #require(PicoJSONRenderSpec.decode(Self.buttonSpec, allowsHostActions: true)?.elements["button"])
        #expect(activeButton.on?["press"] == .actionBinding(ActionBinding(
            action: "sendMessage", params: ["message": .value("Continue planning")]
        )))
        #expect(activeButton.props["disabled"] == nil)

        let unboundButton = #"{"root":"button","elements":{"button":{"type":"Button","props":{"label":"Continue","disabled":false}}}}"#
        let inactiveButton = try #require(
            PicoJSONRenderSpec.decode(unboundButton, allowsHostActions: true)?.elements["button"]
        )
        #expect(inactiveButton.props["disabled"] == true)

        let view = try await renderFence(Self.buttonSpec)
        #expect(try attachments(in: view).count == 1)
    }

    @Test("Built-in, chained, and undeclared actions stay unavailable even with a host callback", arguments: [
        #"{"action":"setState","params":{"statePath":"/show","value":true}}"#,
        #"{"action":"sendMessage","params":{"message":"Continue"},"onSuccess":{"action":"sendMessage","params":{"message":"Again"}}}"#,
        #"{"action":"openLink","params":{"url":"https://example.com/"}}"#
    ])
    func rejectsUnsupportedActions(action: String) {
        let source = #"{"root":"button","elements":{"button":{"type":"Button","props":{"label":"Continue"},"on":{"press":\#(action)}}}}"#
        #expect(PicoJSONRenderSpec.decode(source, allowsHostActions: true) == nil)
    }

    @Test("Specs cannot exceed the source budget or expand the same child repeatedly")
    func rejectsOversizedAndReusedContent() {
        let oversized = Self.buttonSpec + String(repeating: " ", count: PicoJSONRenderSpec.maximumSourceBytes)
        #expect(PicoJSONRenderSpec.decode(oversized, allowsHostActions: true) == nil)

        let repeated = #"{"root":"stack","elements":{"stack":{"type":"Stack","props":{},"children":["item","item"]},"item":{"type":"Text","props":{"text":"Repeated"}}}}"#
        #expect(PicoJSONRenderSpec.decode(repeated) == nil)
    }

    @Test("An over-budget hidden branch falls back to source before it can be shown")
    func hiddenPropsBudgetPreservesSource() async throws {
        let root = UIElement(type: "Stack", props: [:], children: ["item"])
        let visibility: VisibilityCondition = .singleCondition(.stateCondition(StateCondition(
            state: "/show", eq: true
        )))
        let smallItem = UIElement(type: "Text", props: ["text": "Details", "extra": [0]], visible: visibility)
        let smallSpec = Spec(root: "root", elements: ["root": root, "item": smallItem], state: ["show": false])
        #expect(PicoJSONRenderSpec.decode(try encode(smallSpec)) != nil)

        let slots = PicoJSONRenderSpec.renderLimits.maxResolvedPropBytes / MemoryLayout<JSONValue>.stride
        var largeSpec = smallSpec
        largeSpec.elements["item"]?.props["extra"] = .array(Array(repeating: 0, count: slots))
        let source = try encode(largeSpec)
        #expect(source.utf8.count < PicoJSONRenderSpec.maximumSourceBytes)

        let view = try await renderFence(source)
        #expect(try attachments(in: view).isEmpty)
        #expect(view.string.contains(source))
    }

    @Test("Both chart types keep the mark count, geometry and number limits", arguments: ["BarChart", "LineChart"])
    func limitsChartProps(component: String) throws {
        let rows: [JSONValue] = [["x": "April", "y": 5]]
        let accepted: [String: JSONValue] = ["height": 180, "data": .array(rows)]
        let cases: [[String: JSONValue]] = [
            accepted,
            ["height": 1_000, "data": .array(rows)],
            ["height": 180, "data": .array(Array(repeating: rows[0], count: 17))],
            ["height": 180, "data": [["x": "April", "y": 1e13]]],
            ["height": 180, "data": [["x": "April", "y": "10000000000000"]]]
        ]
        for (index, props) in cases.enumerated() {
            let chart = UIElement(type: component, props: props)
            let source = try encode(Spec(root: "chart", elements: ["chart": chart]))
            #expect((PicoJSONRenderSpec.decode(source) != nil) == (index == 0))
        }
    }

    @Test("Native images inherit the Markdown image provider", arguments: [false, true])
    func inheritsImageProvider(hasProvider: Bool) async throws {
        let url = try #require(URL(string: "https://example.com/image.png"))
        let image = UIElement(type: "Image", props: ["src": .string(url.absoluteString), "alt": "Example image"])
        let source = try encode(Spec(root: "image", elements: ["image": image]))
        let provider = CatalogImageProvider()
        let pipeline = MarkdownStreamingPipeline(
            imageProvider: hasProvider ? provider : nil, embeddedBlockRenderers: [.jsonRender]
        )
        let update = try #require(await pipeline.feed("```json-render\n" + source + "\n```\n\n"))
        let presentation = try #require(update.blocks.compactMap(\.embeddedBlock).first)
        let model = PicoHostedEmbeddedBlockModel(presentation: presentation)
        #expect(model.acceptsPresentation)
        let context = try #require(model.context)

        let result = await context.image(for: url)
        #expect(result?.size == (hasProvider ? CGSize(width: 20, height: 10) : nil))
        let requests = await provider.requests
        #expect(requests == (hasProvider ? [url] : []))
    }

    @Test("A dense valid chart card fits the renderer's resolved prop budget")
    func denseSpecRenders() throws {
        let chartIDs = (0..<(PicoJSONRenderSpec.maximumElements - 1)).map { "chart\($0)" }
        let rows = (0..<16).map { ["x": "Item \($0)", "y": $0] as [String: Any] }
        var elements: [String: Any] = ["root": ["type": "Stack", "children": chartIDs]]
        for id in chartIDs {
            elements[id] = ["type": "BarChart", "props": ["data": rows]]
        }
        let json = try JSONSerialization.data(withJSONObject: ["root": "root", "elements": elements])
        let spec = try #require(PicoJSONRenderSpec.decode(String(decoding: json, as: UTF8.self)))
        let registry = RendererRegistry(components: [
            "Stack": ComponentDefinition { _ in "Stack" },
            "BarChart": ComponentDefinition { _ in "BarChart" }
        ])
        let tree = try #require(buildRenderTree(spec: spec, registry: registry, store: StateStore([:]),
                                                limits: PicoJSONRenderSpec.renderLimits))
        #expect(tree.children.count == chartIDs.count)
    }

    private static let buttonSpec = #"{"root":"button","elements":{"button":{"type":"Button","props":{"label":"Continue"},"on":{"press":{"action":"sendMessage","params":{"message":"Continue planning"}}}}}}"#

    private func sampleProps(for component: String) -> [String: JSONValue] {
        switch component {
        case "Card", "List", "ListItem": return ["title": .string(component)]
        case "Heading", "Badge": return ["text": .string(component)]
        case "Text": return ["text": ["$state": "/label"]]
        case "Metric": return ["label": "Processed", "value": 12]
        case "Alert": return ["title": "Review", "message": "Ready for review"]
        case "Image": return ["src": "https://example.com/image.png", "alt": "Example image", "height": 160]
        case "Progress": return ["label": "Progress", "value": 25]
        case "Button": return ["label": "Continue"]
        case "Switch", "Toggle": return ["label": "Show notes", "checked": true]
        case "BarChart", "LineChart": return ["data": [["x": "April", "y": 5]]]
        default: return [:]
        }
    }

    private func encode(_ spec: Spec) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(spec), as: UTF8.self)
    }

    private func renderFence(_ source: String) async throws -> NSTextView {
        let pipeline = MarkdownStreamingPipeline(embeddedBlockRenderers: [.jsonRender])
        let update = try #require(await pipeline.feed("```json-render\n" + source + "\n```\n\n"))
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        controller.update(textView: view, blocks: update.blocks, diffs: [update.diff], replaceToken: 1, configuration: .default())
        return view
    }

    private func attachments(in view: NSTextView) throws -> [PicoHostedAttachment] {
        let storage = try #require(view.textStorage)
        var attachments: [PicoHostedAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? PicoHostedAttachment { attachments.append(attachment) }
        }
        return attachments
    }
}

private actor CatalogImageProvider: MarkdownImageProvider {
    private(set) var requests: [URL] = []

    func image(for url: URL) async -> MarkdownImageResult? {
        requests.append(url)
        let size = CGSize(width: 20, height: 10)
        return MarkdownImageResult(image: NSImage(size: size), size: size)
    }
}
#endif
