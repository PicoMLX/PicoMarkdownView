#if os(macOS)
import Foundation

/// A top-level link-only paragraph, recognized from existing inline runs without parsing
/// the source again. Recognition and canonical source export wait for closure,
/// so an open paragraph never serializes an ever-growing link label.
struct StandaloneFileLink: Equatable {
    let referenceURL: URL
    let markdown: String

    init?(snapshot: BlockSnapshot) {
        guard snapshot.isClosed, snapshot.kind == .paragraph, snapshot.parentID == nil,
              let runs = snapshot.inlineRuns else { return nil }
        var destination: String?
        var hasLabel = false
        var linkEnded = false
        for run in runs {
            guard run.image == nil, run.math == nil, run.tag == nil,
                  run.style.intersection([.image, .math, .tag, .footnote]).isEmpty else { return nil }
            if run.style.contains(.link), let url = run.linkURL {
                guard !linkEnded, destination == nil || destination == url else { return nil }
                destination = url
                hasLabel = hasLabel || !run.text.allSatisfy(\.isWhitespace)
            } else {
                guard run.style.isEmpty, run.linkURL == nil,
                      run.text.allSatisfy(\.isWhitespace) else { return nil }
                if destination != nil, !run.text.isEmpty { linkEnded = true }
            }
        }
        guard hasLabel, let destination, let referenceURL = URL(string: destination) else { return nil }
        self.referenceURL = referenceURL
        markdown = PicoHostedTableMarkdown.inline(runs)
    }
}
#endif
