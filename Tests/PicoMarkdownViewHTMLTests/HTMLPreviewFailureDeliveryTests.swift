#if os(macOS)
import AppKit
import Testing
@testable import PicoMarkdownViewHTML

@MainActor
@Suite("Source-owned HTML failure delivery", .timeLimit(.minutes(1)))
struct HTMLPreviewFailureDeliveryTests {
    @Test("Same-source presentation changes preserve one deferred fallback", arguments: ["style", "suspend", "detach", "reattach"])
    func sameSourceChangesPreserveFailure(change: String) async throws {
        _ = NSApplication.shared
        let source = "<p>Source A</p>"
        let view = HTMLPreviewContainer()
        view.configure(source: source, style: .default)
        // Keep the native hierarchy real but offscreen: this regression does
        // not need a browser process or an asynchronous layout failure.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        var failures = 0
        view.onFailure = { failures += 1 }
        view.fail()
        let notification = try #require(view.pendingFailureNotification)
        switch change {
        case "style":
            var dark = HTMLPreviewStyle.default
            dark.isDark = true
            view.configure(source: source, style: dark)
        case "suspend": view.suspend()
        case "detach": window.contentView = nil
        default:
            window.contentView = nil
            window.contentView = view
        }
        await notification.value
        #expect(failures == 1)
        #expect(view.hasFailed && !view.isReady && view.page == nil)

        // Repeated native validation/configuration for this source occurrence
        // must not keep delivering an already acknowledged terminal fallback.
        view.fail()
        view.suspend()
        view.configure(source: source, style: .default)
        await view.pendingFailureNotification?.value
        #expect(failures == 1)
    }

    @Test("A real source replacement suppresses stale fallback, even when text returns to A", arguments: [false, true])
    func replacementSuppressesStaleFailure(returnToOriginalSource: Bool) async throws {
        _ = NSApplication.shared
        let view = HTMLPreviewContainer()
        let sourceA = "<p>Source A</p>"
        let sourceB = "<p>Source B</p>"
        var failures = 0
        view.onFailure = { failures += 1 }
        view.configure(source: sourceA, style: .default)
        view.fail()
        let staleNotification = try #require(view.pendingFailureNotification)
        view.configure(source: sourceB, style: .default)
        if returnToOriginalSource { view.configure(source: sourceA, style: .default) }
        await staleNotification.value
        #expect(failures == 0)
        #expect(!view.hasFailed)

        view.fail()
        let currentNotification = try #require(view.pendingFailureNotification)
        await currentNotification.value
        #expect(failures == 1, "A replacement source owns a new failure delivery")
    }

    @Test("A failure callback can replace the source without losing the replacement notification")
    func reentrantReplacementKeepsNewNotification() async throws {
        _ = NSApplication.shared
        let view = HTMLPreviewContainer()
        view.configure(source: "<p>First</p>", style: .default)
        var failures = 0
        var replacementNotification: Task<Void, Never>?
        view.onFailure = { [weak view] in
            failures += 1
            if failures == 1, let view {
                view.configure(source: "<p>Replacement</p>", style: .default)
                view.fail()
                replacementNotification = view.pendingFailureNotification
            }
        }
        view.fail()
        let firstNotification = try #require(view.pendingFailureNotification)
        await firstNotification.value
        let replacement = try #require(replacementNotification)
        await replacement.value
        #expect(failures == 2)
        #expect(view.hasFailed && view.pendingFailureNotification == nil)
    }

    @Test("Discarding the native view suppresses its deferred failure without retaining it")
    func discardedViewCannotDeliverFailure() async throws {
        _ = NSApplication.shared
        var view: HTMLPreviewContainer? = HTMLPreviewContainer()
        weak var discarded = view
        var failures = 0
        view?.onFailure = { failures += 1 }
        view?.configure(source: "<p>Discarded</p>", style: .default)
        view?.fail()
        let notification = try #require(view?.pendingFailureNotification)
        view = nil
        #expect(discarded == nil)
        await notification.value
        #expect(failures == 0)
    }

    @Test("An owner installed after failure receives the pending fallback once")
    func lateOwnerReceivesFailure() async throws {
        _ = NSApplication.shared
        let view = HTMLPreviewContainer()
        view.configure(source: "<p>Failed before owner installation</p>", style: .default)
        view.fail()
        #expect(view.pendingFailureNotification == nil)
        var failures = 0
        view.onFailure = { failures += 1 }
        let notification = try #require(view.pendingFailureNotification)
        await notification.value
        #expect(failures == 1)
        view.onFailure = { failures += 1 }
        await view.pendingFailureNotification?.value
        #expect(failures == 1)
    }

    @Test("A remounted native view delivers its own fallback for the shared preparation")
    func remountedOwnerReceivesItsOwnFailure() async throws {
        _ = NSApplication.shared
        let preparation = HTMLPreviewPreparation(source: "<p>Shared source</p>")
        var original: HTMLPreviewContainer? = HTMLPreviewContainer(preparation: preparation)
        weak var discarded = original
        var originalFailures = 0
        original?.onFailure = { originalFailures += 1 }
        original?.configure(source: preparation.source, style: .default)
        original?.fail()
        let firstNotification = try #require(original?.pendingFailureNotification)
        await firstNotification.value
        original = nil
        #expect(discarded == nil)
        #expect(originalFailures == 1)

        let remounted = HTMLPreviewContainer(preparation: preparation)
        var remountedFailures = 0
        remounted.onFailure = { remountedFailures += 1 }
        remounted.configure(source: preparation.source, style: .default)
        remounted.fail()
        let nextNotification = try #require(remounted.pendingFailureNotification)
        await nextNotification.value
        #expect(remountedFailures == 1, "A new native owner must not inherit the previous owner's delivered flag")
        #expect(originalFailures == 1)
    }
}
#endif
