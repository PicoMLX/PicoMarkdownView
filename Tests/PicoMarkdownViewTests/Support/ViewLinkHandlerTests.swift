import SwiftUI
import XCTest
@testable import PicoMarkdownView

@MainActor
final class ViewLinkHandlerTests: XCTestCase {
    func testModifierCompiles() {
        let view = Text("Link")
            .onOpenLink { _ in }
        XCTAssertNotNil(view)
    }
}
