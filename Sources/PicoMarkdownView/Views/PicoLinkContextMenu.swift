#if os(macOS)
import AppKit

@MainActor
enum PicoLinkContextMenu {
    static func make(url: URL, displayText: String,
                     openLink: @escaping (URL, String) -> Void,
                     customize: ((URL, String, NSMenu) -> Void)?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let fileURL = localFileURL(for: url)
        menu.addItem(PicoLinkMenuItem(fileURL != nil ? "Open File" : "Open Link") {
            openLink(url, displayText)
        })

        if let fileURL {
            addFileActions(to: menu, url: fileURL)
        } else {
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                menu.addItem(PicoLinkMenuItem("Open in Default Browser") {
                    NSWorkspace.shared.open(url)
                })
            }
            menu.addItem(.separator())
            menu.addItem(PicoLinkMenuItem("Copy Link") { copy(url.absoluteString) })
        }
        customize?(url, displayText, menu)
        return menu
    }

    private static func localFileURL(for url: URL) -> URL? {
        if url.isFileURL {
            return ["", "localhost"].contains(url.host?.lowercased() ?? "") ? url : nil
        }
        // Markdown often uses /absolute/paths rather than file:// URLs.
        // Relative paths need a document base URL owned by the host app.
        guard url.scheme == nil, url.host == nil, url.path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: url.path)
    }

    private static func addFileActions(to menu: NSMenu, url: URL) {
        let workspace = NSWorkspace.shared
        let applications = Set(workspace.urlsForApplications(toOpen: url)).sorted {
            FileManager.default.displayName(atPath: $0.path)
                .localizedStandardCompare(FileManager.default.displayName(atPath: $1.path)) == .orderedAscending
        }
        if !applications.isEmpty {
            let submenu = NSMenu(title: "Open With")
            submenu.autoenablesItems = false
            let defaultApplication = workspace.urlForApplication(toOpen: url)
            for application in applications {
                let name = FileManager.default.displayName(atPath: application.path)
                let title = application == defaultApplication ? "\(name) (Default)" : name
                let item = PicoLinkMenuItem(title) {
                    Task {
                        do {
                            _ = try await workspace.open([url], withApplicationAt: application,
                                                         configuration: NSWorkspace.OpenConfiguration())
                        } catch {
                            NSAlert(error: error).runModal()
                        }
                    }
                }
                let icon = workspace.icon(forFile: application.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                submenu.addItem(item)
            }
            let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let isReadableFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isReadableFile(atPath: url.path)
        if isReadableFile {
            menu.addItem(PicoLinkMenuItem("Save As…") { saveFile(url) })
        }
        menu.addItem(PicoLinkMenuItem("Copy Path") { copy(url.path) })
        if isReadableFile {
            menu.addItem(PicoLinkMenuItem("Copy File Contents") { copyFileContents(url) })
        }
        let reveal = PicoLinkMenuItem("Reveal in Finder") {
            workspace.activateFileViewerSelecting([url])
        }
        reveal.isEnabled = FileManager.default.fileExists(atPath: url.path)
        menu.addItem(reveal)
    }

    private static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private static func copyFileContents(_ url: URL) {
        Task {
            do {
                let text = try await readText(url)
                copy(text)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private static func saveFile(_ url: URL) {
        Task {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = url.lastPathComponent
            panel.canCreateDirectories = true
            guard await panel.begin() == .OK, let destination = panel.url, destination != url else { return }
            do {
                try await writeCopy(of: url, to: destination)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @concurrent
    nonisolated private static func readText(_ url: URL) async throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @concurrent
    nonisolated private static func writeCopy(of url: URL, to destination: URL) async throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try data.write(to: destination, options: .atomic)
    }
}
#endif
