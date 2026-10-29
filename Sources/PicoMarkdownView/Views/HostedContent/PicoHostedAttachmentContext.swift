#if os(macOS)
import Foundation
import Observation

/// Layout and selection supplied by the surrounding TextKit document.
@MainActor
@Observable
public final class PicoHostedAttachmentContext: NSObject {
    public private(set) var availableWidth: CGFloat = 1
    public private(set) var isSelected = false

    func update(availableWidth: CGFloat, isSelected: Bool) {
        let width = availableWidth.isFinite ? max(1, availableWidth) : 1
        if abs(self.availableWidth - width) > 0.5 { self.availableWidth = width }
        if self.isSelected != isSelected { self.isSelected = isSelected }
    }
}
#endif
