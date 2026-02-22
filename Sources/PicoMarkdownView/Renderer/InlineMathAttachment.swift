import Foundation
import SwiftMath

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
typealias InlineMathPlatformFont = UIFont
#elseif canImport(AppKit)
typealias InlineMathPlatformFont = NSFont
#endif

enum InlineMathAttachment {
    static func mathString(tex: String, display: Bool, baseFont: InlineMathPlatformFont) -> NSAttributedString {
        if let rendered = renderedAttachmentString(tex: tex, display: display, baseFont: baseFont) {
            return rendered
        }
        if let sanitized = sanitizedFallbackTeX(from: tex), sanitized != tex,
           let rendered = renderedAttachmentString(tex: sanitized, display: display, baseFont: baseFont) {
            return rendered
        }
        return NSAttributedString(string: tex)
    }

    static func sanitizedFallbackTeX(from tex: String) -> String? {
        let trimmed = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let unboxed = unwrapWrapper(command: "\\boxed", in: trimmed) {
            return unboxed
        }

        return nil
    }

    private static func renderedAttachmentString(tex: String,
                                                 display: Bool,
                                                 baseFont: InlineMathPlatformFont) -> NSAttributedString? {
        let fontSize = baseFont.pointSize
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

        let insetValue: CGFloat = 2
        imageGenerator.contentInsets = MTEdgeInsets(top: insetValue, left: 2, bottom: insetValue, right: 2)

        let (_, imageAny) = imageGenerator.asImage()
        guard let image = imageAny else { return nil }

        let attachment = NSTextAttachment()
        let size = image.size
        let baselineOffset = (size.height - fontSize) / 2
        let yOffset: CGFloat
        if display {
            yOffset = -baselineOffset
        } else {
            let inlineOffset = min(0, baseFont.descender + baselineOffset)
            yOffset = inlineOffset
        }
        attachment.bounds = CGRect(x: 0, y: yOffset, width: size.width, height: size.height)
        attachment.image = image
        return NSAttributedString(attachment: attachment)
    }

    private static func unwrapWrapper(command: String, in tex: String) -> String? {
        guard tex.hasPrefix(command) else { return nil }

        var index = tex.index(tex.startIndex, offsetBy: command.count)
        while index < tex.endIndex, tex[index].isWhitespace {
            index = tex.index(after: index)
        }

        guard index < tex.endIndex, tex[index] == "{" else { return nil }
        let contentStart = tex.index(after: index)
        var cursor = contentStart
        var depth = 1
        var escaped = false

        while cursor < tex.endIndex {
            let character = tex[cursor]

            if escaped {
                escaped = false
                cursor = tex.index(after: cursor)
                continue
            }

            if character == "\\" {
                escaped = true
                cursor = tex.index(after: cursor)
                continue
            }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let inner = String(tex[contentStart..<cursor])
                    let afterClose = tex.index(after: cursor)
                    let remainder = tex[afterClose...].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard remainder.isEmpty else { return nil }
                    return inner
                }
            }

            cursor = tex.index(after: cursor)
        }

        return nil
    }
}
