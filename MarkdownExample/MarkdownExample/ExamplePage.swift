import Foundation
import PicoMarkdownView

struct ExamplePage: Identifiable, Hashable {
    let name: String
    let examples: [MarkdownExample]
    var id: String { name }

    static let pages: [ExamplePage] = [
        ExamplePage(name: "Markdown", examples: [
            MarkdownExample("Markdown", reference: "https://spec.commonmark.org/0.31.2/"),
            MarkdownExample("Blockquotes", name: "Nested Blocks",
                            reference: "https://spec.commonmark.org/0.31.2/#block-quotes")
        ]),
        ExamplePage(name: "Code", examples: [
            MarkdownExample("Code", reference: "https://github.com/PrismJS/prism/tree/v1.29.0/tests/languages")
        ]),
        ExamplePage(name: "Math", examples: [
            MarkdownExample("Math", reference: "https://github.com/mgriebling/SwiftMath/blob/fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7/EXAMPLES.md")
        ]),
        ExamplePage(name: "Images & SVG", examples: [
            MarkdownExample("Images", reference: "https://github.com/pnggroup/libpng/tree/v1.6.51/contrib/pngsuite",
                            usesBundledImages: true),
            MarkdownExample("SVG", reference: "https://www.w3.org/Graphics/SVG/", svgRenderingEnabled: true),
            MarkdownExample("RemoteImages", name: "Network Images", reference: "https://httpbin.org/#/Images")
        ]),
        ExamplePage(name: "Charts", examples: chartExamples),
        ExamplePage(name: "Diagrams", examples: [
            MarkdownExample("Diagrams-Overview", name: "Examples", reference: "https://pele.run/examples"),
            MarkdownExample("Diagrams", name: "Gallery", reference: "https://pele.run/examples")
        ]),
        ExamplePage(name: "OpenUI", examples: componentExamples),
        ExamplePage(name: "Tags & Mentions", examples: [
            MarkdownExample("Tags", reference: "https://github.com/PicoMLX/PicoMarkdownView",
                            tagPrefixes: [.mention, .hashtag, .ticker, .paired(open: "[[", close: "]]")])
        ]),
        ExamplePage(name: "Link Context Menus", examples: [MarkdownExample("LinkMenus")])
    ]

    private static var chartExamples: [MarkdownExample] {
        var examples = [MarkdownExample("Charts", name: "Examples", reference: "https://vega.github.io/vega-lite/examples/")]
        #if os(macOS)
        examples.append(MarkdownExample("Charts-Gallery-Preview", name: "Gallery",
                                        reference: "https://vega.github.io/vega-lite/examples/",
                                        isLargeFixture: true))
        #endif
        return examples
    }

    private static var componentExamples: [MarkdownExample] {
        var examples = [MarkdownExample("OpenUI", reference: "https://www.openui.com/docs/openui-lang")]
        #if os(macOS)
        examples.append(MarkdownExample("HTMLPreviews", name: "HTML Previews", htmlPreviewsEnabled: true))
        #endif
        return examples
    }
}
