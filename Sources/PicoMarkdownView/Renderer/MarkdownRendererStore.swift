import Foundation
import Observation

@MainActor
@Observable
final class MarkdownRendererStore {
    private(set) var attributedText: AttributedString

    private let renderer: MarkdownRenderer

    init(renderer: MarkdownRenderer) {
        self.renderer = renderer
        self.attributedText = AttributedString()
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await renderer.currentAttributedString()
            await MainActor.run {
                self.attributedText = snapshot
            }
        }
    }

    func apply(_ diff: AssemblerDiff) async {
        if let updated = await renderer.apply(diff) {
            self.attributedText = updated
        }
    }

    func refresh() async {
        let snapshot = await renderer.currentAttributedString()
        self.attributedText = snapshot
    }
}
