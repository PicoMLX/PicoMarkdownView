import SwiftUI
import PicoMarkdownView

/// Galleries and related samples stay within their feature's sidebar destination.
struct ExamplePageView: View {
    let page: ExamplePage
    @State private var selectedExample: MarkdownExample
#if os(macOS)
    private var imageTapHandler: (@MainActor (MarkdownImageActivation) -> Void)?
#endif

    init(page: ExamplePage) {
        self.page = page
        self._selectedExample = State(initialValue: page.examples[0])
    }

#if os(macOS)
    func onImageTap(_ handler: @escaping @MainActor (MarkdownImageActivation) -> Void) -> Self {
        var view = self
        view.imageTapHandler = handler
        return view
    }
#endif

    var body: some View {
        MarkdownView(selectedExample)
#if os(macOS)
            .onImageTap { imageTapHandler?($0) }
#endif
            .id(selectedExample.id)
            .navigationTitle(page.name)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if page.examples.count > 1 {
                        Picker("Example", selection: $selectedExample) {
                            ForEach(page.examples) { example in
                                Text(example.name).tag(example)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    if let referenceURL = selectedExample.referenceURL {
                        Link("Reference", destination: referenceURL)
                    }
                }
            }
    }
}
