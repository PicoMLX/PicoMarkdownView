import Foundation

/// A tapped/hovered inline tag, reduced to the two pieces that are losslessly
/// recoverable from the link the renderer emits: the ``prefix`` (e.g. `"@"`,
/// `"#"`, `"[["`) and the ``identifier`` — the record ID / lookup key.
///
/// This mirrors how ordinary Markdown links work: `[display](url)` surfaces only
/// the `url` to ``View/onOpenLink(_:)``, not the display text, because the URL
/// is the routable key and the host owns the display side. Likewise a tag tap
/// surfaces only the routable key. For the markdown-link form
/// `@[John Doe](u-2345)` that key is `prefix: "@", identifier: "u-2345"`; for
/// the bare form `@behlool` it is `prefix: "@", identifier: "behlool"`.
///
/// The `prefix` is included (not just the identifier) so a single handler can
/// tell a `@u-2345` mention from a `#u-2345` hashtag.
public struct TagReference: Hashable, Sendable {
    /// The prefix that opened the tag — `"@"`, `"#"`, `"$"`, or a paired
    /// opening like `"[["`.
    public let prefix: String

    /// The bare identifier / record ID: the text in the parens for the
    /// markdown-link form (`@[John Doe](u-2345)` → `"u-2345"`), or the whole
    /// token for the bare form (`@behlool` → `"behlool"`).
    public let identifier: String

    public init(prefix: String, identifier: String) {
        self.prefix = prefix
        self.identifier = identifier
    }
}

/// Decoding side of the `pico-tag://` URL scheme that the inline-tag parser
/// emits (see `InlineParser.makePicoTagURL`). Tag runs are rendered as ordinary
/// links carrying a `pico-tag:///<prefix>/<identifier>` URL so they flow through
/// the same hit-testing path as `[text](url)` links; on tap/click the view
/// decodes that URL back into a ``TagReference`` and routes it to the host.
///
/// Encoding (in `InlineParser`) percent-encodes both components with
/// `CharacterSet.alphanumerics` as the only allowed set, and uses an explicitly
/// empty host (`pico-tag:///…`, three slashes) so neither component lands in URL
/// host position. Decoding here mirrors that exactly: take the raw (still
/// percent-encoded) path, split on the literal separators, and percent-decode
/// each segment. This round-trips `prefix` and `identifier` losslessly.
enum PicoTagURL {
    /// The URL scheme used for inline-tag links.
    static let scheme = "pico-tag"

    /// Decodes a `pico-tag:///<prefix>/<identifier>` URL into its components.
    /// Returns `nil` for any URL that is not a well-formed pico-tag URL.
    static func decode(_ url: URL) -> (prefix: String, identifier: String)? {
        guard url.scheme == scheme else { return nil }
        // Use the still-encoded path so the literal separators we wrote stay
        // distinct from any encoded slashes inside a component.
        let rawPath = url.path(percentEncoded: true)
        let segments = rawPath.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count == 2 else { return nil }
        guard let prefix = String(segments[0]).removingPercentEncoding,
              let identifier = String(segments[1]).removingPercentEncoding else { return nil }
        guard !prefix.isEmpty, !identifier.isEmpty else { return nil }
        return (prefix, identifier)
    }

    /// Maps a tapped/hovered pico-tag URL to its ``TagReference``. Returns `nil`
    /// for any URL that is not a well-formed pico-tag link (e.g. an ordinary
    /// `https://` link), so callers can route those elsewhere.
    static func reference(from url: URL) -> TagReference? {
        guard let (prefix, identifier) = decode(url) else { return nil }
        return TagReference(prefix: prefix, identifier: identifier)
    }
}
