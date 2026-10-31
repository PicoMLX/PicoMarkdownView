#if os(macOS) && canImport(JavaScriptCore)
import Foundation
import Testing
@testable import PicoMarkdownView

@Suite("Hosted diagram theme isolation")
struct PeleVectorThemeTests {
    private static let kanban = """
    kanban
    todo[Todo]
      card[Update Database Function]@{ ticket: MC-2037, assigned: 'knsv', priority: 'High' }
    """

    @Test("Hosted Kanban retains visible card and column backgrounds", arguments: [PeleAppearance.light, .dark], [true, false])
    func kanbanUsesLayeredSurfaces(appearance: PeleAppearance, usesCodeTheme: Bool) async throws {
        let base = MarkdownRenderTheme.default()
        let theme = usesCodeTheme ? base : base.withCodeHighlighting(codeBlockTheme: nil, codeHighlighter: nil)
        let renderer = try #require(PeleRenderer.shared)
        let palette = PeleDiagramProvider.peleTheme(for: theme, appearance: appearance)
        let bitmapOptions = PeleRenderOptions(fontSize: theme.bodyFont.pointSize,
                                              fontFamily: "sans-serif", maxWidth: 360, theme: palette)
        let vectorOptions = PeleDiagramProvider.vectorRenderOptions(for: theme, appearance: appearance, maxWidth: 360)
        let baseline = try await renderer.render(Self.kanban, options: bitmapOptions)
        let hosted = try await renderer.render(Self.kanban, options: vectorOptions)

        #expect(hosted.type == "kanban")
        #expect(hosted.width == baseline.width && hosted.height == baseline.height,
                "Changing the hosted backgrounds must not relayout the board")
        try expectBackgrounds(in: hosted.svg, cards: #require(palette["surface"]), columns: #require(palette["surface-alt"]))
        try expectBackgrounds(in: baseline.svg, cards: #require(palette["bg"]), columns: #require(palette["surface"]))
        #expect(hosted.svg.contains("pele-priority-high"), "Priority markings must survive the theme adjustment")

        let afterHosted = try await renderer.render(Self.kanban, options: bitmapOptions)
        #expect(afterHosted == baseline, "A hosted render must not mutate the bitmap/iOS palette")
    }

    @Test("Kanban frontmatter and comments do not bypass its hosted theme")
    func recognizesKanbanAfterFrontmatter() async throws {
        let renderer = try #require(PeleRenderer.shared)
        let theme = MarkdownRenderTheme.default()
        let palette = PeleDiagramProvider.peleTheme(for: theme, appearance: .dark)
        let source = """
        ---
        config:
          kanban:
            ticketBaseUrl: 'https://example.com/#TICKET#'
        ---
        %% The diagram type is below metadata and a comment.
        \(Self.kanban)
        """
        let options = PeleDiagramProvider.vectorRenderOptions(for: theme, appearance: .dark, maxWidth: 360)
        let result = try await renderer.render(source, options: options)
        #expect(result.type == "kanban")
        try expectBackgrounds(in: result.svg, cards: #require(palette["surface"]), columns: #require(palette["surface-alt"]))
    }

    @Test("Hosted theme changes leave C4 and flowchart SVG identical", arguments: [PeleAppearance.light, .dark])
    func unrelatedDiagramsRemainIdentical(appearance: PeleAppearance) async throws {
        let renderer = try #require(PeleRenderer.shared)
        let theme = MarkdownRenderTheme.default()
        let baselineOptions = PeleRenderOptions(fontSize: theme.bodyFont.pointSize,
                                                fontFamily: "sans-serif", maxWidth: 360,
                                                theme: PeleDiagramProvider.peleTheme(for: theme, appearance: appearance))
        let hostedOptions = PeleDiagramProvider.vectorRenderOptions(for: theme, appearance: appearance, maxWidth: 360)
        let sources = [
            """
            C4Context
              title Banking System
              Person(customer, "Customer", "Uses the bank")
              System(bank, "Bank", "Manages accounts")
              Rel(customer, bank, "Uses")
            """,
            "flowchart LR\n  A[Start] --> B{Check} --> C[Finish]\n  B --> D[Other]"
        ]
        for source in sources {
            let baseline = try await renderer.render(source, options: baselineOptions)
            let hosted = try await renderer.render(source, options: hostedOptions)
            #expect(hosted == baseline, "\(baseline.type) must keep every SVG color, size, and element unchanged")
        }
    }

    private func expectBackgrounds(in svg: String, cards: String, columns: String) throws {
        let document = try #require(PeleSVGDocument(svg: svg))
        let cardRects = backgroundRects(in: document.root, groupClass: "pele-card")
        let columnRects = backgroundRects(in: document.root, groupClass: "pele-column")
        try #require(!cardRects.isEmpty && !columnRects.isEmpty, "The SVG must contain real Kanban background rectangles")
        #expect(cardRects.allSatisfy { $0.attributes["fill"] == cards }, "Every Kanban card must retain its background fill")
        #expect(columnRects.allSatisfy { $0.attributes["fill"] == columns }, "Every Kanban column must retain its background fill")
    }

    private func backgroundRects(in element: PeleSVGElement, groupClass: String) -> [PeleSVGElement] {
        let children = element.children.compactMap { node -> PeleSVGElement? in
            if case let .element(child) = node { return child }
            return nil
        }
        if element.attributes["class"]?.split(whereSeparator: { $0.isWhitespace }).contains(Substring(groupClass)) == true {
            return children.filter { $0.name == "rect" }
        }
        return children.flatMap { backgroundRects(in: $0, groupClass: groupClass) }
    }
}
#endif
