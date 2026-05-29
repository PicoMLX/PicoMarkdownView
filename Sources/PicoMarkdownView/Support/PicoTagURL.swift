import Foundation

/// Decoding side of the `pico-tag://` URL scheme that the inline-tag parser
/// emits (see `InlineParser.makePicoTagURL`). Tag runs are rendered as ordinary
/// links carrying a `pico-tag:///<prefix>/<identifier>` URL so they flow through
/// the same hit-testing path as `[text](url)` links; on tap/click the view
/// decodes that URL back into a `Tag` and routes it to the host's `onTagTap`.
///
/// Encoding (in `InlineParser`) percent-encodes both components with
/// `CharacterSet.alphanumerics` as the only allowed set, and uses an explicitly
/// empty host (`pico-tag:///…`, three slashes) so neither component lands in URL
/// host position. Decoding here mirrors that exactly: take the raw (still
/// percent-encoded) path, split on the literal separators, and percent-decode
/// each segment.
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

    /// Reconstructs a `Tag` from a tapped/hovered pico-tag URL plus the visible
    /// link text. The URL round-trips `prefix` and `identifier` exactly; the
    /// visible text supplies `displayText`. `rawText` cannot be recovered from
    /// the URL alone (the original bracket/paren syntax is not encoded), so it
    /// is set to the display text as a best effort — adequate for diagnostics
    /// and copy, which is all `rawText` is used for.
    static func makeTag(from url: URL, displayText: String) -> Tag? {
        guard let (prefix, identifier) = decode(url) else { return nil }
        let display = displayText.isEmpty ? prefix + identifier : displayText
        return Tag(prefix: prefix,
                   identifier: identifier,
                   displayText: display,
                   rawText: display)
    }
}
