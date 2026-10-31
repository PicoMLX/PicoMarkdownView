#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import Testing
@testable import PicoMarkdownView

@Suite("macOS link context menus")
@MainActor
struct MacLinkContextMenuTests {
    @Test("The link under the pointer wins over the selected text and Open keeps host routing")
    func pointerTargetPreservesSelectionAndRouting() async throws {
        let (controller, view) = await makeView(
            "[Selected](https://example.com/selected) beside [Target](https://example.com/target).\n\n"
        )
        let window = makeWindow(containing: view)
        defer { window.close() }
        let storage = try #require(view.textStorage)
        let selection = (storage.string as NSString).range(of: "Selected")
        view.setSelectedRange(selection)
        let target = try #require(URL(string: "https://example.com/target"))
        var opened: [(URL, String)] = []
        var customized: [(URL, String)] = []
        controller.installLinkHandler(on: view) { opened.append(($0, $1)) }
        controller.installLinkContextMenu(on: view) { url, label, menu in
            customized.append((url, label))
            menu.addItem(withTitle: "Host destination", action: nil, keyEquivalent: "")
        }

        let segment = try #require(segments(for: "Target", in: view).first)
        let menu = try #require(view.menu(for: event(at: segment.center, in: view)))
        #expect(customized.count == 1)
        #expect(customized.first?.0 == target)
        #expect(customized.first?.1 == "Target")
        #expect(menu.item(withTitle: "Host destination") != nil)
        #expect(opened.isEmpty)
        #expect(view.selectedRange() == selection)
        #expect(view.textLayoutManager != nil)

        let item = try #require(menu.item(withTitle: "Open Link"))
        let action = try #require(item.action)
        #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
        #expect(opened.count == 1)
        #expect(opened.first?.0 == target)
        #expect(opened.first?.1 == "Target")
    }

    @Test("Every wrapped link segment has the same menu, while adjacent whitespace has none")
    func wrappedLinkAndWhitespaceHitTesting() async throws {
        let label = "A long link label that wraps across several lines in a narrow message"
        let (controller, view) = await makeView("[\(label)](https://example.com/wrapped)\n\n", width: 180)
        let window = makeWindow(containing: view)
        defer { window.close() }
        var labels: [String] = []
        controller.installLinkContextMenu(on: view) { _, label, menu in
            labels.append(label)
            menu.addItem(withTitle: "Wrapped destination", action: nil, keyEquivalent: "")
        }
        let rects = segments(for: label, in: view)
        try #require(rects.count > 1)
        for rect in rects {
            let menu = try #require(view.menu(for: event(at: rect.center, in: view)))
            #expect(menu.item(withTitle: "Wrapped destination") != nil)
        }
        #expect(labels == Array(repeating: label, count: rects.count))

        let last = try #require(rects.last)
        let whitespace = CGPoint(x: view.bounds.maxX - 2, y: last.midY)
        try #require(whitespace.x > last.maxX)
        let countBeforeWhitespace = labels.count
        let menu = view.menu(for: try event(at: whitespace, in: view))
        #expect(labels.count == countBeforeWhitespace)
        #expect(menu?.item(withTitle: "Wrapped destination") == nil)
        #expect(view.textLayoutManager != nil)
    }

