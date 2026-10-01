import XCTest
@testable import PicoMarkdownView

#if canImport(AppKit)
import AppKit

@MainActor
final class TextKitInteractionTests: XCTestCase {
    func testTextKit1LinksHoverAndSelection() async throws {
        let controller = TextKitStreamingController()
        try await checkInteractions(controller.makeTextKit1View(configuration: .default()), controller: controller)
    }

    func testTextKit2LinksHoverAndSelection() async throws {
        let controller = TextKitStreamingController()
        try await checkInteractions(controller.makeTextKit2View(configuration: .default()), controller: controller)
    }

    func testMathAttachmentsFitTableRowsAtBothWidthsAndScales() async throws {
        let markdown = "## Math and quotes\n\n| Formula | Value |\n| --- | --- |\n| $\\frac{1}{\\sqrt{x}}$ | $\\sum_{i=1}^{n} i$ |\n\n> ## Quoted heading\n> - **First item**\n> - Second item\n> ```swift\n> let x = 1\n> ```\n> After the code.\n\nFinal paragraph.\n"
        for width in [CGFloat(320), 800] {
            for scale in [CGFloat(1), 2] {
                let pipeline = MarkdownStreamingPipeline()
                _ = await pipeline.updateTextScale(scale)
                _ = await pipeline.feed(markdown)
                _ = await pipeline.finish()
                let blocks = await pipeline.blocksSnapshot()
                for usesTextKit2 in [false, true] {
                    let controller = TextKitStreamingController()
                    let view = usesTextKit2 ? controller.makeTextKit2View(configuration: .default()) : controller.makeTextKit1View(configuration: .default())
                    view.frame = NSRect(x: 0, y: 0, width: width, height: 1600)
                    view.appearance = NSAppearance(named: .aqua)
                    controller.update(textView: view, blocks: blocks, diffs: [], replaceToken: 1, configuration: .default())
                    view.drawsBackground = true
                    view.backgroundColor = .white
                    view.layoutSubtreeIfNeeded()
                    let layout = try XCTUnwrap(view.layoutManager)
                    let container = try XCTUnwrap(view.textContainer)
                    let storage = try XCTUnwrap(view.textStorage)
                    layout.ensureLayout(for: container)
                    let used = layout.usedRect(for: container)
                    XCTAssertGreaterThan(used.height, 0)
                    XCTAssertLessThan(used.height, view.bounds.height)
                    var attachmentCount = 0
                    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                        guard let attachment = value as? NSTextAttachment else { return }
                        attachmentCount += 1
                        let glyph = layout.glyphIndexForCharacter(at: range.location)
                        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                        XCTAssertGreaterThanOrEqual(line.height + 0.5, attachment.bounds.height,
                            "Table math clipped at width \(width), scale \(scale)")
                    }
                    XCTAssertEqual(attachmentCount, 2)
                    if let directory = ProcessInfo.processInfo.environment["PICO_LAYOUT_SNAPSHOT_DIR"] {
                        let rect = NSRect(x: 0, y: 0, width: width, height: ceil(used.maxY + 20))
                        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
                        view.cacheDisplay(in: rect, to: bitmap)
                        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        let path = URL(fileURLWithPath: directory).appendingPathComponent("layout-\(Int(width))-\(Int(scale))-tk\(usesTextKit2 ? 2 : 1).png")
                        try png.write(to: path)
                    }
                }
            }
        }
    }

    private func checkInteractions(_ view: NSTextView, controller: TextKitStreamingController) async throws {
        let pipeline = MarkdownStreamingPipeline()
        _ = await pipeline.feed("First [link](https://example.com) and @person.\n\n## Heading\n\n> Quote\n\nLast paragraph.\n")
        _ = await pipeline.finish()
        let blocks = await pipeline.blocksSnapshot()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 800)
        window.contentView = view
        controller.update(textView: view, blocks: blocks, diffs: [], replaceToken: 1, configuration: .default())
        view.layoutSubtreeIfNeeded()
        let storage = try XCTUnwrap(view.textStorage)
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        let selection = NSRange(location: 0, length: storage.length)
        view.setSelectedRange(selection)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(view.isSelectable)

        var taps: [(URL, String)] = []
        controller.installLinkHandler(on: view) { taps.append(($0, $1)) }
        var hovers: [(URL?, String, CGRect?)] = []
        controller.installHoverHandler(on: view) { hovers.append(($0, $1, $2)) }
        for (label, url) in [("link", "https://example.com"), ("@person", "pico-tag:///%40/person")] {
            let range = (storage.string as NSString).range(of: label)
            XCTAssertNotEqual(range.location, NSNotFound)
            let link = try XCTUnwrap(storage.attribute(.link, at: range.location, effectiveRange: nil))
            view.clicked(onLink: link, at: range.location)
            XCTAssertEqual(taps.last?.0.absoluteString, url)
            XCTAssertEqual(taps.last?.1, label)

            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var expected = layout.boundingRect(forGlyphRange: glyphs, in: container)
            expected.origin.x += view.textContainerInset.width
            expected.origin.y += view.textContainerInset.height
            let point = CGPoint(x: expected.midX, y: expected.midY)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0))
            view.mouseMoved(with: event)
            XCTAssertEqual(hovers.last?.0?.absoluteString, url)
            XCTAssertEqual(hovers.last?.1, label)
            XCTAssertEqual(hovers.last?.2, expected)
            XCTAssertTrue(try XCTUnwrap(hovers.last?.2).contains(point))
            let count = hovers.count
            view.mouseMoved(with: event)
            XCTAssertEqual(hovers.count, count)
        }
        let emptyPoint = CGPoint(x: view.bounds.maxX - 1, y: view.bounds.maxY - 1)
        let exit = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(emptyPoint, to: nil),
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0))
        view.mouseMoved(with: exit)
        XCTAssertNil(hovers.last?.0)
        XCTAssertNil(hovers.last?.2)
    }
}
#endif
