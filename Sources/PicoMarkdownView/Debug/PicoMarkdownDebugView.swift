#if DEBUG

import SwiftUI

public struct RenderedBlocksProvider {
    let fetch: @Sendable () async -> [RenderedBlock]

    static func renderer(_ renderer: MarkdownRenderer) -> Self {
        Self(fetch: { await renderer.renderedBlocks() })
    }

    static func store(_ store: MarkdownRendererStore) -> Self {
        Self(fetch: { await store.renderedBlocks() })
    }

    static func constant(_ blocks: [RenderedBlock]) -> Self {
        Self(fetch: { blocks })
    }
}

public struct PicoMarkdownDebugView: View {
    private let provider: RenderedBlocksProvider
    private let initialInput: MarkdownStreamingInput?
    private let formatter = DebugBlockFormatter()

    @State private var localViewModel: MarkdownStreamingViewModel?
    @State private var lines: [String] = []
    @State private var isAutoRefresh: Bool = true

    public init(provider: RenderedBlocksProvider) {
        self.provider = provider
        self.initialInput = nil
        self._localViewModel = State(initialValue: nil)
    }

    private init(input: MarkdownStreamingInput,
                 theme: MarkdownRenderTheme) {
        let viewModel = MarkdownStreamingViewModel(theme: theme)
        self.provider = RenderedBlocksProvider(fetch: {
            await MainActor.run { viewModel.blocks }
        })
        self.initialInput = input
        self._localViewModel = State(initialValue: viewModel)
    }

    public init(text: String,
                theme: MarkdownRenderTheme = .default()) {
        self.init(input: .text(text), theme: theme)
    }

    public init(chunks: [String],
                theme: MarkdownRenderTheme = .default()) {
        self.init(input: .chunks(chunks), theme: theme)
    }

    public init(stream: @escaping @Sendable () async -> AsyncStream<String>,
                theme: MarkdownRenderTheme = .default()) {
        self.init(input: .stream(stream), theme: theme)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Auto-refresh", isOn: $isAutoRefresh)
                    .toggleStyle(.switch)
                Spacer()
                Button("Refresh Now") {
                    Task { await refreshOnce() }
                }
                .disabled(isAutoRefresh)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index.isMultiple(of: 2) ? Color.gray.opacity(0.04) : Color.clear)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(white: 0.05).opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding()
        .task(id: isAutoRefresh) {
            if isAutoRefresh {
                while !Task.isCancelled {
                    await refreshOnce()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
        .task {
            await refreshOnce()
        }
        .task(id: initialInput?.id) {
            guard let input = initialInput, let viewModel = localViewModel else { return }
            await viewModel.consume(input)
        }
    }

    @MainActor
    private func updateLines(_ newLines: [String]) {
        lines = newLines
    }

    private func refreshOnce() async {
        let blocks = await provider.fetch()
        let newLines = formatter.makeLines(from: blocks)
        await MainActor.run {
            updateLines(newLines)
        }
    }
}

struct PicoMarkdownDebugView_Previews: PreviewProvider {
    static var previews: some View {
        PicoMarkdownDebugView(provider: .constant(sampleBlocks))
            .previewLayout(.sizeThatFits)
    }

    private static var sampleBlocks: [RenderedBlock] {
        let runs: [InlineRun] = [
            InlineRun(text: "This is a "),
            InlineRun(text: "bold", style: [.bold]),
            InlineRun(text: " statement with "),
            InlineRun(text: "mc^2", style: [.math], math: MathInlinePayload(tex: "mc^2", display: false))
        ]

        let paragraphSnapshot = BlockSnapshot(id: 1,
                                              kind: .paragraph,
                                              inlineRuns: runs,
                                              isClosed: true,
                                              parentID: nil,
                                              depth: 0,
                                              childIDs: [])

        let mathBlock = RenderedMath(tex: "\\int_0^x \\sin(x) dx",
                                     display: true,
                                     fontSize: 16)

        let mathSnapshot = BlockSnapshot(id: 2,
                                         kind: .math(display: true),
                                         inlineRuns: nil,
                                         mathText: mathBlock.tex,
                                         isClosed: true,
                                         parentID: nil,
                                         depth: 0,
                                         childIDs: [])

        let paragraphBlock = RenderedBlock(id: 1,
                                           kind: .paragraph,
                                           content: AttributedString("This is a bold statement with mc^2"),
                                           snapshot: paragraphSnapshot,
                                           table: nil,
                                           listItem: nil,
                                           blockquote: nil,
                                           math: nil,
                                           images: [],
                                           codeBlock: nil)

        let mathRenderedBlock = RenderedBlock(id: 2,
                                              kind: .math(display: true),
                                              content: AttributedString(mathBlock.tex),
                                              snapshot: mathSnapshot,
                                              table: nil,
                                              listItem: nil,
                                              blockquote: nil,
                                              math: mathBlock,
                                              images: [],
                                              codeBlock: nil)

        return [paragraphBlock, mathRenderedBlock]
    }
}

#endif
