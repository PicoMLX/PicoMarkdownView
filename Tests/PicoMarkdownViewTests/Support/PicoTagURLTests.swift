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

    func testMakeTagUsesVisibleDisplayText() {
        let url = encode(prefix: "@", identifier: "u-2345")
        let tag = PicoTagURL.makeTag(from: url, displayText: "@John Doe")!
        XCTAssertEqual(tag.prefix, "@")
        XCTAssertEqual(tag.identifier, "u-2345")
        XCTAssertEqual(tag.displayText, "@John Doe")
    }

    func testMakeTagFallsBackWhenDisplayTextEmpty() {
        let url = encode(prefix: "#", identifier: "swift")
        let tag = PicoTagURL.makeTag(from: url, displayText: "")!
        XCTAssertEqual(tag.displayText, "#swift")
    }

    // MARK: - resolver(for:) — authentic Tag resolution

    /// The whole point of the registry fix: a tapped markdown-link tag must
    /// resolve to the parser's *authentic* Tag, with rawText equal to the exact
    /// source substring — not the lossy URL reconstruction.
    func testResolverReturnsAuthenticRawTextForMarkdownLinkForm() {
        let authentic = Tag(prefix: "@",
                            identifier: "u-2345",
                            displayText: "@John Doe",
                            rawText: "@[John Doe](u-2345)")
        let runs = [InlineRun(text: "@John Doe", style: [.tag, .link],
                              linkURL: "pico-tag:///%40/u-2345", tag: authentic)]
        let resolve = PicoTagURL.resolver(for: runs)

        let resolved = resolve(encode(prefix: "@", identifier: "u-2345"), "@John Doe")
        XCTAssertEqual(resolved, authentic)
        // The reconstruction would have produced "@John Doe" here; assert we did
        // NOT fall back to it.
        XCTAssertEqual(resolved?.rawText, "@[John Doe](u-2345)")
    }

    func testResolverFallsBackToReconstructionWhenNoMatchingRun() {
        let resolve = PicoTagURL.resolver(for: [])
        let resolved = resolve(encode(prefix: "@", identifier: "behlool"), "@behlool")
        // No authentic run present → best-effort reconstruction.
        XCTAssertEqual(resolved?.prefix, "@")
        XCTAssertEqual(resolved?.identifier, "behlool")
        XCTAssertEqual(resolved?.displayText, "@behlool")
    }

    func testResolverReturnsNilForNonPicoTagURL() {
        let resolve = PicoTagURL.resolver(for: [])
        XCTAssertNil(resolve(URL(string: "https://example.com")!, "example"))
    }

    func testResolverDisambiguatesByPrefixAndIdentifier() {
        let mention = Tag(prefix: "@", identifier: "ada", displayText: "@Ada", rawText: "@[Ada](ada)")
        let hashtag = Tag(prefix: "#", identifier: "ada", displayText: "#ada", rawText: "#ada")
        let runs = [
            InlineRun(text: "@Ada", style: [.tag, .link], linkURL: "pico-tag:///%40/ada", tag: mention),
            InlineRun(text: "#ada", style: [.tag, .link], linkURL: "pico-tag:///%23/ada", tag: hashtag),
        ]
        let resolve = PicoTagURL.resolver(for: runs)

        XCTAssertEqual(resolve(encode(prefix: "@", identifier: "ada"), "@Ada"), mention)
        XCTAssertEqual(resolve(encode(prefix: "#", identifier: "ada"), "#ada"), hashtag)
    }
}
