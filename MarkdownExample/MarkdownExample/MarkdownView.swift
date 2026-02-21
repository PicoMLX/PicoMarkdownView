//
//  MarkdownView.swift
//  MarkdownExample
//
//  Created by Ronald Mannak on 10/15/25.
//

import SwiftUI
import PicoMarkdownView
import WebKit

struct MarkdownView: View {
    
    @Environment(\.openURL) var openURL
    
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
                        PicoMarkdownView(stream: { [markdown] in
                            AsyncStream<String> { continuation in
                                let task = Task {
                                    // Stream word-by-word at ~20 words/sec to simulate fast LLM inference
                                    var chunk = ""
                                    var wordSeen = false
                                    for char in markdown {
                                        guard !Task.isCancelled else { break }
                                        chunk.append(char)
                                        if char.isWhitespace {
                                            if wordSeen {
                                                continuation.yield(chunk)
                                                chunk = ""
                                                wordSeen = false
                                                try? await Task.sleep(nanoseconds: 50_000_000)
                                            }
                                        } else {
                                            wordSeen = true
                                        }
                                    }
                                    if !chunk.isEmpty && !Task.isCancelled {
                                        continuation.yield(chunk)
                                    }
                                    continuation.finish()
                                }
                                continuation.onTermination = { _ in
                                    task.cancel()
                                }
                            }
                        })
                            .textSelection(.enabled)
                            .padding()
                            .onOpenLink { url in
                                openURL(url)
                                return .handled
                            }
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
                        
            WebView(url: webURL) { configuration in
                // To shut up Nyan Cat
                configuration.mediaTypesRequiringUserActionForPlayback = .all
            }
                .id(webURL)
        }
    }
}
