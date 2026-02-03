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
    private var lastAppliedVersion: UInt64 = 0
    private var lastAppliedReplaceToken: UInt64 = 0

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
                diffs: [AssemblerDiff],
                replaceToken: UInt64,
                configuration: PicoTextKitConfiguration) {
        configure(textView, with: configuration)
        backend.setPaused(configuration.isPaused)
        if replaceToken != lastAppliedReplaceToken {
            lastAppliedReplaceToken = replaceToken
            lastAppliedVersion = 0
            _ = backend.apply(blocks: blocks, selection: textView.selectedRange)
            textView.invalidateIntrinsicContentSize()
            return
        }
        let eligible = eligibleDiffs(from: diffs)
        if eligible.diffs.isEmpty {
            if configuration.isSelectable {
                textView.selectedRange = textView.selectedRange.clamped(maxLength: backend.length)
            }
            textView.invalidateIntrinsicContentSize()
            return
        }
        if !configuration.isSelectable {
            _ = backend.apply(blocks: blocks, diffs: eligible.diffs, selection: NSRange(location: backend.length, length: 0))
            if !configuration.isPaused {
                lastAppliedVersion = eligible.lastVersion
            }
            textView.invalidateIntrinsicContentSize()
            return
        }
        let selection = backend.apply(blocks: blocks, diffs: eligible.diffs, selection: textView.selectedRange)
        if !configuration.isPaused {
            lastAppliedVersion = eligible.lastVersion
        }
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
        let textView = StreamingTextKit2View(backend: backend)
        configure(textView, with: configuration)
        return textView
    }

    func update(textView: NSTextView,
                blocks: [RenderedBlock],
                diffs: [AssemblerDiff],
                replaceToken: UInt64,
                configuration: PicoTextKitConfiguration) {
        configure(textView, with: configuration)
        let currentSelection = configuration.isSelectable ? textView.selectedRange() : NSRange(location: backend.length, length: 0)
        backend.setPaused(configuration.isPaused)
        if replaceToken != lastAppliedReplaceToken {
            lastAppliedReplaceToken = replaceToken
            lastAppliedVersion = 0
            _ = backend.apply(blocks: blocks, selection: currentSelection)
            textView.invalidateIntrinsicContentSize()
            return
        }
        let eligible = eligibleDiffs(from: diffs)
        if eligible.diffs.isEmpty {
            if configuration.isSelectable {
                textView.setSelectedRange(currentSelection.clamped(maxLength: backend.length))
            }
            textView.invalidateIntrinsicContentSize()
            return
        }
        let selection = backend.apply(blocks: blocks, diffs: eligible.diffs, selection: currentSelection)
        if !configuration.isPaused {
            lastAppliedVersion = eligible.lastVersion
        }
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

    private func eligibleDiffs(from diffs: [AssemblerDiff]) -> (diffs: [AssemblerDiff], lastVersion: UInt64) {
        guard !diffs.isEmpty else { return ([], lastAppliedVersion) }
        var eligible: [AssemblerDiff] = []
        eligible.reserveCapacity(diffs.count)
        var latest = lastAppliedVersion
        for diff in diffs where diff.documentVersion > latest {
            eligible.append(diff)
            latest = diff.documentVersion
        }
        return (eligible, latest)
    }
}

@MainActor
final class TextKitStreamingBackend {
    private var records: [BlockRecord] = []
    private var blockOffsets: [Int] = []
    private var indexByID: [BlockID: Int] = [:]
    private var isPaused = false
    private var deferred: DeferredUpdate?
    
    private struct BlockRecord {
        var id: BlockID
        var content: AttributedString
        var nsAttributed: NSAttributedString
        var length: Int
    }

    private struct DeferredUpdate {
        var blocks: [RenderedBlock]
        var diffs: [AssemblerDiff]
    }

    private let storage = NSTextStorage()

