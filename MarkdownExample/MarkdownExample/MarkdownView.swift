//
//  MarkdownView.swift
//  MarkdownExample
//
//  Created by Ronald Mannak on 10/15/25.
//

import SwiftUI
import PicoMarkdownView


struct MarkdownView: View {
    
    private let webURL: URL
    private let markdown: String

    init(_ example: MarkdownExample) {
        self.webURL = example.webURL
        self.markdown = try! String(contentsOfFile: example.localPath, encoding: .utf8)
    }
    
    var body: some View {
        
        HStack {
            TabView {
                Tab("Markdown", systemImage: "square.fill.text.grid.1x2") {
                    ScrollView {
                        PicoMarkdownStackView(text: markdown)
                            .padding()
                    }
                }
                Tab("Debug", systemImage: "ladybug") {
                    ScrollView {
                        PicoMarkdownDebugView(text: markdown)
                    }
                }
                Tab("Text", systemImage: "text.alignleft") {
                    ScrollView {
                        Text(markdown)
                    }
                }
            }
            .textSelection(.enabled)
            
            WebView(url: webURL)
                .id(webURL)
        }
    }
}
