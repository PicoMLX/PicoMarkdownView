import Foundation
import Markdown
import Testing
@testable import PicoMarkdownView

/// CommonMark 0.31.2 conformance, measured against cmark-gfm.
///
/// The spec defines Markdown by the HTML each example must produce.
/// PicoMarkdownView produces blocks and inline runs, not HTML, so instead of
/// serializing to HTML every example is parsed twice: once by PicoMarkdownView
/// (one feed, then `finish`) and once by swift-markdown, Apple's wrapper around
/// cmark-gfm, which passes the spec. Both results are reduced to the same
/// `Shape`: block kinds, nesting, heading levels, code languages and text, and
/// plain text with whitespace collapsed. Inline styling is deliberately not
/// compared yet; that is a later, finer dimension.
///
/// The suite is a ratchet, not a gate. `Fixtures/commonmark-known-failures.txt`
/// lists the examples that currently differ, each with its section, so the
/// pass count only moves up: an example that starts failing fails the suite,
/// and an example that starts passing fails it too, until the list is updated.
/// Deliberate deviations (raw HTML, entity decoding, setext headings) live in
/// that list with the rest; the list is the current state of conformance.
@Suite
struct CommonMarkConformance {
    struct Example: Decodable {
        let markdown: String
        let html: String
        let section: String
        let number: Int
    }

    static func examples() throws -> [Example] {
        let url = try #require(Bundle.module.url(forResource: "commonmark-spec-0.31.2", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([Example].self, from: Data(contentsOf: url))
    }

    /// Example numbers that currently differ from cmark-gfm, with a note.
    static func knownFailures() throws -> [Int: String] {
        let url = try #require(Bundle.module.url(forResource: "commonmark-known-failures", withExtension: "txt", subdirectory: "Fixtures"))
        var known: [Int: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            if let number = Int(parts[0]) {
                known[number] = parts.count > 1 ? String(parts[1]) : ""
            }
        }
        return known
    }

    @Test("Every spec example parses like cmark-gfm, except the recorded deviations")
    func conformance() async throws {
        let examples = try Self.examples()
        let known = try Self.knownFailures()
        var regressions: [String] = []
        var newlyPassing: [String] = []
        var passing = 0
        var perSection: [String: (passing: Int, total: Int)] = [:]
        var sectionOrder: [String] = []

        for example in examples {
            let ours = await Shape.pico(example.markdown)
            let reference = Shape.cmark(example.markdown)
            let passes = ours == reference
            if perSection[example.section] == nil { sectionOrder.append(example.section) }
            perSection[example.section, default: (0, 0)].total += 1
            if passes {
                passing += 1
                perSection[example.section, default: (0, 0)].passing += 1
                if known[example.number] != nil {
                    newlyPassing.append("\(example.number) \(example.section)")
                }
            } else if known[example.number] == nil {
                regressions.append("""
                    Example \(example.number) (\(example.section))
                    \(example.markdown.debugDescription)
                      pico:  \(ours)
                      cmark: \(reference)
                    """)
            }
        }

        print("CommonMark 0.31.2: \(passing)/\(examples.count) examples match cmark-gfm")
        for section in sectionOrder {
            let counts = perSection[section]!
            print(String(format: "  %3d/%3d  %@", counts.passing, counts.total, section))
        }

        #expect(regressions.isEmpty, "Examples that matched cmark-gfm before no longer do:\n\(regressions.joined(separator: "\n"))")
        #expect(newlyPassing.isEmpty, "Examples now match cmark-gfm; remove them from commonmark-known-failures.txt:\n\(newlyPassing.joined(separator: "\n"))")
    }

    @Test("The known-failures list is sorted, unique and names real examples")
    func knownFailuresListIsWellFormed() throws {
        let known = try Self.knownFailures()
        let examples = try Self.examples()
        let numbers = Set(examples.map(\.number))
        #expect(known.keys.allSatisfy { numbers.contains($0) })
        let url = try #require(Bundle.module.url(forResource: "commonmark-known-failures", withExtension: "txt", subdirectory: "Fixtures"))
        let listed = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .compactMap { line -> Int? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                return Int(trimmed.split(separator: " ", maxSplits: 1)[0])
            }
        #expect(listed == listed.sorted(), "keep the list in example order")
        #expect(Set(listed).count == listed.count, "no duplicates")
    }
}

