import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@testable import PicoMarkdownView

@Suite("Opt-in SVG fence rendering")
struct SVGRendererTests {
    @Test("SVG is disabled by default and every theme copy retains the option")
    func themeCopiesPreserveOptIn() {
        let defaults = MarkdownRenderTheme.default()
        #expect(!defaults.svgRenderingEnabled)
        let enabled = defaults.withSVGRendering()
        #expect(enabled.svgRenderingEnabled)
        #expect(enabled.scaled(by: 1.5).svgRenderingEnabled)
        #expect(enabled.withMermaidRendering(.disabled).svgRenderingEnabled)
        #expect(enabled.withCodeHighlighting(codeBlockTheme: nil, codeHighlighter: nil).svgRenderingEnabled)
        #expect(!enabled.withSVGRendering(false).svgRenderingEnabled)
    }

    @Test("Only the SVG info-string language opts into the renderer", arguments: [
        ("svg", true), ("SVG title=Example", true), (" svg\tpreview", true),
        ("xml", false), ("html", false), ("svg+xml", false), ("swift", false), ("", false)
    ])
    func recognizesOnlySVG(_ entry: (String, Bool)) {
        #expect(SVGDiagramSupport.isSVGLanguage(entry.0) == entry.1)
    }

    @Test("SVG keeps complete code fallback and distinct closed-fence metadata")
    func closedFenceCarriesSource() async throws {
        let disabled = await render([document], theme: .default())
        let enabled = await render([document], theme: .default().withSVGRendering())
        let plainCode = try #require(disabled.first { $0.codeBlock?.language == "svg" })
        let svgCode = try #require(enabled.first { $0.codeBlock?.language == "svg" })
        #expect(await equivalentPresentation(svgCode.content, plainCode.content))
        #expect(svgCode.codeBlock == plainCode.codeBlock)
        #expect(svgCode.mermaidDiagram == nil)
        #expect(svgCode.math == nil)
        #expect(String(svgCode.content.characters).contains("<rect"))
        #expect(disabled.allSatisfy { $0.svgGraphic == nil })
#if os(macOS)
        #expect(svgCode.svgGraphic?.source == source + "\n")
        #expect(svgCode.svgGraphic?.language == "svg")
#else
        #expect(svgCode.svgGraphic == nil, "UIKit SVG remains its existing code presentation")
#endif
    }

    @Test("Open SVG fences stream as native code until they close")
    func noPresentationForOpenFence() async throws {
        let pipeline = MarkdownStreamingPipeline(theme: .default().withSVGRendering())
        _ = await pipeline.feed("Before.\n\n```svg\n" + source + "\n")
        let open = try #require(await pipeline.blocksSnapshot().first { $0.codeBlock?.language == "svg" })
        #expect(!open.snapshot.isClosed)
        #expect(open.svgGraphic == nil)
        #expect(String(open.content.characters).contains("<rect"))
        _ = await pipeline.feed("```\n\nAfter.\n\n")
        _ = await pipeline.finish()
        let closed = try #require(await pipeline.blocksSnapshot().first { $0.codeBlock?.language == "svg" })
        #expect(closed.snapshot.isClosed)
#if os(macOS)
        #expect(closed.svgGraphic?.source == source + "\n")
#else
        #expect(closed.svgGraphic == nil)
#endif
    }

    @Test("Single-character chunks and a single feed produce identical SVG presentation")
    func chunkedRenderingMatchesSingleShot() async {
        let theme = MarkdownRenderTheme.default().withSVGRendering()
        let single = await render([document], theme: theme)
        let streamed = await render(document.map(String.init), theme: theme)
        #expect(streamed.count == single.count)
        for (actual, expected) in zip(streamed, single) {
            #expect(await equivalentPresentation(actual.content, expected.content))
            // Compare all other block metadata without comparing the identities
            // of fresh dynamic-color providers embedded in attributed content.
            var metadata = actual
            metadata.content = expected.content
            #expect(metadata == expected)
        }
    }

    @Test("SVG and math stay separate and ordinary XML/HTML fences remain native code")
    func languageIsolation() async {
        let text = "```xml\n" + source + "\n```\n\n```html\n<div>Example</div>\n```\n\n```math\nx^2\n```\n\n"
        let blocks = await render([text], theme: .default().withSVGRendering())
        #expect(blocks.allSatisfy { $0.svgGraphic == nil })
        #expect(blocks.contains { $0.codeBlock?.language == "xml" })
        #expect(blocks.contains { $0.codeBlock?.language == "html" })
        #expect(blocks.contains { $0.math != nil })
    }

    /// ThemeColor creates a new adaptive provider at render time. Provider
    /// identity differs even when both light/dark colors and every text style
    /// match; compare their rendered values in both appearances instead.
    @MainActor
    private func equivalentPresentation(_ lhs: AttributedString, _ rhs: AttributedString) -> Bool {
#if canImport(AppKit)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { return false }
            var equal = false
            appearance.performAsCurrentDrawingAppearance {
                equal = resolvedColors(in: lhs) { $0.usingColorSpace(.sRGB) ?? $0 }
                    .isEqual(to: resolvedColors(in: rhs) { $0.usingColorSpace(.sRGB) ?? $0 })
            }
            if !equal { return false }
        }
#else
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            guard resolvedColors(in: lhs, resolve: { $0.resolvedColor(with: traits) })
                .isEqual(to: resolvedColors(in: rhs, resolve: { $0.resolvedColor(with: traits) })) else { return false }
        }
#endif
        return true
    }

    @MainActor
    private func resolvedColors(in content: AttributedString,
                                resolve: (MarkdownColor) -> MarkdownColor) -> NSAttributedString {
        let original = NSAttributedString.picoConverted(from: content)
        let result = NSMutableAttributedString(attributedString: original)
        original.enumerateAttributes(in: NSRange(location: 0, length: original.length)) { attributes, range, _ in
            for (key, value) in attributes {
                if let color = value as? MarkdownColor {
                    result.addAttribute(key, value: resolve(color), range: range)
                }
            }
        }
        return result
    }

    private let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 320 160\"><rect width=\"320\" height=\"160\" fill=\"#3973d5\"/></svg>"
    private var document: String { "Before 🧭.\n\n```svg\n" + source + "\n```\n\nAfter.\n\n" }

    private func render(_ chunks: [String], theme: MarkdownRenderTheme) async -> [RenderedBlock] {
        let pipeline = MarkdownStreamingPipeline(theme: theme)
        for chunk in chunks { _ = await pipeline.feed(chunk) }
        _ = await pipeline.finish()
        return await pipeline.blocksSnapshot()
    }
}
