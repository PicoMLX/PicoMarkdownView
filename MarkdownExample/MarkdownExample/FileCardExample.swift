#if os(macOS)
import AppKit
import Foundation
import Observation
import PicoMarkdownView
import UniformTypeIdentifiers

/// The example app creates and resolves an artifact; the renderer receives only
/// its opaque reference, display metadata and explicit action callbacks.
@MainActor
@Observable
final class FileCardExample {
    let file = PicoFileAttachment(
        id: "example-report",
        referenceURL: URL(string: "sandbox:/mnt/data/Report.md")!,
        filename: "Report.md",
        typeDescription: "Markdown")
    private(set) var localURL: URL?

    func createFile() async throws {
        file.state = .creating
        file.byteCount = nil
        localURL = nil
        try await Task.sleep(for: .seconds(2))
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicoFileCard-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Report.md")
        let data = Data(Self.report.utf8)
        try data.write(to: url, options: .atomic)
        localURL = url
        file.byteCount = data.count
        file.state = .ready
    }

    func perform(_ action: PicoFileCardAction, preview: (URL) -> Void,
                 onError: @escaping @MainActor (String) -> Void) {
        guard action.file.id == file.id, file.state == .ready, let localURL else {
            onError(String(localized: "The example file is not ready.", table: "FileCardExample"))
            return
        }
        switch action.kind {
        case .preview:
            preview(localURL)
        case .download:
            saveCopy(of: localURL, onError: onError)
        }
    }

    private func saveCopy(of sourceURL: URL, onError: @escaping @MainActor (String) -> Void) {
        let data: Data
        do { data = try Data(contentsOf: sourceURL) }
        catch { onError(error.localizedDescription); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: sourceURL.pathExtension) ?? .data]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = file.filename
        let completion: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            panel.orderOut(nil)
            do { try data.write(to: url, options: .atomic) }
            catch { onError(error.localizedDescription) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private static let report = """
    # Example report

    This file was created by the example app and is available for preview or download.

    - The file card represents one artifact between native Markdown paragraphs.
    - Its filename and source reference stay stable while it becomes ready.
    - Preview opens this actual Markdown file with Quick Look.
    - Download saves these same bytes to the location you choose.

    """
}
#endif
