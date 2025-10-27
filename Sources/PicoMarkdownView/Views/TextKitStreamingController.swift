import Foundation

#if canImport(UIKit) || canImport(AppKit)

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class TextKitStreamingController: ObservableObject {
    private let backend = TextKitStreamingBackend()

#if canImport(UIKit)
    func makeTextKit1View(configuration: PicoTextKitConfiguration) -> UITextView {
        let textView = StreamingTextKit1View(backend: backend)
        configure(textView, with: configuration)
        return textView
    }

    @available(iOS 16.0, *)
    func makeTextKit2View(configuration: PicoTextKitConfiguration) -> UITextView {
        let textView = StreamingTextKit2View(backend: backend)
        configure(textView, with: configuration)
        return textView
    }

    func update(textView: UITextView,
                blocks: [RenderedBlock],
                configuration: PicoTextKitConfiguration) {
        configure(textView, with: configuration)
        guard configuration.isSelectable else {
            _ = backend.apply(blocks: blocks, selection: NSRange(location: backend.length, length: 0))
            textView.invalidateIntrinsicContentSize()
            return
        }
        let selection = backend.apply(blocks: blocks, selection: textView.selectedRange)
        textView.selectedRange = selection.clamped(maxLength: backend.length)
        textView.invalidateIntrinsicContentSize()
    }

    private func configure(_ view: UITextView, with configuration: PicoTextKitConfiguration) {
        if view.isSelectable != configuration.isSelectable {
            view.isSelectable = configuration.isSelectable
        }
        if view.isEditable {
            view.isEditable = false
        }
        if view.isScrollEnabled != configuration.isScrollEnabled {
            view.isScrollEnabled = configuration.isScrollEnabled
        }
        if view.textContainerInset != configuration.uiEdgeInsets {
            view.textContainerInset = configuration.uiEdgeInsets
        }
        let background = configuration.platformColor
        if view.backgroundColor != background {
            view.backgroundColor = background
        }
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        if !configuration.isScrollEnabled {
            view.alwaysBounceVertical = false
            view.showsVerticalScrollIndicator = false
        }
    }
#elseif canImport(AppKit)
    func makeTextKit1View(configuration: PicoTextKitConfiguration) -> NSTextView {
        let textView = StreamingTextKit1View(backend: backend)
        configure(textView, with: configuration)
        return textView
    }

    @available(macOS 13.0, *)
    func makeTextKit2View(configuration: PicoTextKitConfiguration) -> NSTextView {
        // Fallback to TextKit 1 host on macOS until TextKit 2 configuration can be customized.
        return makeTextKit1View(configuration: configuration)
    }

    func update(textView: NSTextView,
                blocks: [RenderedBlock],
                configuration: PicoTextKitConfiguration) {
        configure(textView, with: configuration)
        let currentSelection = configuration.isSelectable ? textView.selectedRange() : NSRange(location: backend.length, length: 0)
        let selection = backend.apply(blocks: blocks, selection: currentSelection)
        if configuration.isSelectable {
            textView.setSelectedRange(selection.clamped(maxLength: backend.length))
        }
        textView.invalidateIntrinsicContentSize()
    }

    private func configure(_ view: NSTextView, with configuration: PicoTextKitConfiguration) {
        if view.isEditable {
            view.isEditable = false
        }
        if view.isSelectable != configuration.isSelectable {
            view.isSelectable = configuration.isSelectable
        }
        view.drawsBackground = true
        if let container = view.textContainer {
            container.lineFragmentPadding = 0
        }
        view.textContainerInset = NSSize(width: configuration.horizontalInset,
                                         height: configuration.verticalInset)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = configuration.isScrollEnabled
        view.isHorizontallyResizable = configuration.isScrollEnabled
        view.allowsUndo = false
        view.usesAdaptiveColorMappingForDarkAppearance = true
        view.textContainer?.widthTracksTextView = true
        view.backgroundColor = configuration.platformColor
    }
#endif
}

@MainActor
final class TextKitStreamingBackend {
    private var records: [BlockRecord] = []
    private var blockOffsets: [Int] = []
    
    private struct BlockRecord {
        var id: BlockID
        var content: AttributedString
        var nsAttributed: NSAttributedString
        var length: Int
    }

    private let storage = NSTextStorage()

    var length: Int {
        storage.length
    }

    func apply(blocks: [RenderedBlock], selection: NSRange) -> NSRange {
        if blocks.isEmpty {
            if storage.length == 0 {
                records = []
                return NSRange(location: 0, length: 0)
            }
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString())
            storage.endEditing()
            records = []
            return NSRange(location: 0, length: 0)
        }

        let blockData: [(block: RenderedBlock, attributed: NSAttributedString)] = blocks.enumerated().map { index, block in
            if index < records.count && records[index].id == block.id && records[index].content == block.content {
                return (block: block, attributed: records[index].nsAttributed)
            } else {
                return (block: block, attributed: NSAttributedString(block.content))
            }
        }

        if records.count != blockData.count || !zip(records, blockData).allSatisfy({ $0.0.id == $0.1.block.id }) {
            return replaceAll(with: blockData, selection: selection)
        }

        var updatedSelection = selection
        var mutated = false

        storage.beginEditing()
        defer { storage.endEditing() }
        for index in records.indices {
            let record = records[index]
            let data = blockData[index]
            if record.content == data.block.content { continue }
            let range = rangeForBlock(at: index, data: blockData)
            storage.replaceCharacters(in: range, with: data.attributed)
            updatedSelection = adjust(selection: updatedSelection, editedRange: range, replacementLength: data.attributed.length)
            records[index].content = data.block.content
            records[index].length = data.attributed.length
            mutated = true
        }

