import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct PicoTextKitConfiguration {
    public var backgroundColor: MarkdownColor
    public var contentInsets: EdgeInsets
    public var isSelectable: Bool
    public var isScrollEnabled: Bool

    public init(backgroundColor: MarkdownColor = .clear,
                contentInsets: EdgeInsets = EdgeInsets(),
                isSelectable: Bool = true,
                isScrollEnabled: Bool = true) {
        self.backgroundColor = backgroundColor
        self.contentInsets = contentInsets
        self.isSelectable = isSelectable
        self.isScrollEnabled = isScrollEnabled
    }

    public static func `default`() -> PicoTextKitConfiguration {
        PicoTextKitConfiguration()
    }

    var platformColor: MarkdownColor {
        backgroundColor
    }

#if canImport(UIKit)
    var uiEdgeInsets: UIEdgeInsets {
        UIEdgeInsets(top: contentInsets.top,
                     left: contentInsets.leading,
                     bottom: contentInsets.bottom,
                     right: contentInsets.trailing)
    }
#elseif canImport(AppKit)
    var nsEdgeInsets: NSEdgeInsets {
        NSEdgeInsets(top: contentInsets.top,
                     left: contentInsets.leading,
                     bottom: contentInsets.bottom,
                     right: contentInsets.trailing)
    }

    var horizontalInset: CGFloat {
        max(contentInsets.leading, contentInsets.trailing)
    }

    var verticalInset: CGFloat {
        max(contentInsets.top, contentInsets.bottom)
    }
#endif
}
