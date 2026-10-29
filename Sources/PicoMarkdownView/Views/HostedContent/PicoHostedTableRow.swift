#if os(macOS)
import AppKit
import Observation

@MainActor
@Observable
final class PicoHostedTableRow: Identifiable {
    let id: Int
    private(set) var cells: [AttributedString]
    private(set) var labels: [String]
    private(set) var links: [PicoHostedTableLink]

    init(id: Int, cells: [AttributedString], source: [[InlineRun]]) {
        self.id = id
        self.cells = cells
        labels = Self.labels(for: source, fallback: cells)
        links = Self.links(in: cells)
    }

    func update(cells: [AttributedString], source: [[InlineRun]]) {
        let labels = Self.labels(for: source, fallback: cells)
        if self.labels != labels { self.labels = labels }
        guard self.cells != cells else { return }
        self.cells = cells
        links = Self.links(in: cells)
    }

    private static func labels(for source: [[InlineRun]], fallback: [AttributedString]) -> [String] {
        fallback.enumerated().map { index, cell in
            guard index < source.count else { return String(cell.characters) }
            return source[index].map { run in run.math?.tex ?? run.text }.joined()
        }
    }

    private static func links(in cells: [AttributedString]) -> [PicoHostedTableLink] {
        var result: [PicoHostedTableLink] = []
        for (column, cell) in cells.enumerated() {
            let attributed = NSAttributedString.picoConverted(from: cell)
            attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
                guard let url else { return }
                result.append(PicoHostedTableLink(id: "\(column):\(range.location)", url: url,
                                                 label: (attributed.string as NSString).substring(with: range)))
            }
        }
        return result
    }
}

struct PicoHostedTableLink: Identifiable {
    let id: String
    let url: URL
    let label: String
}
#endif
