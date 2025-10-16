import Foundation
import SwiftMath

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum InlineMathAttachment {
    static func mathString(tex: String, display: Bool, fontSize: CGFloat) -> NSAttributedString {
        let mode: MTMathUILabelMode = display ? .display : .text
#if canImport(UIKit)
        let textColor = MTColor.label
#else
        let textColor = MTColor.labelColor
#endif

        let imageGenerator = MTMathImage(latex: tex,
                                         fontSize: fontSize,
                                         textColor: textColor,
                                         labelMode: mode,
                                         textAlignment: .left)

        let insetValue: CGFloat = display ? 6 : 2
        imageGenerator.contentInsets = MTEdgeInsets(top: insetValue, left: 2, bottom: insetValue, right: 2)

        let (_, imageAny) = imageGenerator.asImage()
        guard let image = imageAny else {
            return NSAttributedString(string: tex)
        }

        let attachment = NSTextAttachment()
        let size = image.size
        let baselineOffset = (size.height - fontSize) / 2
        attachment.bounds = CGRect(x: 0, y: -baselineOffset, width: size.width, height: size.height)
        attachment.image = image
        return NSAttributedString(attachment: attachment)
    }
}
