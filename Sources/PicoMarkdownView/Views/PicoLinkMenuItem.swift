#if os(macOS)
import AppKit

@MainActor
final class PicoLinkMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: nil, keyEquivalent: "")
        target = self
        self.action = #selector(performAction)
    }

    required init(coder: NSCoder) {
        fatalError("Use init(_:action:)")
    }

    @objc private func performAction() {
        handler()
    }
}
#endif
