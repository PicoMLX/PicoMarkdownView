import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A Sendable font specification that resolves to a platform font at render time.
///
/// Stores only `Sendable` values (CGFloat, enum cases). Call `resolved()` to
/// get the corresponding `MarkdownFont` (UIFont/NSFont).
public struct FontSpec: Sendable, Hashable {
    public let pointSize: CGFloat
    public let weight: Weight
    public let design: Design

    public enum Weight: Sendable, Hashable {
        case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black

        var platformWeight: MarkdownFont.Weight {
            switch self {
            case .ultraLight: return .ultraLight
            case .thin:       return .thin
            case .light:      return .light
            case .regular:    return .regular
            case .medium:     return .medium
            case .semibold:   return .semibold
            case .bold:       return .bold
            case .heavy:      return .heavy
            case .black:      return .black
            }
        }
    }

    public enum Design: Sendable, Hashable {
        case `default`
        case monospaced
        case serif
        case rounded
    }

    public init(size: CGFloat, weight: Weight = .regular, design: Design = .default) {
        self.pointSize = size
        self.weight = weight
        self.design = design
    }

    /// Resolve to a platform font.
    public func resolved() -> MarkdownFont {
        switch design {
        case .monospaced:
            return MarkdownFont.monospacedSystemFont(ofSize: pointSize, weight: weight.platformWeight)
        case .default, .serif, .rounded:
            #if canImport(UIKit)
            var descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
            descriptor = descriptor.addingAttributes([
                .size: pointSize
            ])
            if design == .serif {
                descriptor = descriptor.withDesign(.serif) ?? descriptor
            } else if design == .rounded {
                descriptor = descriptor.withDesign(.rounded) ?? descriptor
            }
            let font = UIFont(descriptor: descriptor, size: pointSize)
            if weight != .regular {
                if let weighted = font.fontDescriptor.withSymbolicTraits(weight == .bold || weight == .semibold || weight == .heavy || weight == .black ? .traitBold : []) {
                    return UIFont(descriptor: weighted, size: pointSize)
                }
            }
            return UIFont.systemFont(ofSize: pointSize, weight: weight.platformWeight)
            #else
            return NSFont.systemFont(ofSize: pointSize, weight: weight.platformWeight)
            #endif
        }
    }

    /// Resolve to a bold variant.
    public func bold() -> FontSpec {
        FontSpec(size: pointSize, weight: .bold, design: design)
    }

    /// Resolve to an italic variant. Since italic is a trait applied at render time,
    /// we return the same spec — the caller should apply italic traits to the resolved font.
    public func withSize(_ size: CGFloat) -> FontSpec {
        FontSpec(size: size, weight: weight, design: design)
    }
}

// MARK: - Convenience: Extract spec from platform font

extension FontSpec {
    /// Best-effort extraction of a FontSpec from a platform font.
    public init(_ platformFont: MarkdownFont) {
        self.pointSize = platformFont.pointSize

        #if canImport(UIKit)
        let traits = platformFont.fontDescriptor.symbolicTraits
        let isMonospaced = traits.contains(.traitMonoSpace)
        #else
        let traits = platformFont.fontDescriptor.symbolicTraits
        let isMonospaced = traits.contains(.monoSpace)
        #endif

        self.design = isMonospaced ? .monospaced : .default

        // Extract weight from font descriptor
        #if canImport(UIKit)
        let weightTrait = platformFont.fontDescriptor.object(forKey: .init(rawValue: "NSCTFontUIUsageAttribute"))
        if let usage = weightTrait as? String {
            switch usage {
            case "CTFontBoldUsage":     self.weight = .bold
            case "CTFontHeavyUsage":    self.weight = .heavy
            case "CTFontBlackUsage":    self.weight = .black
            case "CTFontMediumUsage":   self.weight = .medium
            case "CTFontDemiUsage":     self.weight = .semibold
            case "CTFontLightUsage":    self.weight = .light
            case "CTFontThinUsage":     self.weight = .thin
            case "CTFontUltraLightUsage": self.weight = .ultraLight
            default:                    self.weight = .regular
            }
        } else if traits.contains(.traitBold) {
            self.weight = .bold
        } else {
            self.weight = .regular
        }
        #else
        if traits.contains(.bold) {
            self.weight = .bold
        } else {
            // Try reading weight from font descriptor attributes
            let attrs = platformFont.fontDescriptor.fontAttributes
            if let weightNumber = attrs[.init(rawValue: "NSCTFontWeightTrait")] as? CGFloat {
                switch weightNumber {
                case ...(-0.6): self.weight = .ultraLight
                case ...(-0.4): self.weight = .thin
                case ...(-0.2): self.weight = .light
                case ...(0.1):  self.weight = .regular
                case ...(0.25): self.weight = .medium
                case ...(0.35): self.weight = .semibold
                case ...(0.5):  self.weight = .bold
                case ...(0.6):  self.weight = .heavy
                default:        self.weight = .black
                }
            } else {
                self.weight = .regular
            }
        }
        #endif
    }
}
