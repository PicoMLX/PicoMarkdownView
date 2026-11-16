#if os(macOS)
import JSONRenderCore
import PicoMarkdownView
import SwiftUI

@MainActor
struct PicoJSONRenderImage: View {
    private let url: URL?
    private let alt: String
    private let height: CGFloat
    private let context: PicoEmbeddedBlockContext
    @State private var loadedImage: (url: URL, image: MarkdownImage)?

    init(props: [String: JSONValue], context: PicoEmbeddedBlockContext) {
        url = props["src"]?.stringValue.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        alt = props["alt"]?.stringValue ?? ""
        let proposedHeight = props["height"]?.doubleValue ?? 160
        height = proposedHeight.isFinite ? min(max(proposedHeight, 1), 320) : 160
        self.context = context
    }

    var body: some View {
        Group {
            if let loadedImage, loadedImage.url == url {
                Image(nsImage: loadedImage.image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: alt))
        .accessibilityAddTraits(.isImage)
        .accessibilityHidden(alt.isEmpty)
        .task(id: url) {
            guard let url else {
                loadedImage = nil
                return
            }
            guard loadedImage?.url != url else { return }
            loadedImage = nil
            guard let result = await context.image(for: url), !Task.isCancelled else { return }
            loadedImage = (url, result.image)
        }
    }
}
#endif
