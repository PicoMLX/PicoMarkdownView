//
//  ContentView.swift
//  MarkdownExample
//
//  Created by Ronald Mannak on 10/15/25.
//

import SwiftUI
import PicoMarkdownView

struct MarkdownExample: Identifiable, Hashable {
    var id = UUID()

    let name: String
    let localPath: String
    let webURL: URL
    /// Inline-tag prefixes the renderer should recognise for this document.
    /// Most examples use the defaults (`@`, `#`); the Tags demo opts into the
    /// `$` ticker and `[[ ]]` wiki paired delimiter too.
    let tagPrefixes: Set<TagPrefix>
    /// Large offline fixtures load asynchronously and omit the extra diagnostic views.
    let isLargeFixture: Bool
    /// Only the SVG demo opts into rendering SVG fences as native graphics.
    let svgRenderingEnabled: Bool

    init(localFilename: String,
         webURL: String,
         displayName: String? = nil,
         tagPrefixes: Set<TagPrefix> = TagPrefix.defaults,
         isLargeFixture: Bool = false,
         svgRenderingEnabled: Bool = false) {
        self.name = displayName ?? localFilename
        self.localPath = (Bundle.main.path(forResource: localFilename, ofType: "md")
            ?? Bundle.main.path(forResource: localFilename, ofType: "md.deflate"))!
        self.webURL = URL(string: webURL)!
        self.tagPrefixes = tagPrefixes
        self.isLargeFixture = isLargeFixture
        self.svgRenderingEnabled = svgRenderingEnabled
    }

    func loadMarkdown() throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: localPath))
        if localPath.hasSuffix(".deflate") {
            let decoded = try (data as NSData).decompressed(using: .zlib) as Data
            return String(decoding: decoded, as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(localPath)
        hasher.combine(webURL)
    }

    static let examples: [MarkdownExample] = {
        var examples = [
        MarkdownExample(
            localFilename: "LinkMenus",
            webURL: "about:blank"),
        MarkdownExample(
            localFilename: "Tags",
            webURL: "https://github.com/PicoMLX/PicoMarkdownView/blob/main/MarkdownExample/MarkdownExample/markdown%20files/Tags.md",
            tagPrefixes: [.mention, .hashtag, .ticker, .paired(open: "[[", close: "]]")]),
        MarkdownExample(
            localFilename: "TEST",
            webURL: "https://github.com/mxstbr/markdown-test-file/blob/master/TEST.md"),
        MarkdownExample(
            localFilename: "markdown-it",
            webURL: "https://markdown-it.github.io"),
        MarkdownExample(
            localFilename: "KaTeX-tests",
            webURL: "https://github.com/just-the-docs/just-the-docs-tests/blob/main/collections/_components/math/katex/tests.md"),
        MarkdownExample(
            localFilename: "KaTeX-streaming",
            webURL: "https://www.nyan.cat"),
        MarkdownExample(
            localFilename: "tables",
            webURL: "https://github.com/gonzalezreal/swift-markdown-ui/blob/main/Examples/Demo/Demo/TablesView.swift"),
        MarkdownExample(
            localFilename: "RemoteImages",
            webURL: "https://httpbin.org/#/Images"),
        MarkdownExample(
            localFilename: "CodeBlocks",
            webURL: "https://github.com/PicoMLX/PicoMarkdownView/blob/main/MarkdownExample/MarkdownExample/markdown%20files/CodeBlocks.md"),
        MarkdownExample(
            localFilename: "StackEdit",
            webURL: "https://stackedit.io/app#"),
        MarkdownExample(
            localFilename: "Diagrams",
            webURL: "https://pele.run/examples"),
        MarkdownExample(
            localFilename: "Charts",
            webURL: "https://vega.github.io/vega-lite/examples/"),
        MarkdownExample(
            localFilename: "SVG",
            webURL: "https://developer.mozilla.org/en-US/docs/Web/SVG/Tutorials/SVG_from_scratch",
            svgRenderingEnabled: true),
        MarkdownExample(
            localFilename: "OpenUI",
            webURL: "https://www.openui.com/docs/openui-lang"),
        MarkdownExample(
            localFilename: "Blockquotes",
            webURL: "https://spec.commonmark.org/0.31.2/#block-quotes"),
        ]
        #if os(macOS)
        let charts = examples.firstIndex { $0.name == "Charts" }!
        examples.insert(MarkdownExample(localFilename: "Charts-Gallery-Preview",
                                        webURL: "https://vega.github.io/vega-lite/examples/",
                                        displayName: "Charts-Gallery",
                                        isLargeFixture: true), at: charts + 1)
        #endif
        return examples
    }()
}

struct ContentView: View {    
    
    @State var selectedExample: MarkdownExample?
#if os(macOS)
    @State private var selectedImage: ExampleImagePresentation?
#endif
    
    var body: some View {
        NavigationSplitView {
                List(selection: $selectedExample) {
                    ForEach(MarkdownExample.examples) { example in
                        Text(example.name)
                            .tag(example)
                    }
                }
        } detail: {
            if let selectedExample {
                MarkdownView(selectedExample)
#if os(macOS)
                    .onImageTap { selectedImage = ExampleImagePresentation(image: $0) }
#endif
                    .id(selectedExample.id)
            } else {
                Text("Select an Example")
            }
        }
        .onAppear {
            selectedExample = MarkdownExample.examples.first
        }
#if os(macOS)
        // The app owns presentation above the entire split view, including
        // the browser comparison pane. The Markdown renderer only reports
        // activation and keeps its streaming view alive beneath the sheet.
        .background {
            GeometryReader { geometry in
                Color.clear
                    .sheet(item: $selectedImage) { presentation in
                        ImageLightbox(image: presentation.image)
                            .frame(width: max(320, geometry.size.width * 0.94),
                                   height: max(280, geometry.size.height * 0.92))
                    }
            }
        }
#endif
    }
}

#Preview {
    ContentView()
}

#if os(macOS)
private struct ExampleImagePresentation: Identifiable {
    let id = UUID()
    let image: MarkdownImageActivation
}
#endif
