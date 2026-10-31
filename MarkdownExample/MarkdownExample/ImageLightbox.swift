#if os(macOS)
import AppKit
import PicoMarkdownView
import SwiftUI
import UniformTypeIdentifiers

/// An app-owned viewer. PicoMarkdownView only supplies the already loaded
/// source image and its Markdown metadata; it never presents another window.
struct ImageLightbox: View {
    let image: MarkdownImageActivation
    @Environment(\.dismiss) private var dismiss
    @State private var command = ImageLightboxCommand()
    @State private var exportError: String?
    @FocusState private var closeIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ImageLightboxHeader(title: image.title, altText: image.altText,
                                sourceURL: image.sourceURL,
                                copy: copyImage, save: saveImage, close: { dismiss() },
                                closeIsFocused: $closeIsFocused)
            Divider()
            ImageLightboxCanvas(image: image.image, altText: image.altText, command: command)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            ImageLightboxControls(perform: perform)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { closeIsFocused = true }
        .onExitCommand { dismiss() }
        // Zoom changes are immediate, including when Reduce Motion is on.
        // The native sheet owns modal focus and returns it on dismissal.
        .alert("Couldn’t Export Image", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func perform(_ action: ImageLightboxCommand.Action) {
        command = ImageLightboxCommand(action: action)
    }

    private func copyImage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.writeObjects([image.image]) {
            exportError = String(localized: "The image could not be copied.")
        }
    }

    private func saveImage() {
        guard let tiff = image.image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            exportError = String(localized: "The image could not be converted to PNG.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let sourceName = image.sourceURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = (sourceName.isEmpty ? "Image" : sourceName) + ".png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

private struct ImageLightboxHeader: View {
    let title: String?
    let altText: String
    let sourceURL: URL
    let copy: () -> Void
    let save: () -> Void
    let close: () -> Void
    let closeIsFocused: FocusState<Bool>.Binding

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                ImageLightboxCaption(title: title, altText: altText, sourceURL: sourceURL)
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: 8) {
                ImageLightboxCaption(title: title, altText: altText, sourceURL: sourceURL)
                actions
            }
        }
        .padding()
    }

    private var actions: some View {
        HStack {
            Button("Copy Image", systemImage: "doc.on.doc", action: copy)
                .help("Copy the image to the clipboard.")
            Button("Save…", systemImage: "square.and.arrow.down", action: save)
                .help("Save the image as a PNG file.")
                .keyboardShortcut("s", modifiers: .command)
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .focused(closeIsFocused)
        }
    }
}

private struct ImageLightboxCaption: View {
    let title: String?
    let altText: String
    let sourceURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title, !title.isEmpty {
                Text(title).font(.headline).lineLimit(2)
            } else if !altText.isEmpty {
                Text(altText).font(.headline).lineLimit(2)
            } else {
                Text("Image").font(.headline)
            }
            Text(sourceURL.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ImageLightboxControls: View {
    let perform: (ImageLightboxCommand.Action) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { perform(.zoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right") { perform(.fit) }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Zoom In", systemImage: "plus.magnifyingglass") { perform(.zoomIn) }
                    .keyboardShortcut("=", modifiers: .command)
            }
            Text("Pinch to zoom. Drag or scroll to pan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct ImageLightboxCommand: Equatable {
    enum Action { case fit, zoomIn, zoomOut }
    let id = UUID()
    var action: Action = .fit
}

private struct ImageLightboxCanvas: NSViewRepresentable {
    let image: NSImage
    let altText: String
    let command: ImageLightboxCommand

    func makeNSView(context: Context) -> ImageLightboxScrollView {
        ImageLightboxScrollView(image: image, altText: altText)
    }

    func updateNSView(_ view: ImageLightboxScrollView, context: Context) {
        view.perform(command)
    }
}

/// Native magnification preserves the source image, including vector image
/// representations. Scrolling and mouse dragging operate only in this viewer.
private final class ImageLightboxScrollView: NSScrollView {
    private var lastCommand: UUID?
    private var isFitted = true
    private var fittedViewport = CGSize.zero

    init(image: NSImage, altText: String) {
        super.init(frame: .zero)
        let imageView = ImageLightboxImageView()
        imageView.image = image
        imageView.imageScaling = .scaleNone
        let size = image.size
        imageView.frame.size = CGSize(width: size.width.isFinite ? max(1, size.width) : 1,
                                      height: size.height.isFinite ? max(1, size.height) : 1)
        imageView.setAccessibilityLabel(altText.isEmpty ? String(localized: "Image") : altText)
        contentView = ImageLightboxClipView()
        documentView = imageView
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.001
        maxMagnification = 16
        borderType = .noBorder
    }

    required init?(coder: NSCoder) { fatalError("Use init(image:altText:)") }

    override func layout() {
        super.layout()
        let viewport = contentSize
        if isFitted, viewport != fittedViewport, viewport.width > 0, viewport.height > 0 {
            fittedViewport = viewport
            fitImage()
        }
    }

    func perform(_ command: ImageLightboxCommand) {
        guard command.id != lastCommand else { return }
        lastCommand = command.id
        switch command.action {
        case .fit:
            isFitted = true
            fitImage()
        case .zoomIn:
            isFitted = false
            setMagnification(min(maxMagnification, magnification * 1.25), centeredAt: visibleCenter)
        case .zoomOut:
            isFitted = false
            setMagnification(max(minMagnification, magnification / 1.25), centeredAt: visibleCenter)
        }
    }

    override func magnify(with event: NSEvent) {
        isFitted = false
        super.magnify(with: event)
    }

    private var visibleCenter: CGPoint {
        CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
    }

    private func fitImage() {
        guard let documentView, contentSize.width > 0, contentSize.height > 0 else { return }
        magnify(toFit: documentView.bounds)
    }
}

private final class ImageLightboxClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        let size = documentView.frame.size
        if size.width < result.width { result.origin.x = (size.width - result.width) / 2 }
        if size.height < result.height { result.origin.y = (size.height - result.height) / 2 }
        return result
    }
}

private final class ImageLightboxImageView: NSImageView {
    private var dragPoint: CGPoint?

    override func mouseDown(with event: NSEvent) {
        dragPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previous = dragPoint, let scrollView = enclosingScrollView else { return }
        let next = event.locationInWindow
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.x -= (next.x - previous.x) / scrollView.magnification
        // NSClipView coordinates are unflipped here, matching window y.
        origin.y -= (next.y - previous.y) / scrollView.magnification
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        dragPoint = next
    }

    override func mouseUp(with event: NSEvent) { dragPoint = nil }
}
#endif