/// The common reduction of a parsed document: what both parsers must agree on.
indirect enum Shape: Equatable, CustomStringConvertible {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, text: String)
    case quote([Shape])
    case list(ordered: Bool, items: [[Shape]])
    case rule
    case html(String)
    case other(String)

    var description: String {
        switch self {
        case .heading(let level, let text): return "h\(level)(\(text.debugDescription))"
        case .paragraph(let text): return "p(\(text.debugDescription))"
        case .code(let language, let text): return "code(\(language ?? "-"), \(text.debugDescription))"
        case .quote(let children): return "quote\(children)"
        case .list(let ordered, let items): return (ordered ? "ol" : "ul") + items.description
        case .rule: return "hr"
        case .html(let raw): return "html(\(raw.debugDescription))"
        case .other(let kind): return "other(\(kind))"
        }
    }

    /// Whitespace runs collapse to one space; leading and trailing go.
    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The info string's first word, or nil when there is none.
    static func normalizeLanguage(_ language: String?) -> String? {
        guard let first = language?.split(whereSeparator: \.isWhitespace).first else { return nil }
        return String(first)
    }

    /// Code keeps its whitespace; only a single trailing newline is dropped,
    /// since the two parsers differ on whether the final line ends in one.
    static func normalizeCode(_ code: String) -> String {
        code.hasSuffix("\n") ? String(code.dropLast()) : code
    }

    // MARK: PicoMarkdownView

    static func pico(_ markdown: String) async -> [Shape] {
        let tokenizer = MarkdownTokenizer()
        let assembler = MarkdownAssembler()
        _ = await assembler.apply(await tokenizer.feed(markdown))
        _ = await assembler.apply(await tokenizer.finish())
        let blocks = await assembler.makeSnapshot()
        var children: [BlockID: [BlockSnapshot]] = [:]
        for block in blocks {
            if let parent = block.parentID { children[parent, default: []].append(block) }
        }
        return shapes(of: blocks.filter { $0.parentID == nil }, children: children)
    }

    private static func inlineText(_ block: BlockSnapshot) -> String {
        normalize((block.inlineRuns ?? []).map(\.text).joined())
    }

    /// List items are flat siblings in PicoMarkdownView (there is no list
    /// container block), so consecutive items of one kind become one list.
    private static func shapes(of siblings: [BlockSnapshot], children: [BlockID: [BlockSnapshot]]) -> [Shape] {
        var result: [Shape] = []
        var index = 0
        while index < siblings.count {
            if case .listItem(let ordered, _, _) = siblings[index].kind {
                var items: [[Shape]] = []
                while index < siblings.count, case .listItem(let itemOrdered, _, _) = siblings[index].kind, itemOrdered == ordered {
                    let item = siblings[index]
                    var content: [Shape] = []
                    let text = inlineText(item)
                    if !text.isEmpty { content.append(.paragraph(text)) }
                    content += shapes(of: children[item.id] ?? [], children: children)
                    items.append(content)
                    index += 1
                }
                result.append(.list(ordered: ordered, items: items))
                continue
            }
            result.append(shape(of: siblings[index], children: children))
            index += 1
        }
        return result
    }

    private static func shape(of block: BlockSnapshot, children: [BlockID: [BlockSnapshot]]) -> Shape {
        switch block.kind {
        case .paragraph:
            return .paragraph(inlineText(block))
        case .heading(let level):
            return .heading(level: level, text: inlineText(block))
        case .fencedCode(let language):
            return .code(language: normalizeLanguage(language), text: normalizeCode(block.codeText ?? ""))
        case .blockquote:
            // A quote's own text precedes any child block; cmark has it as a paragraph.
            var content: [Shape] = []
            let own = inlineText(block)
            if !own.isEmpty { content.append(.paragraph(own)) }
            content += shapes(of: children[block.id] ?? [], children: children)
            return .quote(content)
        case .horizontalRule:
            return .rule
        case .table:
            return .other("table")
        case .math:
            return .other("math")
        case .footnoteDefinition:
            return .other("footnote")
        case .unknown:
            return .other("unknown")
        case .listItem:
            return .other("list item")
        }
    }

    // MARK: cmark-gfm (swift-markdown)

    static func cmark(_ markdown: String) -> [Shape] {
        // Smart punctuation is a cmark option, not CommonMark: the spec's
        // expected output keeps `--` and straight quotes as typed.
        Document(parsing: markdown, options: [.disableSmartOpts]).children.map(shape)
    }

    private static func shape(_ markup: Markup) -> Shape {
        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level, text: normalize(plainText(heading)))
        case let paragraph as Paragraph:
            return .paragraph(normalize(plainText(paragraph)))
        case let code as CodeBlock:
            return .code(language: normalizeLanguage(code.language), text: normalizeCode(code.code))
        case let quote as BlockQuote:
            return .quote(quote.children.map(shape))
        case let list as UnorderedList:
            return .list(ordered: false, items: list.children.map { $0.children.map(shape) })
        case let list as OrderedList:
            return .list(ordered: true, items: list.children.map { $0.children.map(shape) })
        case is ThematicBreak:
            return .rule
        case let html as HTMLBlock:
            return .html(html.rawHTML)
        case is Table:
            return .other("table")
        default:
            return .other(String(describing: type(of: markup)))
        }
    }

    /// Plain text the way PicoMarkdownView's inline runs carry it: code spans
    /// and raw HTML as their text, breaks as spaces, links and emphasis as
    /// their contents.
    private static func plainText(_ markup: Markup) -> String {
        switch markup {
        case let text as Text:
            return text.string
        case let code as InlineCode:
            return code.code
        case is SoftBreak, is LineBreak:
            return " "
        case let html as InlineHTML:
            return html.rawHTML
        default:
            return markup.children.map(plainText).joined()
        }
    }
}
