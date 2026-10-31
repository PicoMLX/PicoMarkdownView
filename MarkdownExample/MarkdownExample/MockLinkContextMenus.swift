import Foundation
#if os(macOS)
import AppKit
#endif

/// Screenshot-style menus for the two fixture links. Every action is inert.
@MainActor
enum MockLinkContextMenus {
    static let webURL = URL(string: "https://example.com/pico-link-menu-demo")!
    static let fileURL = URL(fileURLWithPath: "/tmp/PicoMarkdownView-context-menu-demo.md")

    static func isDemoURL(_ url: URL) -> Bool {
        url == webURL || url == fileURL
    }

    #if os(macOS)
    static func customize(url: URL, label: String, menu: NSMenu) {
        guard isDemoURL(url) else { return }
        menu.removeAllItems()
        menu.autoenablesItems = false
        if url.isFileURL {
            addFileItems(to: menu)
        } else {
            addWebItems(to: menu)
        }
    }

    private static func addFileItems(to menu: NSMenu) {
        menu.addItem(item("Open file"))
        menu.addItem(item("Open in VS Code", symbol: "chevron.left.forwardslash.chevron.right"))

        let applications = NSMenu(title: "Open with")
        applications.autoenablesItems = false
        applications.addItem(item("VS Code", symbol: "chevron.left.forwardslash.chevron.right"))
        applications.addItem(item("Default app", symbol: "app"))
        applications.addItem(item("Finder", symbol: "folder"))
        applications.addItem(item("Terminal", symbol: "terminal"))
        applications.addItem(item("iTerm2", symbol: "terminal.fill"))
        applications.addItem(item("Xcode", symbol: "hammer"))
        let openWith = item("Open with")
        openWith.submenu = applications
        menu.addItem(openWith)

        menu.addItem(.separator())
        menu.addItem(item("Save as…"))
        menu.addItem(item("Copy path"))
        menu.addItem(item("Copy file contents"))
        menu.addItem(item("Reveal in Finder"))
    }

    private static func addWebItems(to menu: NSMenu) {
        let heading = NSMenuItem(title: "Open in", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(item("Code review", symbol: "arrow.triangle.branch"))
        menu.addItem(.separator())
        menu.addItem(item("New tab", symbol: "square"))
        menu.addItem(item("New window", symbol: "square.on.square"))
        menu.addItem(item("Default browser", symbol: "globe"))
        menu.addItem(.separator())
        menu.addItem(item("Copy link", symbol: "link"))
        menu.addItem(item("Save link as…", symbol: "square.and.arrow.down"))
    }

    private static func item(_ title: String, symbol: String? = nil) -> NSMenuItem {
        let item = MockMenuItem(title: title)
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    private final class MockMenuItem: NSMenuItem {
        init(title: String) {
            super.init(title: title, action: nil, keyEquivalent: "")
            target = self
            action = #selector(selectMockItem)
        }

        required init(coder: NSCoder) {
            fatalError("Use init(title:)")
        }

        @objc private func selectMockItem() {}
    }
    #endif
}
