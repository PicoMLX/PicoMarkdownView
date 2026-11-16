//
//  ContentView.swift
//  MarkdownExample
//
//  Created by Ronald Mannak on 10/15/25.
//

import SwiftUI
import PicoMarkdownView

struct ContentView: View {    
    
    @State private var selectedPage = ExamplePage.pages.first
#if os(macOS)
    @State private var selectedImage: ExampleImagePresentation?
#endif
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPage) {
                ForEach(ExamplePage.pages) { page in
                    Text(page.name)
                        .tag(page)
                }
            }
            .navigationTitle("Examples")
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 300)
        } detail: {
            if let selectedPage {
                ExamplePageView(page: selectedPage)
#if os(macOS)
                    .onImageTap { selectedImage = ExampleImagePresentation(image: $0) }
#endif
                    .id(selectedPage.id)
            } else {
                ContentUnavailableView("Select an Example", systemImage: "doc.text")
            }
        }
#if os(macOS)
        // The app owns presentation above the entire split view, including
        // the source and diagnostic tabs. The Markdown renderer only reports
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