    @Test("Menus distinguish file actions and avoid external browser actions for internal tags")
    func destinationSpecificDefaults() throws {
        let file = URL(fileURLWithPath: "/tmp/Pico Context Menu Fixture.md")
        let fileMenu = PicoLinkContextMenu.make(url: file, displayText: "Fixture", openLink: { _, _ in }, customize: nil)
        #expect(fileMenu.item(withTitle: "Open File") != nil)
        #expect(fileMenu.item(withTitle: "Copy Path") != nil)
        #expect(fileMenu.item(withTitle: "Reveal in Finder") != nil)
        #expect(fileMenu.item(withTitle: "Open in Default Browser") == nil)

        let path = try #require(URL(string: "/tmp/Pico%20Context%20Menu%20Fixture.md#L12"))
        var openedPath: URL?
        let pathMenu = PicoLinkContextMenu.make(url: path, displayText: "Fixture", openLink: { url, _ in
            openedPath = url
        }, customize: nil)
        #expect(pathMenu.item(withTitle: "Copy Path") != nil)
        let openPath = try #require(pathMenu.item(withTitle: "Open File"))
        #expect(NSApplication.shared.sendAction(try #require(openPath.action), to: openPath.target, from: openPath))
        #expect(openedPath == path)

        let remote = try #require(URL(string: "file://remote-host/share/fixture.md"))
        let remoteMenu = PicoLinkContextMenu.make(url: remote, displayText: "Remote", openLink: { _, _ in }, customize: nil)
        #expect(remoteMenu.item(withTitle: "Copy Path") == nil)
        #expect(remoteMenu.item(withTitle: "Copy File Contents") == nil)

        let relative = try #require(URL(string: "relative/fixture.md"))
        let relativeMenu = PicoLinkContextMenu.make(url: relative, displayText: "Relative", openLink: { _, _ in }, customize: nil)
        #expect(relativeMenu.item(withTitle: "Open File") == nil)

        let tag = try #require(URL(string: "pico-tag://mention/person"))
        let tagMenu = PicoLinkContextMenu.make(url: tag, displayText: "@person", openLink: { _, _ in }, customize: nil)
        #expect(tagMenu.item(withTitle: "Open in Default Browser") == nil)
    }

