//
//  ContentView.swift
//  MarkdownExample
//
//  Created by Ronald Mannak on 10/15/25.
//

import SwiftUI

struct MarkdownExample: Identifiable, Hashable {
    var id = UUID()
        
    let name: String
    let localPath: String
    let webURL: URL
    
    init(localFilename: String, webURL: String) {
        self.name = localFilename
        self.localPath = Bundle.main.path(forResource: localFilename, ofType: "md")!
        self.webURL = URL(string: webURL)!
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(localPath)
        hasher.combine(webURL)
    }
    
    static let examples = [
        MarkdownExample(
            localFilename: "TEST",
            webURL: "https://github.com/mxstbr/markdown-test-file/blob/master/TEST.md"),
        MarkdownExample(
            localFilename: "markdown-it",
            webURL: "https://markdown-it.github.io"),
        MarkdownExample(
            localFilename: "KaTeX-tests",
            webURL: "https://github.com/just-the-docs/just-the-docs-tests/blob/main/collections/_components/math/katex/tests.md")
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
