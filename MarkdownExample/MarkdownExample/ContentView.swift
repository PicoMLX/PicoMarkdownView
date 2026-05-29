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

    init(localFilename: String,
         webURL: String,
         tagPrefixes: Set<TagPrefix> = TagPrefix.defaults) {
        self.name = localFilename
        self.localPath = Bundle.main.path(forResource: localFilename, ofType: "md")!
        self.webURL = URL(string: webURL)!
        self.tagPrefixes = tagPrefixes
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(localPath)
        hasher.combine(webURL)
    }

    static let examples = [
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
    ]
}

struct ContentView: View {    
    
    @State var selectedExample: MarkdownExample?
    
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
            } else {
                Text("Select example")
            }
        }
        .onAppear {
            selectedExample = MarkdownExample.examples.first
        }
    }
}

#Preview {
    ContentView()
}