    var length: Int {
        storage.length
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    func apply(blocks: [RenderedBlock], selection: NSRange) -> NSRange {
        apply(blocks: blocks, diffs: [], selection: selection)
    }

    func apply(blocks: [RenderedBlock], diffs: [AssemblerDiff], selection: NSRange) -> NSRange {
        if isPaused {
            deferred = DeferredUpdate(blocks: blocks, diffs: diffs)
            return selection.clamped(maxLength: storage.length)
        }
        if deferred != nil {
            deferred = nil
        }
        guard !diffs.isEmpty else {
            return applyFullScan(blocks: blocks, selection: selection)
        }
        guard canApplyDiffs(diffs, blocks: blocks) else {
            return applyFullScan(blocks: blocks, selection: selection)
        }
        return applyDiffs(diffs, blocks: blocks, selection: selection)
    }

    private func applyFullScan(blocks: [RenderedBlock], selection: NSRange) -> NSRange {
        if blocks.isEmpty {
            if storage.length == 0 {
                records = []
                blockOffsets = [0]
                indexByID = [:]
                return NSRange(location: 0, length: 0)
            }
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString())
            storage.endEditing()
            records = []
            blockOffsets = [0]
            indexByID = [:]
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

        // Check if any content actually changed before editing
        let hasChanges = zip(records, blockData).contains { $0.0.content != $0.1.block.content }
        guard hasChanges else {
            return selection.clamped(maxLength: storage.length)
        }

        var updatedSelection = selection

        storage.beginEditing()
        defer { storage.endEditing() }
        for index in records.indices {
            let record = records[index]
            let data = blockData[index]
            if record.content == data.block.content { continue }

            let oldLength = record.length
            let range = rangeForBlock(at: index, data: blockData)
            storage.replaceCharacters(in: range, with: data.attributed)
            updatedSelection = adjust(selection: updatedSelection, editedRange: range, replacementLength: data.attributed.length)

            records[index].content = data.block.content
            records[index].length = data.attributed.length
            records[index].nsAttributed = data.attributed

            // Incremental offset update - O(1) for last block updates (streaming!)
            let delta = data.attributed.length - oldLength
            if delta != 0 {
                updateOffsetsAfter(index: index, delta: delta)
            }
        }

        return updatedSelection.clamped(maxLength: storage.length)
    }

    private func canApplyDiffs(_ diffs: [AssemblerDiff], blocks: [RenderedBlock]) -> Bool {
        var expectedCount = records.count
        var insertedIDs = Set<BlockID>()

        for diff in diffs {
            for change in diff.changes {
                switch change {
                case .blockStarted(let id, _, let position):
                    if position < 0 || position > expectedCount { return false }
                    if position < blocks.count, blocks[position].id != id { return false }
                    insertedIDs.insert(id)
                    expectedCount += 1
                case .blocksDiscarded(let range):
                    if range.lowerBound < 0 || range.upperBound > expectedCount { return false }
                    expectedCount -= range.count
                case .runsAppended(let id, _),
                     .codeAppended(let id, _),
                     .tableHeaderConfirmed(let id),
                     .tableRowAppended(let id, _),
                     .blockEnded(let id):
                    if indexByID[id] == nil && !insertedIDs.contains(id) {
                        return false
                    }
                    if let index = indexByID[id], index < blocks.count, blocks[index].id != id {
                        return false
                    }
                }
            }
        }

        return expectedCount == blocks.count
    }

    private func applyDiffs(_ diffs: [AssemblerDiff],
                            blocks: [RenderedBlock],
                            selection: NSRange) -> NSRange {
        var updatedSelection = selection
        storage.beginEditing()
        defer { storage.endEditing() }

        for diff in diffs {
            updatedSelection = applyDiff(diff, blocks: blocks, selection: updatedSelection)
        }

        return updatedSelection.clamped(maxLength: storage.length)
    }

    private func applyDiff(_ diff: AssemblerDiff,
                           blocks: [RenderedBlock],
                           selection: NSRange) -> NSRange {
        var updatedSelection = selection

        for change in diff.changes {
            switch change {
            case .blocksDiscarded(let range):
                updatedSelection = removeRecords(in: range, selection: updatedSelection)
            case .blockStarted(let id, _, let position):
                let index = max(0, min(position, blocks.count))
                guard index < blocks.count, blocks[index].id == id else { continue }
                updatedSelection = insertRecord(blocks[index], at: index, selection: updatedSelection)
            case .runsAppended(let id, _),
                 .codeAppended(let id, _),
                 .tableHeaderConfirmed(let id),
                 .tableRowAppended(let id, _),
                 .blockEnded(let id):
                updatedSelection = updateRecord(id: id, blocks: blocks, selection: updatedSelection)
            }
        }

        return updatedSelection
    }

    private func insertRecord(_ block: RenderedBlock,
                              at index: Int,
                              selection: NSRange) -> NSRange {
        let attributed = NSAttributedString(block.content)
        let record = BlockRecord(id: block.id,
                                 content: block.content,
                                 nsAttributed: attributed,
                                 length: attributed.length)
        let clampedIndex = max(0, min(index, records.count))
        let location = clampedIndex < blockOffsets.count ? blockOffsets[clampedIndex] : storage.length
        let editedRange = NSRange(location: location, length: 0)

        storage.replaceCharacters(in: editedRange, with: attributed)

        records.insert(record, at: clampedIndex)
        for i in clampedIndex..<records.count {
            indexByID[records[i].id] = i
        }
        insertOffsets(at: clampedIndex, length: attributed.length)

        return adjust(selection: selection, editedRange: editedRange, replacementLength: attributed.length)
    }

    private func updateRecord(id: BlockID,
                              blocks: [RenderedBlock],
                              selection: NSRange) -> NSRange {
        guard let index = indexByID[id], index < records.count, index < blocks.count else {
            return selection
        }
        let block = blocks[index]
        let record = records[index]
        guard record.content != block.content else { return selection }

        let newAttributed = NSAttributedString(block.content)
        let range = rangeForRecord(at: index)
        storage.replaceCharacters(in: range, with: newAttributed)
        let updatedSelection = adjust(selection: selection, editedRange: range, replacementLength: newAttributed.length)

        let oldLength = record.length
        records[index].content = block.content
        records[index].length = newAttributed.length
        records[index].nsAttributed = newAttributed

        let delta = newAttributed.length - oldLength
        if delta != 0 {
            updateOffsetsAfter(index: index, delta: delta)
        }

        return updatedSelection
    }

    private func removeRecords(in range: Range<Int>,
                               selection: NSRange) -> NSRange {
        guard !records.isEmpty else { return selection }
        let lower = max(0, range.lowerBound)
        let upper = min(range.upperBound, records.count)
        guard lower < upper else { return selection }
        let removalRange = lower..<upper

        let startLocation = lower < blockOffsets.count ? blockOffsets[lower] : 0
        let endLocation = upper < blockOffsets.count ? blockOffsets[upper] : storage.length
        let removalLength = max(0, endLocation - startLocation)
        let editedRange = NSRange(location: startLocation, length: removalLength)

        storage.replaceCharacters(in: editedRange, with: NSAttributedString())

        let removed = records[removalRange]
        for record in removed {
            indexByID[record.id] = nil
        }
        records.removeSubrange(removalRange)
        for i in lower..<records.count {
            indexByID[records[i].id] = i
        }
        removeOffsets(in: removalRange, removedLength: removalLength)
        if records.isEmpty {
            blockOffsets = [0]
        }

        return adjust(selection: selection, editedRange: editedRange, replacementLength: 0)
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
        indexByID = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($1.id, $0) })
        rebuildOffsets()
    }
    
    private func rebuildOffsets() {
        blockOffsets = Array(repeating: 0, count: records.count + 1)
        for index in records.indices {
            blockOffsets[index + 1] = blockOffsets[index] + records[index].length
        }
    }
    
    private func updateOffsetsAfter(index: Int, delta: Int) {
        guard delta != 0 else { return }
        // Incremental update: only adjust offsets after the changed block
        // O(n - index) instead of O(n) - typically O(1) for streaming (last block)
        let startOffset = index + 1
        for i in startOffset..<blockOffsets.count {
            blockOffsets[i] += delta
        }
    }

    private func insertOffsets(at index: Int, length: Int) {
        if blockOffsets.isEmpty {
            blockOffsets = [0]
        }
        let clampedIndex = max(0, min(index, blockOffsets.count - 1))
        let base = blockOffsets[clampedIndex]
        let insertPosition = clampedIndex + 1
        if insertPosition <= blockOffsets.count {
            blockOffsets.insert(base + length, at: insertPosition)
            if length != 0 {
                for i in (insertPosition + 1)..<blockOffsets.count {
                    blockOffsets[i] += length
                }
            }
        } else {
            blockOffsets.append(base + length)
        }
    }

    private func removeOffsets(in range: Range<Int>, removedLength: Int) {
        guard !blockOffsets.isEmpty else { return }
        let removeCount = range.count
        guard removeCount > 0 else { return }
        let startIndex = range.lowerBound + 1
        let endIndex = min(startIndex + removeCount, blockOffsets.count)
        if startIndex < endIndex {
            blockOffsets.removeSubrange(startIndex..<endIndex)
        }
        guard removedLength != 0 else { return }
        if startIndex < blockOffsets.count {
            for i in startIndex..<blockOffsets.count {
                blockOffsets[i] -= removedLength
            }
        }
    }

    private func rangeForBlock(at index: Int,
                               data: [(block: RenderedBlock, attributed: NSAttributedString)]) -> NSRange {
        let location: Int
        if index < blockOffsets.count {
            location = blockOffsets[index]
        } else {
            location = records.prefix(index).reduce(0) { $0 + $1.length }
        }

        let length: Int
        if index + 1 < blockOffsets.count {
            length = blockOffsets[index + 1] - location
        } else {
            length = records[index].length
        }

        return NSRange(location: location, length: length)
    }

    private func rangeForRecord(at index: Int) -> NSRange {
        let location: Int
        if index < blockOffsets.count {
            location = blockOffsets[index]
        } else {
            location = records.prefix(index).reduce(0) { $0 + $1.length }
        }

        let length: Int
        if index + 1 < blockOffsets.count {
            length = blockOffsets[index + 1] - location
        } else {
            length = records[index].length
        }

        return NSRange(location: location, length: length)
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

    func cachedAttributedString(forBlockAt index: Int) -> NSAttributedString? {
        guard records.indices.contains(index) else { return nil }
        return records[index].nsAttributed
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
           let contentStorage = textContentStorage {
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

@available(macOS 13.0, *)
@MainActor
private final class StreamingTextKit2View: NSTextView {
    init(backend: TextKitStreamingBackend) {
        super.init(frame: .zero)
        if let layoutManager = textLayoutManager,
           let contentStorage = textContentStorage {
            backend.connect(to: contentStorage, layoutManager: layoutManager)
        } else if let legacyLayout = layoutManager {
            backend.connect(to: legacyLayout)
        }
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
        if !isVerticallyResizable {
            invalidateIntrinsicContentSize()
        }
    }

    private func sizeThatFits() -> NSSize {
        if let layoutManager = textLayoutManager,
           let textContainer = layoutManager.textContainer {
            let width = bounds.width > 0 ? bounds.width : CGFloat.greatestFiniteMagnitude
            textContainer.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            let targetBounds = CGRect(origin: .zero, size: textContainer.size)
            layoutManager.ensureLayout(for: targetBounds)
            let used = layoutManager.usageBoundsForTextContainer
            return NSSize(width: NSView.noIntrinsicMetric, height: used.height + textContainerInset.height * 2)
        }

        guard let textContainer = textContainer, let legacyLayout = layoutManager else {
            return super.intrinsicContentSize
        }
        let width = bounds.width > 0 ? bounds.width : CGFloat.greatestFiniteMagnitude
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        legacyLayout.ensureLayout(for: textContainer)
        let used = legacyLayout.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: used.height + textContainerInset.height * 2)
    }
}
#endif

#endif
