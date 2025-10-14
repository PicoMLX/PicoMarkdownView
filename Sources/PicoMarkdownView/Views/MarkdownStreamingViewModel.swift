import Foundation
import Observation

@MainActor
@Observable
final class MarkdownStreamingViewModel {
    private var pipeline: MarkdownStreamingPipeline
    private var processedInputs: Set<UUID> = []
    private let theme: MarkdownRenderTheme

    var attributedText: AttributedString = AttributedString()

    init(theme: MarkdownRenderTheme = .default()) {
        self.theme = theme
        self.pipeline = MarkdownStreamingPipeline(theme: theme)
    }

    func consume(_ input: MarkdownStreamingInput) async {
        if case .replacement = input.payload {
            processedInputs.removeAll(keepingCapacity: true)
        }
        guard processedInputs.insert(input.id).inserted else { return }
        switch input.payload {
        case .replacement(let value):
            await replace(with: value)
        case .chunks(let values):
            await consume(chunks: values)
        case .stream:
            guard let factory = input.streamFactory else { return }
            let stream = await factory()
            await consume(stream: stream)
        }
    }

    private func consume(chunks: [String]) async {
        for chunk in chunks {
            await applyChunk(chunk)
        }
        let (final, mutated) = await pipeline.finish()
        if mutated, let final, final != attributedText {
            attributedText = final
        }
    }

    private func consume(stream: AsyncStream<String>) async {
        for await chunk in stream {
            await applyChunk(chunk)
        }
        let (final, mutated) = await pipeline.finish()
        if mutated, let final, final != attributedText {
            attributedText = final
        }
    }

    private func replace(with value: String) async {
        let newPipeline = MarkdownStreamingPipeline(theme: theme)
        var latest = AttributedString()

        if !value.isEmpty {
            if let updated = await newPipeline.feed(value) {
                latest = updated
            }
        }

        let (final, mutated) = await newPipeline.finish()
        if mutated, let final {
            latest = final
        }

        pipeline = newPipeline
        if latest != attributedText {
            attributedText = latest
        }
    }

    private func applyChunk(_ chunk: String) async {
        guard !chunk.isEmpty else { return }
        if let updated = await pipeline.feed(chunk) {
            attributedText = updated
        }
    }
}
