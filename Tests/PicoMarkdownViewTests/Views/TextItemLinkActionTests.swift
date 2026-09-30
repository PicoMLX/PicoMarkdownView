#if canImport(UIKit)
import Testing
import UIKit
@testable import PicoMarkdownView

@Suite
struct TextItemLinkActionTests {
    @Test("Link actions route only when invoked", arguments: ["https://example.com", "pico-tag://%40/john"])
    @MainActor
    func linkActionsRouteWhenInvoked(destination: String) throws {
        let url = try #require(URL(string: destination))
        let view = UITextView()
        view.attributedText = NSAttributedString(string: "Before John Doe after")
        var received: [(URL, String)] = []
        let defaultAction = UIAction(title: "Open Link") { _ in Issue.record("Unexpected default action") }
        let action = TextItemLinkAction.make(for: .link(url), range: NSRange(location: 7, length: 8),
                                             in: view, defaultAction: defaultAction) { received.append(($0, $1)) }
        #expect(received.isEmpty)
        let button = UIButton()
        button.addAction(action, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        #expect(received.count == 1)
        #expect(received.first?.0 == url)
        #expect(received.first?.1 == "John Doe")
    }

    @Test("No handler preserves the system link action")
    @MainActor
    func noHandlerPreservesDefaultAction() throws {
        let view = UITextView()
        let defaultAction = UIAction { _ in }
        let url = try #require(URL(string: "https://example.com"))
        let action = TextItemLinkAction.make(for: .link(url), range: NSRange(location: 0, length: 0),
                                             in: view, defaultAction: defaultAction, handler: nil)
        #expect(action === defaultAction)
    }

    @Test("Non-link items preserve system actions")
    @MainActor
    func nonLinksPreserveDefaultAction() {
        let view = UITextView()
        let defaultAction = UIAction { _ in }
        for content in [UITextItem.Content.tag("topic"), .textAttachment(NSTextAttachment())] {
            let action = TextItemLinkAction.make(for: content, range: NSRange(location: 0, length: 0),
                                                 in: view, defaultAction: defaultAction) { _, _ in
                Issue.record("Non-link item routed as a link")
            }
            #expect(action === defaultAction)
        }
    }
}
#endif