        if mutated {
            rebuildRecords(using: blockData)
        }

        return updatedSelection.clamped(maxLength: storage.length)
    }

    private func replaceAll(with blockData: [(block: RenderedBlock, attributed: NSAttributedString)],
                            selection: NSRange) -> NSRange {
        let composed = NSMutableAttributedString()
        for data in blockData {
            composed.append(data.attributed)
        }
        storage.beginEditing()
        storage.setAttributedString(composed)
        storage.endEditing()
        rebuildRecords(using: blockData)
        return selection.clamped(maxLength: storage.length)
    }

    private func rebuildRecords(using blockData: [(block: RenderedBlock, attributed: NSAttributedString)]) {
        records = blockData.map { BlockRecord(id: $0.block.id, content: $0.block.content, nsAttributed: $0.attributed, length: $0.attributed.length) }
        rebuildOffsets()
    }
    
    private func rebuildOffsets() {
        blockOffsets.removeAll(keepingCapacity: true)
        blockOffsets.reserveCapacity(records.count)
        var cumulative = 0
        for record in records {
            blockOffsets.append(cumulative)
            cumulative += record.length
        }
    }

    private func rangeForBlock(at index: Int,
                               data: [(block: RenderedBlock, attributed: NSAttributedString)]) -> NSRange {
        let location = index < blockOffsets.count ? blockOffsets[index] : 0
        return NSRange(location: location, length: records[index].length)
    }

    private func adjust(selection: NSRange,
                        editedRange: NSRange,
                        replacementLength: Int) -> NSRange {
        var result = selection
        let delta = replacementLength - editedRange.length
        let editEnd = editedRange.location + editedRange.length
        let selectionEnd = result.location + result.length

        if editEnd <= result.location {
            result.location += delta
        } else if editedRange.location >= selectionEnd {
            return result
        } else {
            result.location = editedRange.location
            result.length = max(0, min(replacementLength, selectionEnd - editedRange.location))
        }

        return result
    }

    fileprivate func connect(to layoutManager: NSLayoutManager) {
        for manager in storage.layoutManagers {
            storage.removeLayoutManager(manager)
        }
        storage.addLayoutManager(layoutManager)
    }

#if canImport(UIKit)
    fileprivate func connect(to textContentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager) {
        textContentStorage.textStorage = storage
        for manager in textContentStorage.textLayoutManagers {
            textContentStorage.removeTextLayoutManager(manager)
        }
        textContentStorage.addTextLayoutManager(layoutManager)
    }
#elseif canImport(AppKit)
    @available(macOS 13.0, *)
    fileprivate func connect(to textContentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager) {
        textContentStorage.textStorage = storage
        for manager in textContentStorage.textLayoutManagers {
            textContentStorage.removeTextLayoutManager(manager)
        }
        textContentStorage.addTextLayoutManager(layoutManager)
    }
#endif

    func snapshotAttributedString() -> NSAttributedString {
        NSAttributedString(attributedString: storage)
    }
}

private extension NSRange {
    func clamped(maxLength: Int) -> NSRange {
        guard maxLength >= 0 else { return NSRange(location: 0, length: 0) }
        let location = Swift.max(0, Swift.min(self.location, maxLength))
        let available = Swift.max(0, maxLength - location)
        let length = Swift.max(0, Swift.min(self.length, available))
        return NSRange(location: location, length: length)
    }
}

#if canImport(UIKit)
@MainActor
private final class StreamingTextKit1View: UITextView {
    init(backend: TextKitStreamingBackend) {
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        layoutManager.addTextContainer(textContainer)
        backend.connect(to: layoutManager)
        super.init(frame: .zero, textContainer: textContainer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        guard !isScrollEnabled else { return super.intrinsicContentSize }
        let targetWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let size = sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !isScrollEnabled {
            invalidateIntrinsicContentSize()
        }
    }
}

@available(iOS 16.0, *)
@MainActor
private final class StreamingTextKit2View: UITextView {
    init(backend: TextKitStreamingBackend) {
        super.init(frame: .zero, textContainer: nil)
        if let layoutManager = textLayoutManager,
           let contentStorage = layoutManager.textContentStorage {
            backend.connect(to: contentStorage, layoutManager: layoutManager)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        guard !isScrollEnabled else { return super.intrinsicContentSize }
        let targetWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let size = sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !isScrollEnabled {
            invalidateIntrinsicContentSize()
        }
    }
}

#elseif canImport(AppKit)
@MainActor
private final class StreamingTextKit1View: NSTextView {
    init(backend: TextKitStreamingBackend) {
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                         height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(textContainer)
        backend.connect(to: layoutManager)
        super.init(frame: .zero, textContainer: textContainer)
        isVerticallyResizable = true
        isHorizontallyResizable = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        guard !isVerticallyResizable else { return super.intrinsicContentSize }
        return sizeThatFits()
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }

    private func sizeThatFits() -> NSSize {
        guard let textContainer = textContainer, let layoutManager = layoutManager else {
            return super.intrinsicContentSize
        }
        let width = bounds.width > 0 ? bounds.width : CGFloat.greatestFiniteMagnitude
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: used.height + textContainerInset.height * 2)
    }
}
#endif

#endif
