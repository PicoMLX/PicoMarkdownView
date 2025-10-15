#if canImport(UIKit)
import UIKit
public typealias MarkdownFont = UIFont
public typealias MarkdownColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias MarkdownFont = NSFont
public typealias MarkdownColor = NSColor
#endif

typealias PlatformFont = MarkdownFont
typealias PlatformColor = MarkdownColor
