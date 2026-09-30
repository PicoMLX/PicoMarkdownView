#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import PicoMarkdownView

@MainActor
final class DynamicTypeIntegrationTests: XCTestCase {
    func testTextKit2UsesConnectedStorage() {
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default())
        let snapshot = BlockSnapshot(id: 1, kind: .paragraph, inlineRuns: [], isClosed: true)
        let block = RenderedBlock(id: 1, kind: .paragraph, content: AttributedString("Hello\n"), snapshot: snapshot)
        controller.update(textView: view, blocks: [block], diffs: [], replaceToken: 1, configuration: .default())
        XCTAssertEqual(view.attributedText.string, "Hello\n")
        XCTAssertNotNil(view.textLayoutManager)
    }

    func testEnvironmentSizingUpdatesExistingSelectableView() async throws {
        let baseReady = expectation(description: "Initial content measured")
        baseReady.assertForOverFulfill = false
        var scaledReady: XCTestExpectation?
        var host: UIHostingController<AnyView>?
        var initialPointSize: CGFloat = 0
        var awaitingScale = false
        func content(size: DynamicTypeSize) -> AnyView {
            AnyView(ScrollView {
                PicoMarkdownView("First paragraph\n\nSecond paragraph", remoteImagesEnabled: false)
                .onContentSize { measured in
                    guard measured.height > 0, let root = host?.view,
                          let text = self.textView(in: root), text.attributedText.length > 0,
                          let font = text.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont else { return }
                    if awaitingScale {
                        if font.pointSize > initialPointSize * 1.5 { scaledReady?.fulfill() }
                    } else {
                        baseReady.fulfill()
                    }
                }
            }.environment(\.dynamicTypeSize, size))
        }
        let hostingController = UIHostingController(rootView: content(size: .large))
        host = hostingController
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.beginAppearanceTransition(true, animated: false)
        hostingController.endAppearanceTransition()
        defer { window.isHidden = true }
        hostingController.view.layoutIfNeeded()
        await fulfillment(of: [baseReady], timeout: 10)
        let initialView = try XCTUnwrap(textView(in: hostingController.view))
        XCTAssertGreaterThan(initialView.attributedText.length, 0)
        guard initialView.attributedText.length > 0 else { return }
        let initialFont = try XCTUnwrap(initialView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        initialPointSize = initialFont.pointSize
        let selection = NSRange(location: 0, length: initialView.attributedText.length)
        initialView.selectedRange = selection
        let scaleExpectation = expectation(description: "Scaled content measured")
        scaleExpectation.assertForOverFulfill = false
        scaledReady = scaleExpectation
        awaitingScale = true
        hostingController.rootView = content(size: .accessibility3)
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        await fulfillment(of: [scaleExpectation], timeout: 10)
        let scaledView = try XCTUnwrap(textView(in: hostingController.view))
        let scaledFont = try XCTUnwrap(scaledView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(initialView === scaledView)
        XCTAssertGreaterThan(scaledFont.pointSize, initialFont.pointSize * 1.5)
        XCTAssertEqual(scaledView.selectedRange, selection)
        XCTAssertTrue(scaledView.isSelectable)
        XCTAssertFalse(scaledView.isEditable)
    }

    private func textView(in view: UIView) -> UITextView? {
        if let text = view as? UITextView { return text }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }
}
#endif
