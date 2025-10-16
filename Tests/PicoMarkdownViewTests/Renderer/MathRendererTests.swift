import XCTest
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import PicoMarkdownView

final class MathRendererTests: XCTestCase {
    private var renderer: MathRenderer!

    override func setUp() async throws {
        renderer = MathRenderer()
    }

    func testParserBuildsFractionTree() throws {
        var parser = MathParser(string: "\\frac{1}{x^2}")
        let node = try parser.parse()

        guard case .fraction(let numerator, let denominator) = node else {
            return XCTFail("Expected fraction node")
        }

        if case .number(let value) = numerator {
            XCTAssertEqual(value, "1")
        } else {
            XCTFail("Expected numeric numerator")
        }

        guard case .scripts(let base, let superscript, _) = denominator else {
            return XCTFail("Expected scripts in denominator")
        }

        if case .symbol(let text, _) = base {
            XCTAssertEqual(text, "x")
        } else {
            XCTFail("Expected symbol base")
        }

        if case .number(let supValue)? = superscript {
            XCTAssertEqual(supValue, "2")
        } else {
            XCTFail("Expected superscript 2")
        }
    }

    func testRendererProducesCommands() async throws {
        let spec = MathRenderFontSpec(postScriptName: TestFonts.primaryFontName, pointSize: 18)
        let artifact = await renderer.render(tex: "x^{2}+\\sqrt{y}", display: false, font: spec)
        XCTAssertGreaterThan(artifact.commands.count, 0)
        XCTAssertGreaterThan(artifact.size.width, 0)
        XCTAssertGreaterThan(artifact.size.height, 0)
    }

    func testUnsupportedCommandFallsBackToText() async {
        let spec = MathRenderFontSpec(postScriptName: TestFonts.primaryFontName, pointSize: 16)
        let artifact = await renderer.render(tex: "\\foobar{1}", display: true, font: spec)
        XCTAssertTrue(artifact.commands.count > 0)
    }

    func testRendererCachesArtifacts() async {
        let spec = MathRenderFontSpec(postScriptName: TestFonts.primaryFontName, pointSize: 14)
        let first = await renderer.render(tex: "\\sum_{i=1}^{n} i", display: true, font: spec)
        let second = await renderer.render(tex: "\\sum_{i=1}^{n} i", display: true, font: spec)
        XCTAssertEqual(first, second)
    }
}

private enum TestFonts {
#if canImport(UIKit)
    static let primaryFontName: String = UIFont.preferredFont(forTextStyle: .body).fontName
#else
    static let primaryFontName: String = NSFont.preferredFont(forTextStyle: .body).fontName
#endif
}
