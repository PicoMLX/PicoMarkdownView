#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// One source occurrence retains its model while the app updates its artifact.
@MainActor
@Observable
final class PicoHostedFileCardModel {
    private(set) var file: PicoFileAttachment
    private(set) var markdown: String
    private(set) var bodyFontSize: CGFloat
    var onAction: (@MainActor (PicoFileCardAction) -> Void)?

    init(file: PicoFileAttachment, markdown: String, bodyFontSize: CGFloat) {
        self.file = file
        self.markdown = markdown
        self.bodyFontSize = max(1, bodyFontSize)
    }

    func update(file: PicoFileAttachment, markdown: String, bodyFontSize: CGFloat) {
        if self.file !== file { self.file = file }
        if self.markdown != markdown { self.markdown = markdown }
        let size = max(1, bodyFontSize)
        if self.bodyFontSize != size { self.bodyFontSize = size }
    }

    func perform(_ kind: PicoFileCardAction.Kind) {
        guard file.state == .ready, let onAction else { return }
        onAction(PicoFileCardAction(kind: kind, file: file))
    }
}

@MainActor
struct PicoHostedFileCardView: View {
    let model: PicoHostedFileCardModel
    let context: PicoHostedAttachmentContext

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                metadata
                    .frame(minWidth: min(180, max(1, context.availableWidth - 24)), alignment: .leading)
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: 10) {
                metadata
                actions
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .overlay {
            if context.isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint, lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var metadata: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: model.bodyFontSize * 1.6))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: model.file.filename)
                    .font(.system(size: model.bodyFontSize, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: detail)
                    .font(.system(size: model.bodyFontSize * 0.85))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background {
            PicoFileCardAccessibilityMetadata(label: model.file.filename + ". " + detail)
                .allowsHitTesting(false)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let type = model.file.typeDescription, !type.isEmpty { parts.append(type) }
        if model.file.state == .creating {
            parts.append(String(localized: "Creating…", table: "FileCards", bundle: .module))
        } else {
            if let count = model.file.byteCount, count >= 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file))
            }
            parts.append(String(localized: "Ready", table: "FileCards", bundle: .module))
        }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                action(.preview)
                action(.download)
            }
            VStack(alignment: .leading, spacing: 8) {
                action(.preview)
                action(.download)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func action(_ kind: PicoFileCardAction.Kind) -> some View {
        let title = kind == .preview
            ? String(localized: "Preview", table: "FileCards", bundle: .module)
            : String(localized: "Download", table: "FileCards", bundle: .module)
        let help = kind == .preview
            ? String(localized: "Preview \(model.file.filename).", table: "FileCards", bundle: .module)
            : String(localized: "Save a copy of \(model.file.filename).", table: "FileCards", bundle: .module)
        let announcement = kind == .preview
            ? String(localized: "\(model.file.filename) is ready.", table: "FileCards", bundle: .module)
            : nil
        let enabled = model.file.state == .ready && model.onAction != nil
        return PicoFileCardButton(title: title, help: help,
                                  enabled: enabled,
                                  fontSize: model.bodyFontSize, announcement: announcement) {
            model.perform(kind)
        }
        // SwiftUI also updates native control availability from its environment.
        .disabled(!enabled)
        .fixedSize()
    }
}

@MainActor
private struct PicoFileCardButton: NSViewRepresentable {
    let title: String
    let help: String
    let enabled: Bool
    let fontSize: CGFloat
    let announcement: String?
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> PicoFileCardNativeButton {
        let button = PicoFileCardNativeButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: PicoFileCardNativeButton, context: Context) {
        let becameAvailable = button.previousEnabled == false && enabled
        button.previousEnabled = enabled
        button.title = title
        button.font = .systemFont(ofSize: max(11, fontSize * 0.9))
        button.isEnabled = enabled
        button.toolTip = help
        button.setAccessibilityHelp(help)
        button.performAction = action
        if becameAvailable, let announcement, button.window != nil,
           !button.visibleRect.isEmpty {
            NSAccessibility.post(element: button, notification: .announcementRequested,
                                 userInfo: [.announcement: announcement,
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PicoFileCardNativeButton,
                      context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

@MainActor
private final class PicoFileCardNativeButton: NSButton, PicoHostedAttachmentHitTarget, PicoFileCardAccessibilityChild {
    weak var fileCardAccessibilityParent: NSView?
    var performAction: (@MainActor () -> Void)?
    var previousEnabled: Bool?

    init() {
        super.init(frame: .zero)
        target = self
        action = #selector(activate)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func accessibilityParent() -> Any? {
        if let fileCardAccessibilityParent { return fileCardAccessibilityParent }
        return super.accessibilityParent()
    }

    func acceptsHostedAttachmentHit(at point: NSPoint) -> Bool {
        isEnabled && bounds.contains(point)
    }

    @objc private func activate() {
        guard isEnabled else { return }
        performAction?()
    }
}

/// TextKit exposes its text accessibility element but can omit the hosted
/// SwiftUI subtree. Only these file-card views opt into the native parent bridge.
@MainActor
private protocol PicoFileCardAccessibilityChild: AnyObject {
    var fileCardAccessibilityParent: NSView? { get set }
}

@MainActor
private struct PicoFileCardAccessibilityMetadata: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> PicoFileCardNativeMetadata {
        let view = PicoFileCardNativeMetadata()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        return view
    }

    func updateNSView(_ view: PicoFileCardNativeMetadata, context: Context) {
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(label)
    }
}

@MainActor
private final class PicoFileCardNativeMetadata: NSView, PicoFileCardAccessibilityChild {
    weak var fileCardAccessibilityParent: NSView?

    override func accessibilityParent() -> Any? {
        if let fileCardAccessibilityParent { return fileCardAccessibilityParent }
        return super.accessibilityParent()
    }
}

@MainActor
enum PicoFileCardAccessibility {
    static func children(in textView: NSView) -> [NSView] {
        guard let window = textView.window else { return [] }
        func visibleChildren(in view: NSView) -> [NSView] {
            guard view.window === window, !view.isHidden, view.alphaValue > 0,
                  !view.bounds.intersection(view.visibleRect).isEmpty else { return [] }
            if let child = view as? any PicoFileCardAccessibilityChild {
                child.fileCardAccessibilityParent = textView
                return [view]
            }
            return view.subviews.flatMap { visibleChildren(in: $0) }
        }
        return textView.subviews.flatMap { visibleChildren(in: $0) }.sorted { first, second in
            let firstRect = first.convert(first.bounds, to: textView)
            let secondRect = second.convert(second.bounds, to: textView)
            let firstTop = textView.isFlipped ? firstRect.minY : -firstRect.maxY
            let secondTop = textView.isFlipped ? secondRect.minY : -secondRect.maxY
            if abs(firstTop - secondTop) > 1 { return firstTop < secondTop }
            return firstRect.minX < secondRect.minX
        }
    }
}
#endif
