#if canImport(JavaScriptCore)
import Foundation
import Testing
@testable import PicoMarkdownView

/// Exercises the real Pele bundle through JavaScriptCore. Apple platforms
/// only — the whole file compiles out where JavaScriptCore is unavailable.
@Suite
struct PeleRendererTests {
    private static let flowchart = """
    flowchart LR
      A[Mermaid text] --> B[SVG]
      B --> C{Decision}
      C -->|yes| D[Done]
    """

    @Test("Every bundled diagram type renders to sized SVG", arguments: [
        ("flowchart", "flowchart LR\n  A --> B"),
        ("sequence", "sequenceDiagram\n  Alice->>Bob: Hello\n  Bob-->>Alice: Hi"),
        ("pie", "pie title Pets\n  \"Dogs\" : 386\n  \"Cats\" : 85"),
        ("class", "classDiagram\n  Animal <|-- Duck\n  Animal : +int age"),
        ("state", "stateDiagram-v2\n  [*] --> Still\n  Still --> [*]"),
        ("er", "erDiagram\n  CUSTOMER ||--o{ ORDER : places"),
        ("gantt", "gantt\n  dateFormat YYYY-MM-DD\n  section S\n  Task :a1, 2024-01-01, 30d"),
        ("mindmap", "mindmap\n  root((root))\n    A\n    B"),
        ("timeline", "timeline\n  title History\n  2002 : LinkedIn\n  2004 : Facebook"),
        ("gitGraph", "gitGraph\n  commit\n  branch dev\n  commit\n  checkout main\n  merge dev"),
        ("journey", "journey\n  title My day\n  section Go to work\n    Make tea: 5: Me"),
        ("xychart", "xychart-beta\n  x-axis [a, b]\n  y-axis 0 --> 10\n  bar [3, 7]")
    ])
    func rendersBundledDiagramTypes(type: String, source: String) async throws {
        let renderer = try #require(PeleRenderer.shared)
        let result = try await renderer.render(source)
        #expect(result.type == type)
        #expect(result.svg.hasPrefix("<svg"))
        #expect(result.svg.hasSuffix("</svg>"))
        #expect(result.width > 0)
        #expect(result.height > 0)
        #expect(!result.svg.contains("var("), "\(type): CSS variables must be resolved")
    }

    @Test("Theme values replace Pele's CSS variables and their fallbacks")
    func themeValuesReplaceVariables() async throws {
        let renderer = try #require(PeleRenderer.shared)
        let themed = try await renderer.render(Self.flowchart, options: PeleRenderOptions(theme: [
            "bg": "#0a0b0c",
            "fg": "#fdfeff",
            "surface": "#112233",
            "line": "#445566",
            "font": "Avenir Next"
        ]))

        #expect(themed.svg.contains("#0a0b0c"), "background should be substituted")
        #expect(themed.svg.contains("#fdfeff"), "foreground should be substituted")
        #expect(themed.svg.contains("#112233"), "node surface should be substituted")
        #expect(themed.svg.contains("#445566"), "edge line color should be substituted")
        #expect(themed.svg.contains("font-family:Avenir Next"))
        #expect(!themed.svg.contains("#1f1f1f"), "Pele's default foreground must not leak through")
        #expect(!themed.svg.contains("--pele-"), "custom property declarations must be stripped")
        #expect(!themed.svg.contains("--_"), "private alias declarations must be stripped")
    }

    @Test("Unthemed variables fall back to Pele's defaults")
    func unthemedVariablesUseFallbacks() async throws {
        let renderer = try #require(PeleRenderer.shared)
        let result = try await renderer.render(Self.flowchart)
        #expect(result.svg.contains("#1f1f1f"), "default foreground fallback")
        #expect(result.svg.contains("#f3f3f3"), "default surface fallback")
        #expect(!result.svg.contains("var("))
    }

    @Test("Font size and width options reach Pele")
    func fontSizeAndWidthOptionsApply() async throws {
        let renderer = try #require(PeleRenderer.shared)
        let small = try await renderer.render(Self.flowchart, options: PeleRenderOptions(fontSize: 10))
        let large = try await renderer.render(Self.flowchart, options: PeleRenderOptions(fontSize: 24))
        #expect(large.width > small.width)
        #expect(large.svg.contains("font:24px"))

        let unconstrained = try await renderer.render(Self.flowchart)
        let narrow = try await renderer.render(Self.flowchart, options: PeleRenderOptions(maxWidth: 200))
        #expect(narrow.width < unconstrained.width, "a narrow host should produce a narrower (vertical) flowchart")
    }

    @Test("Rendering is deterministic for identical input")
    func renderingIsDeterministic() async throws {
        let renderer = try #require(PeleRenderer.shared)
        let options = PeleRenderOptions(fontSize: 15, maxWidth: 480, theme: ["accent": "#ff8800"])
        let first = try await renderer.render(Self.flowchart, options: options)
        let second = try await renderer.render(Self.flowchart, options: options)
        #expect(first == second)
    }

    @Test("Unrecognized source reports Pele's error code")
    func unrecognizedSourceThrows() async throws {
        let renderer = try #require(PeleRenderer.shared)
        await #expect(throws: PeleRenderError.self) {
            try await renderer.render("this is not a diagram")
        }
        do {
            _ = try await renderer.render("this is not a diagram")
            Issue.record("expected an error")
        } catch {
            #expect(error.code == "unsupported-diagram")
            #expect(!error.message.isEmpty)
        }
    }

    @Test("Malformed diagram source throws instead of crashing")
    func malformedSourceThrows() async throws {
        let renderer = try #require(PeleRenderer.shared)
        do {
            _ = try await renderer.render("flowchart LR\n  A --> [")
            Issue.record("expected a parse error")
        } catch {
            #expect(error.code != "error", "Pele should classify the failure: \(error)")
        }
    }

    @Test("Diagram text is escaped, never interpreted as markup")
    func diagramTextIsEscaped() async throws {
        let renderer = try #require(PeleRenderer.shared)
        let result = try await renderer.render("flowchart LR\n  A[\"<script>alert(1)</script> & <b>bold</b>\"] --> B")
        #expect(!result.svg.contains("<script"), "Pele drops unknown HTML tags from labels")
        #expect(result.svg.contains("alert(1)"))
        #expect(result.svg.contains("&amp;"), "ampersands are entity-escaped")
    }
}
#endif
