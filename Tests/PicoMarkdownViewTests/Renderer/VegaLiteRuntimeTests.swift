#if os(macOS)
import CryptoKit
import Foundation
import JavaScriptCore
import Testing
@testable import PicoMarkdownView

@Suite("Vega-Lite compiler runtime")
struct VegaLiteRuntimeTests {
    @Test("Compiler cloning preserves Set aliases and graph identity without invoking toJSON")
    func compilerClonePreservesAggregationMetadata() throws {
        let context = try #require(JSContext())
        context.evaluateScript(VegaLiteRuntime.bootstrapScript)
        let result = context.evaluateScript("""
        (function() {
          let toJSONCalls = 0;
          Set.prototype.toJSON = function() { toJSONCalls++; return 'Set("median_yield")'; };
          const shared = {value: 7};
          const aliases = new Set(['median_yield', shared]);
          const input = {measures: {yield: {median: {aliases}}}, shared,
                         list: [shared, aliases, undefined, , NaN, Infinity, -Infinity, -0], optional: undefined};
          Object.defineProperty(input, '__proto__', {value: {column: true}, enumerable: true});
          input.self = input;
          const clone = structuredClone(input);
          const result = {
            aliasesAreSet: clone.measures.yield.median.aliases instanceof Set,
            aliasRetained: clone.measures.yield.median.aliases.has('median_yield'),
            noToJSON: toJSONCalls === 0,
            sharedObject: clone.shared === clone.list[0] && clone.shared !== shared,
            sharedSet: clone.measures.yield.median.aliases === clone.list[1],
            setObjectIdentity: clone.list[1].has(clone.shared),
            cycleRetained: clone.self === clone,
            undefinedRetained: Object.hasOwn(clone, 'optional') && clone.optional === undefined && clone.list[2] === undefined,
            holeRetained: clone.list.length === 8 && !(3 in clone.list),
            numbersRetained: Number.isNaN(clone.list[4]) && clone.list[5] === Infinity && clone.list[6] === -Infinity && Object.is(clone.list[7], -0),
            plainRecord: Object.getPrototypeOf(clone) === Object.prototype && Object.hasOwn(clone, '__proto__') && clone.__proto__.column === true
          };
          clone.shared.value = 9;
          clone.list[1].add('new_alias');
          result.originalUnchanged = shared.value === 7 && !aliases.has('new_alias');
          return result;
        })()
        """)
        try #require(context.exception == nil)
        let checks = try #require(result?.toDictionary() as? [String: Bool])
        for (name, passed) in checks { #expect(passed, "\(name)") }
        #expect(checks.count == 12)
    }

    @Test("The official barley trellis retains its aggregate scale and dispersed data points", arguments: [140, 336, 700])
    func barleyTrellisPreservesAggregateDomain(width: Int) async throws {
        let source = try Self.barleySource()
        let provider = VegaLiteChartProvider(theme: .default())
        let result = try #require(await provider.render(source: source, targetWidth: CGFloat(width)))
        #expect(!result.svg.contains("NaN"))
        #expect(!result.svg.contains("Infinity"))
        let document = try #require(PeleSVGDocument(svg: result.svg, dialect: .vega))
        let elements = Self.descendants(document.root)
        let points = elements.filter { $0.name == "path" && $0.attributes["aria-roledescription"] == "point" }
        #expect(points.count == 120)
        let positions = points.compactMap { element -> Double? in
            guard let transform = element.attributes["transform"], transform.hasPrefix("translate("), transform.hasSuffix(")") else { return nil }
            let coordinates = transform.dropFirst("translate(".count).dropLast()
            return coordinates.split(whereSeparator: { $0 == "," || $0.isWhitespace }).first.flatMap { Double($0) }
        }
        #expect(positions.count == points.count)
        #expect(positions.allSatisfy { $0.isFinite })
        #expect(Set(positions).count > 100, "The yields must not collapse onto x = 0")
        let axes = elements.filter { $0.attributes["aria-label"]?.hasPrefix("X-axis") == true }
        try #require(!axes.isEmpty)
        for axis in axes {
            let numericTicks = Self.descendants(axis).filter { element in
                guard element.name == "text" else { return false }
                let text = element.children.compactMap { node -> String? in
                    if case let .text(value) = node { return value }
                    return nil
                }.joined()
                return Double(text) != nil
            }
            #expect(numericTicks.count > 1, "The aggregate scale must have numeric domain ticks")
        }
    }

    private static func descendants(_ element: PeleSVGElement) -> [PeleSVGElement] {
        [element] + element.children.flatMap { node -> [PeleSVGElement] in
            if case let .element(child) = node { return descendants(child) }
            return []
        }
    }

    private static func barleySource() throws -> String {
        struct Manifest: Decodable {
            struct Entry: Decodable { var id: String; var sourceSHA256: String; var fenceIndex: Int? }
            var entries: [Entry]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf:
            root.appendingPathComponent("Tests/Fixtures/VegaLiteGallery/preview-manifest.json")))
        let entry = try #require(manifest.entries.first { $0.id == "trellis_barley" })
        let fenceIndex = try #require(entry.fenceIndex)
        let compressed = try Data(contentsOf: root.appendingPathComponent(
            "MarkdownExample/MarkdownExample/markdown files/Charts-Gallery-Preview.md.deflate"))
        let data = try (compressed as NSData).decompressed(using: .zlib) as Data
        let markdown = try #require(String(data: data, encoding: .utf8))
        var cursor = markdown.startIndex
        for index in 0...fenceIndex {
            let opening = try #require(markdown.range(of: "```vega-lite\n", range: cursor..<markdown.endIndex))
            let closing = try #require(markdown.range(of: "\n```\n", range: opening.upperBound..<markdown.endIndex))
            if index == fenceIndex {
                let source = String(markdown[opening.upperBound..<markdown.index(after: closing.lowerBound)])
                let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
                #expect(digest == entry.sourceSHA256)
                return source
            }
            cursor = closing.upperBound
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}
#endif
