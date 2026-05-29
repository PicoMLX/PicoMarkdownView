import SwiftUI

// MARK: - Host-facing view modifiers

public extension View {
    /// Handles taps on ordinary Markdown links (`[text](url)`) and, when no
    /// ``onTagTap(_:)`` is set, inline-tag taps too (delivered as a
    /// `pico-tag://` URL). Routes through SwiftUI's `openURL` action, so it is
    /// order-independent and composes with the other Pico modifiers.
    func onOpenLink(_ handler: @escaping (URL) -> OpenURLAction.Result) -> some View {
        environment(\.openURL, OpenURLAction { url in
            return handler(url)
        })
    }

    func onOpenLink(_ handler: @escaping (URL) -> Void) -> some View {
        onOpenLink { url in
            handler(url)
            return .handled
        }
    }

    /// Routes taps on inline tags (`@mentions`, `#hashtags`, `[[wiki-links]]`,
    /// `$tickers`, …) to a typed handler that receives the decoded ``Tag``.
    /// When set, tag taps go here instead of the ``onOpenLink(_:)``/`openURL`
    /// path; ordinary links still route through `openURL`. When *not* set, tag
    /// taps fall back to `openURL` carrying the `pico-tag://` URL.
    func onTagTap(_ handler: @escaping (Tag) -> Void) -> some View {
        environment(\.picoOnTagTap, handler)
    }

    /// Reports hover enter/exit over inline tags (**macOS only** — no-op on
    /// iOS). On enter the handler receives the decoded ``Tag`` and its bounding
    /// rect in the view's coordinate space (anchor a popover against it); on
    /// exit it receives `(nil, nil)`.
    func onTagHover(_ handler: @escaping (Tag?, CGRect?) -> Void) -> some View {
        environment(\.picoOnTagHover, handler)
    }

    /// Reports hover enter/exit over ordinary `[text](url)` links (**macOS
    /// only** — no-op on iOS). On enter the handler receives the link `URL` and
    /// its bounding rect; on exit it receives `(nil, nil)`. Inline-tag links
    /// are reported via ``onTagHover(_:)`` instead.
    func onLinkHover(_ handler: @escaping (URL?, CGRect?) -> Void) -> some View {
        environment(\.picoOnLinkHover, handler)
    }

    /// Reports the rendered content size whenever it changes — e.g. when
    /// streaming adds a newline and the content grows taller. De-duplicated so
    /// it only fires when the size actually changes.
    func onContentSize(_ handler: @escaping (CGSize) -> Void) -> some View {
        environment(\.picoOnContentSize, handler)
    }
}

// MARK: - Environment plumbing
//
// The Pico callbacks live in the environment (like SwiftUI's own `openURL`) so
// the modifiers above are order-independent: they can appear anywhere in the
// chain, in any order, before or after standard `View` modifiers such as
// `.padding()` or `.id(_:)`. `PicoMarkdownView` reads them back via
// `@Environment` in its `body`.

// `defaultValue` is a *computed* static property (not a stored `static let`):
// under Swift 6 strict concurrency a stored static of a non-Sendable type (a
// closure) is flagged as shared mutable global state. A computed property has
// no storage, so there is nothing to share — and it is exactly the shape the
// `EnvironmentKey` protocol requires (`static var defaultValue: Value { get }`).
private struct PicoOnTagTapKey: EnvironmentKey {
    static var defaultValue: ((Tag) -> Void)? { nil }
}

private struct PicoOnTagHoverKey: EnvironmentKey {
    static var defaultValue: ((Tag?, CGRect?) -> Void)? { nil }
}

private struct PicoOnLinkHoverKey: EnvironmentKey {
    static var defaultValue: ((URL?, CGRect?) -> Void)? { nil }
}

private struct PicoOnContentSizeKey: EnvironmentKey {
    static var defaultValue: ((CGSize) -> Void)? { nil }
}

extension EnvironmentValues {
    var picoOnTagTap: ((Tag) -> Void)? {
        get { self[PicoOnTagTapKey.self] }
        set { self[PicoOnTagTapKey.self] = newValue }
    }

    var picoOnTagHover: ((Tag?, CGRect?) -> Void)? {
        get { self[PicoOnTagHoverKey.self] }
        set { self[PicoOnTagHoverKey.self] = newValue }
    }

    var picoOnLinkHover: ((URL?, CGRect?) -> Void)? {
        get { self[PicoOnLinkHoverKey.self] }
        set { self[PicoOnLinkHoverKey.self] = newValue }
    }

    var picoOnContentSize: ((CGSize) -> Void)? {
        get { self[PicoOnContentSizeKey.self] }
        set { self[PicoOnContentSizeKey.self] = newValue }
    }
}
