//
//  MarkdownView.swift
//  MarkdownExample
//
//  Created by Ronald Mannak on 10/15/25.
//

import SwiftUI
import PicoMarkdownView
import Splash


struct MarkdownView: View {
    
    private let webURL: URL
    private let markdown: String

    let customProvider = CodeBlockThemeProvider(
        light: { codeFont in
            Theme.sunset(withFont: Splash.Font(size: Double(codeFont.pointSize)))
        },
        dark: { codeFont in
            Theme.midnight(withFont: Splash.Font(size: Double(codeFont.pointSize)))
        }
    )
    
    init(_ example: MarkdownExample) {
        self.webURL = example.webURL
        self.markdown = try! String(contentsOfFile: example.localPath, encoding: .utf8)
    }
    
    var body: some View {
        
        HStack {
            TabView {
                Tab("Markdown", systemImage: "square.fill.text.grid.1x2") {
                    ScrollView {
                        PicoMarkdownStackView(
                            text: markdown,
                            codeBlockThemeProvider: customProvider)
                            .padding()
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
