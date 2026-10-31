#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import PicoMarkdownViewHTML

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HTMLPreviewOrderedListTests {
    struct ListCase: Sendable {
        let reversed: String
        let start: Int?
        let middleValue: Int?
        let expectedNumbers: [Int]
    }

    @Test("Native reversed-list markers match the expected descending ordinal values", arguments: [
        ListCase(reversed: "reversed", start: nil, middleValue: nil, expectedNumbers: [3, 2, 1]),
        ListCase(reversed: "reversed='false'", start: nil, middleValue: nil, expectedNumbers: [3, 2, 1]),
        ListCase(reversed: "reversed=''", start: 5, middleValue: nil, expectedNumbers: [5, 4, 3]),
        ListCase(reversed: "reversed", start: 5, middleValue: 2, expectedNumbers: [5, 2, 1])
    ])
    func renderedMarkersKeepDescendingNumbers(scenario: ListCase) async throws {
        _ = NSApplication.shared
        let start = scenario.start.map { " start='\($0)'" } ?? ""
        let middle = scenario.middleValue.map { " value='\($0)'" } ?? ""
        let source = """
        <style>
          body { background:white; color:black; font:24px/32px monospace; }
          ol { margin:0; padding-left:60px; list-style-position:outside; }
          li { height:32px; }
        </style>
        <ol \(scenario.reversed)\(start)><li>First</li><li\(middle)>Second</li><li>Third</li></ol>
        """
        let view = HTMLPreviewContainer()
        let outcome = AsyncStream.makeStream(of: Bool.self)
        view.onReady = { outcome.continuation.yield(true); outcome.continuation.finish() }
        view.onFailure = { outcome.continuation.yield(false); outcome.continuation.finish() }
        view.configure(source: source, style: .default)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 400, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer {
            view.onReady = nil
            view.onFailure = nil
            outcome.continuation.finish()
            view.suspend()
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        var events = outcome.stream.makeAsyncIterator()
        try #require(await events.next() == true)
        let page = try #require(view.page)
        let result = try await page.callJavaScript("""
            const list = document.querySelector('ol');
            return { reversed: list.reversed, reversedAttribute: list.getAttribute('reversed'), start: list.start,
                     values: Array.from(list.children, item => item.value),
                     display: getComputedStyle(list.firstElementChild).display,
                     markerType: getComputedStyle(list).listStyleType };
            """, contentWorld: .defaultClient) as? [String: Any]
        let values = try #require(result)
        #expect(values["reversed"] as? Bool == true)
        #expect(values["reversedAttribute"] as? String == "")
        #expect(values["start"] as? Int == (scenario.start ?? 1))
        #expect(values["values"] as? [Int] == [0, scenario.middleValue ?? 0, 0])
        #expect(values["display"] as? String == "list-item")
        #expect(values["markerType"] as? String == "decimal")

        // Compare actual browser-rendered marker pixels, rather than deriving
        // ordinals in JavaScript or trusting reflected start/value defaults.
        let actual = try await markerPixels(page)
        _ = try await page.callJavaScript("""
            const list = document.querySelector('ol');
            list.removeAttribute('reversed');
            Array.from(list.children).forEach((item, index) => item.value = numbers[index]);
            """, arguments: ["numbers": scenario.expectedNumbers], contentWorld: .defaultClient)
        let reference = try await markerPixels(page)
        try #require(actual.width == reference.width && actual.height == reference.height)
        #expect(actual.darkPixels > 0 && reference.darkPixels > 0, "Both snapshots must contain real native list markers")
        let changedComponents = zip(actual.components, reference.components).filter { pair in pair.0 != pair.1 }.count
        #expect(changedComponents == 0, "Native marker pixels must match the explicit expected descending numbers")
    }

    private func markerPixels(_ page: WebPage) async throws -> (width: Int, height: Int, components: [UInt8], darkPixels: Int) {
        let data = try await page.exported(as: .image(
            region: .rect(CGRect(x: 0, y: 0, width: 60, height: 96)),
            allowTransparentBackground: false, snapshotWidth: 60, afterScreenUpdates: true))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        var components: [UInt8] = []
        var darkPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let rgba = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                components.append(contentsOf: rgba.map { UInt8(min(255, max(0, ($0 * 255).rounded()))) })
                if rgba[0] < 0.5 && rgba[1] < 0.5 && rgba[2] < 0.5 && rgba[3] > 0.5 { darkPixels += 1 }
            }
        }
        return (bitmap.pixelsWide, bitmap.pixelsHigh, components, darkPixels)
    }
}
#endif
