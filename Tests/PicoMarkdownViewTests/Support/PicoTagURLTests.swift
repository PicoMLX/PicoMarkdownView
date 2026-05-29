import XCTest
@testable import PicoMarkdownView

/// Round-trip tests for the `pico-tag://` URL scheme: the parser encodes inline
/// tags into these URLs, and the view decodes them on tap. The two sides must
/// stay in lock-step, so these exercise the decode against URLs shaped exactly
/// like `InlineParser.makePicoTagURL` produces.
final class PicoTagURLTests: XCTestCase {

    /// Mirror of the private `InlineParser.makePicoTagURL` so the test pins the
    /// exact wire format both sides depend on.
    private func encode(prefix: String, identifier: String) -> URL {
        let allowed = CharacterSet.alphanumerics
        let p = prefix.addingPercentEncoding(withAllowedCharacters: allowed) ?? prefix
        let i = identifier.addingPercentEncoding(withAllowedCharacters: allowed) ?? identifier
        return URL(string: "pico-tag:///\(p)/\(i)")!
    }

    func testDecodesMention() {
        let (prefix, identifier) = PicoTagURL.decode(encode(prefix: "@", identifier: "behlool"))!
        XCTAssertEqual(prefix, "@")
        XCTAssertEqual(identifier, "behlool")
    }

    func testDecodesHashtag() {
        let (prefix, identifier) = PicoTagURL.decode(encode(prefix: "#", identifier: "swift"))!
        XCTAssertEqual(prefix, "#")
        XCTAssertEqual(identifier, "swift")
    }

    func testDecodesPairedWikiPrefix() {
        let (prefix, identifier) = PicoTagURL.decode(encode(prefix: "[[", identifier: "Wiki Page"))!
        XCTAssertEqual(prefix, "[[")
        XCTAssertEqual(identifier, "Wiki Page")
    }

    func testRoundTripsAwkwardCharacters() {
        // Slashes, percent signs, userinfo/fragment separators inside the
        // identifier must survive because encoding allows alphanumerics only.
        for identifier in ["a/b/c", "100%", "u@host", "frag#ment", "a?b=c", "u-2345", "张伟"] {
            let (_, decoded) = PicoTagURL.decode(encode(prefix: "@", identifier: identifier))!
            XCTAssertEqual(decoded, identifier, "round-trip failed for \(identifier)")
        }
    }

    func testRejectsNonPicoTagScheme() {
        XCTAssertNil(PicoTagURL.decode(URL(string: "https://example.com/@behlool")!))
        XCTAssertNil(PicoTagURL.decode(URL(string: "mailto:john@example.com")!))
    }

    func testRejectsMalformedPath() {
        XCTAssertNil(PicoTagURL.decode(URL(string: "pico-tag:///onlyone")!))
        XCTAssertNil(PicoTagURL.decode(URL(string: "pico-tag:///a/b/c")!))
        XCTAssertNil(PicoTagURL.decode(URL(string: "pico-tag:///")!))
    }

    // MARK: - reference(from:)

    /// A tap on the markdown-link form surfaces the record ID from the parens
    /// (not the display text) plus the prefix — mirroring how a link surfaces
    /// its URL, not its label.
    func testReferenceUsesIdentifierFromParens() {
        let reference = PicoTagURL.reference(from: encode(prefix: "@", identifier: "u-2345"))
        XCTAssertEqual(reference, TagReference(prefix: "@", identifier: "u-2345"))
    }

    func testReferenceForBareForm() {
        let reference = PicoTagURL.reference(from: encode(prefix: "@", identifier: "behlool"))
        XCTAssertEqual(reference, TagReference(prefix: "@", identifier: "behlool"))
    }

    /// The prefix is part of the reference so a single handler can tell a
    /// `@id` mention from a `#id` hashtag that share the same identifier.
    func testReferenceDisambiguatesByPrefix() {
        XCTAssertEqual(PicoTagURL.reference(from: encode(prefix: "@", identifier: "ada")),
                       TagReference(prefix: "@", identifier: "ada"))
        XCTAssertEqual(PicoTagURL.reference(from: encode(prefix: "#", identifier: "ada")),
                       TagReference(prefix: "#", identifier: "ada"))
    }

    func testReferenceReturnsNilForNonPicoTagURL() {
        XCTAssertNil(PicoTagURL.reference(from: URL(string: "https://example.com")!))
        XCTAssertNil(PicoTagURL.reference(from: URL(string: "mailto:john@example.com")!))
    }

    func testReferenceRoundTripsAwkwardIdentifiers() {
        for identifier in ["a/b/c", "100%", "u@host", "frag#ment", "u-2345", "张伟"] {
            let reference = PicoTagURL.reference(from: encode(prefix: "@", identifier: identifier))
            XCTAssertEqual(reference?.identifier, identifier, "round-trip failed for \(identifier)")
        }
    }
}