    @Test("An existing hosted table cell consults the current host menu and Open handler")
    func existingTableUsesUpdatedHandlers() async throws {
        let (controller, view) = await makeView("| Name | Value |\n| --- | --- |\n| [Table link](https://example.com/table) | Content |\n\n")
        controller.installLinkContextMenu(on: view) { _, _, menu in
            menu.addItem(withTitle: "Original host action", action: nil, keyEquivalent: "")
        }
        let storage = try #require(view.textStorage)
        var tableAttachment: PicoHostedAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if let attachment = value as? PicoHostedAttachment {
                tableAttachment = attachment
                stop.pointee = true
            }
        }
        let attachment = try #require(tableAttachment)
        attachment.update(availableWidth: 600, isSelected: false)
        let host = attachment.loadHostedView()
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 200)
        let window = makeWindow(containing: host)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let cell = try #require(descendants(of: host).compactMap { $0 as? PicoHostedTableCellTextView }
            .first { $0.string.contains("Table link") })
        let point = try #require(segments(for: "Table link", in: cell).first).center
        let initial = try #require(cell.menu(for: event(at: point, in: cell)))
        #expect(initial.item(withTitle: "Original host action") != nil)

        var opened: [(URL, String)] = []
        controller.installLinkHandler(on: view) { opened.append(($0, $1)) }
        controller.installLinkContextMenu(on: view) { _, _, menu in
            menu.addItem(withTitle: "Updated host action", action: nil, keyEquivalent: "")
        }
        let updated = try #require(cell.menu(for: event(at: point, in: cell)))
        #expect(updated.item(withTitle: "Original host action") == nil)
        #expect(updated.item(withTitle: "Updated host action") != nil)
        let item = try #require(updated.item(withTitle: "Open Link"))
        let action = try #require(item.action)
        #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
        #expect(opened.count == 1)
        #expect(opened.first?.0.absoluteString == "https://example.com/table")
        #expect(opened.first?.1 == "Table link")
        #expect(cell.textLayoutManager != nil)
        #expect(view.textLayoutManager != nil)
    }

    @Test("A row accessibility action presents the matching column and repeated link range")
    func rowAccessibilityActionPresentsExactLinkMenu() throws {
        let firstURL = try #require(URL(string: "https://example.com/first"))
        let secondURL = try #require(URL(string: "https://example.com/second"))
        let firstText = NSMutableAttributedString(string: "Shared", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        firstText.addAttribute(.link, value: firstURL, range: NSRange(location: 0, length: 6))
        let secondText = NSMutableAttributedString(string: "Shared and Shared", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        secondText.addAttribute(.link, value: firstURL, range: NSRange(location: 0, length: 6))
        let targetRange = NSRange(location: 11, length: 6)
        secondText.addAttribute(.link, value: secondURL, range: targetRange)
        let contents = [firstText, secondText].map { AttributedString.picoConverted(from: $0) }
        let row = PicoHostedTableRow(id: 0, cells: contents, source: [])
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 480, height: 150))
        let cells = contents.enumerated().map { column, content in
            let cell = PicoHostedTableCellTextView(usingTextLayoutManager: true)
            cell.frame = CGRect(x: CGFloat(column) * 240, y: 0, width: 240, height: 150)
            cell.isEditable = false
            cell.isSelectable = false
            cell.textContainerInset = .zero
            cell.textContainer?.lineFragmentPadding = 0
            cell.textContainer?.widthTracksTextView = false
            cell.update(content: content, width: 240, alignment: .left)
            container.addSubview(cell)
            row.registerLinkMenuPresenter(in: column) { [weak cell] link in
                cell?.showLinkContextMenu(for: link)
            }
            return cell
        }
        let window = makeWindow(containing: container)
        defer { window.close() }
        let menu = RecordingLinkContextMenu(title: "Recorded link menu")
        var requested: [(URL, String)] = []
        var opens = 0
        for cell in cells {
            cell.onOpenLink = { _ in opens += 1 }
            cell.onLinkContextMenu = { url, label in
                requested.append((url, label))
                return menu
            }
        }

        let target = try #require(row.links.first { $0.id == "1:11" })
        let targetRect = try #require(segments(in: cells[1], range: targetRange).first)
        row.showLinkMenu(for: target)
        #expect(requested.count == 1)
        #expect(requested.first?.0 == secondURL)
        #expect(requested.first?.1 == "Shared")
        #expect(menu.presentationCount == 1)
        #expect(menu.presentedView === cells[1])
        #expect(menu.presentedPoint == CGPoint(x: targetRect.minX, y: targetRect.maxY))
        #expect(menu.presentedPoint.x.isFinite && menu.presentedPoint.y.isFinite)

        let otherColumn = try #require(row.links.first { $0.id == "0:0" })
        row.showLinkMenu(for: otherColumn)
        #expect(requested.count == 2)
        #expect(requested.last?.0 == firstURL)
        #expect(requested.last?.1 == "Shared")
        #expect(menu.presentationCount == 2)
        #expect(menu.presentedView === cells[0])

        // An action retained across a content change must not target a different URL.
        row.showLinkMenu(for: PicoHostedTableLink(id: target.id, url: firstURL, label: target.label))
        #expect(menu.presentationCount == 2)
        #expect(requested.count == 2)
        #expect(opens == 0)
        #expect(cells.allSatisfy { $0.textLayoutManager != nil })
    }

    private func makeView(_ markdown: String, width: CGFloat = 600) async -> (TextKitStreamingController, NSTextView) {
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        view.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed(markdown)
        _ = await pipeline.finish()
        controller.update(textView: view, blocks: await pipeline.blocksSnapshot(), diffs: [],
                          replaceToken: 1, configuration: .default())
        return (controller, view)
    }

    private func makeWindow(containing view: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func event(at point: CGPoint, in view: NSView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .rightMouseDown,
                                       location: view.convert(point, to: nil),
                                       modifierFlags: [], timestamp: 0,
                                       windowNumber: view.window?.windowNumber ?? 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func segments(for label: String, in view: NSTextView) -> [CGRect] {
        guard let storage = view.textStorage else { return [] }
        return segments(in: view, range: (storage.string as NSString).range(of: label))
    }

    private func segments(in view: NSTextView, range: NSRange) -> [CGRect] {
        guard let manager = view.textLayoutManager, let content = manager.textContentManager,
              range.location != NSNotFound,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        manager.ensureLayout(for: content.documentRange)
        var rects: [CGRect] = []
        manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
            if rect.width > 0, rect.height > 0 {
                rects.append(rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y))
            }
            return true
        }
        return rects
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class RecordingLinkContextMenu: NSMenu {
    private(set) var presentationCount = 0
    private(set) var presentedPoint = CGPoint.zero
    private(set) weak var presentedView: NSView?

    override func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        presentationCount += 1
        presentedPoint = location
        presentedView = view
        return true
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
#endif
