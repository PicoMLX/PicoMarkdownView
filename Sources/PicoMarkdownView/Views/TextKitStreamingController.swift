import Foundation
import os

#if canImport(UIKit) || canImport(AppKit)

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class TextKitStreamingController: ObservableObject {
    private static let logger = Logger(subsystem: "com.picomarkdown", category: "Controller")
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
            textView.setNeedsDisplay()
            textView.invalidateIntrinsicContentSize()
            return
        }
        let eligible = eligibleDiffs(from: diffs)
        if eligible.diffs.isEmpty {
            // Safety net: if the blocks have changed but all diffs were already
            // consumed (e.g. coalesced flush delivered stale diff versions),
            // force a full apply so the view stays in sync.
            if backend.needsFullApply(for: blocks) {
                _ = backend.apply(blocks: blocks, selection: textView.selectedRange)
                textView.setNeedsDisplay()
            } else if configuration.isSelectable {
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
            textView.setNeedsDisplay()
            textView.invalidateIntrinsicContentSize()
            return
        }
        let selection = backend.apply(blocks: blocks, diffs: eligible.diffs, selection: textView.selectedRange)
        if !configuration.isPaused {
            lastAppliedVersion = eligible.lastVersion
        }
        textView.selectedRange = selection.clamped(maxLength: backend.length)
        textView.setNeedsDisplay()
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
        Self.logger.debug("update: \(blocks.count) blocks, replaceToken=\(replaceToken), lastApplied=\(self.lastAppliedReplaceToken), storageLen=\(self.backend.length)")
        configure(textView, with: configuration)
        let currentSelection = configuration.isSelectable ? textView.selectedRange() : NSRange(location: backend.length, length: 0)
        backend.setPaused(configuration.isPaused)
        if replaceToken != lastAppliedReplaceToken {
            lastAppliedReplaceToken = replaceToken
            lastAppliedVersion = 0
            _ = backend.apply(blocks: blocks, selection: currentSelection)
            Self.logger.debug("applied full replace: storageLen=\(self.backend.length)")
            textView.needsDisplay = true
            textView.invalidateIntrinsicContentSize()
            return
        }
        let eligible = eligibleDiffs(from: diffs)
        if eligible.diffs.isEmpty {
            // Safety net: if the blocks have changed but all diffs were already
            // consumed (e.g. coalesced flush delivered stale diff versions),
            // force a full apply so the view stays in sync.
            if backend.needsFullApply(for: blocks) {
                _ = backend.apply(blocks: blocks, selection: currentSelection)
                textView.needsDisplay = true
            } else if configuration.isSelectable {
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
        textView.needsDisplay = true
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

#if canImport(UIKit)
    func mermaidContentWidth(for textView: UITextView) -> CGFloat? {
        let insets = textView.textContainerInset
        let width = textView.bounds.width - insets.left - insets.right
        return width > 0 ? width : nil
    }

    func installMermaidWidthObserver(on textView: UITextView, _ observer: @escaping (CGFloat?) -> Void) {
        if let textView = textView as? StreamingTextKit1View {
            textView.onMermaidContentWidthChanged = observer
        } else if #available(iOS 16.0, *), let textView = textView as? StreamingTextKit2View {
            textView.onMermaidContentWidthChanged = observer
        }
        observer(mermaidContentWidth(for: textView))
    }

    func installContentSizeObserver(on textView: UITextView, _ observer: ((CGSize) -> Void)?) {
        if let textView = textView as? StreamingTextKit1View {
            textView.onContentSizeChanged = observer
        } else if #available(iOS 16.0, *), let textView = textView as? StreamingTextKit2View {
            textView.onContentSizeChanged = observer
        }
    }

    func installLinkHandler(on textView: UITextView, _ handler: ((URL, String) -> Void)?) {
        if let textView = textView as? StreamingTextKit1View {
            textView.linkActionHandler = handler
        } else if #available(iOS 16.0, *), let textView = textView as? StreamingTextKit2View {
            textView.linkActionHandler = handler
        }
    }
#elseif canImport(AppKit)
    func mermaidContentWidth(for textView: NSTextView) -> CGFloat? {
        let inset = textView.textContainerInset
        let width = textView.bounds.width - inset.width * 2
        return width > 0 ? width : nil
    }

    func installMermaidWidthObserver(on textView: NSTextView, _ observer: @escaping (CGFloat?) -> Void) {
        if let textView = textView as? StreamingTextKit1View {
            textView.onMermaidContentWidthChanged = observer
        } else if #available(macOS 13.0, *), let textView = textView as? StreamingTextKit2View {
            textView.onMermaidContentWidthChanged = observer
        }
        observer(mermaidContentWidth(for: textView))
    }

    func installContentSizeObserver(on textView: NSTextView, _ observer: ((CGSize) -> Void)?) {
        if let textView = textView as? StreamingTextKit1View {
            textView.onContentSizeChanged = observer
        } else if #available(macOS 13.0, *), let textView = textView as? StreamingTextKit2View {
            textView.onContentSizeChanged = observer
        }
    }

    func installLinkHandler(on textView: NSTextView, _ handler: ((URL, String) -> Void)?) {
        if let textView = textView as? StreamingTextKit1View {
            textView.linkActionHandler = handler
        } else if #available(macOS 13.0, *), let textView = textView as? StreamingTextKit2View {
            textView.linkActionHandler = handler
        }
    }

    func installHoverHandler(on textView: NSTextView, _ handler: ((URL?, String, CGRect?) -> Void)?) {
        if let textView = textView as? StreamingTextKit1View {
            textView.hoverHandler = handler
        } else if #available(macOS 13.0, *), let textView = textView as? StreamingTextKit2View {
            textView.hoverHandler = handler
        }
    }
#endif
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

    private var storage = NSTextStorage()

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
                return (block: block, attributed: NSAttributedString.picoConverted(from: block.content))
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
        let attributed = NSAttributedString.picoConverted(from: block.content)
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

        let newAttributed = NSAttributedString.picoConverted(from: block.content)
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
        // Adopt the content storage's existing text storage so the TextKit2 observation
        // chain stays intact. Writing to this storage will flow through
        // NSTextContentStorage → NSTextLayoutManager → NSTextContainer → view.
        if let existingStorage = textContentStorage.textStorage {
            self.storage = existingStorage
        } else {
            textContentStorage.textStorage = storage
        }
    }
#elseif canImport(AppKit)
    @available(macOS 13.0, *)
    fileprivate func connect(to textContentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager) {
        // Adopt the content storage's existing text storage so the TextKit2 observation
        // chain stays intact. Writing to this storage will flow through
        // NSTextContentStorage → NSTextLayoutManager → NSTextContainer → view.
        if let existingStorage = textContentStorage.textStorage {
            self.storage = existingStorage
        } else {
            textContentStorage.textStorage = storage
        }
    }
#endif

    func snapshotAttributedString() -> NSAttributedString {
        NSAttributedString(attributedString: storage)
    }

    /// Returns true when the given blocks differ from the backend's current records
    /// (different count, different IDs, or different content).
    func needsFullApply(for blocks: [RenderedBlock]) -> Bool {
        guard blocks.count == records.count else { return true }
        for i in blocks.indices {
            if blocks[i].id != records[i].id || blocks[i].content != records[i].content {
                return true
            }
        }
        return false
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
private final class StreamingTextKit1View: UITextView, UITextViewDelegate {
    var onMermaidContentWidthChanged: ((CGFloat?) -> Void)?
    var onContentSizeChanged: ((CGSize) -> Void)?
    var linkActionHandler: ((URL, String) -> Void)?
    private var lastMermaidWidthBucket: Int?
    private var lastReportedContentSize: CGSize = CGSize(width: -1, height: -1)

    init(backend: TextKitStreamingBackend) {
        let layoutManager = BlockquoteBarLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        layoutManager.addTextContainer(textContainer)
        backend.connect(to: layoutManager)
        super.init(frame: .zero, textContainer: textContainer)
        delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        guard let linkActionHandler else { return true }
        linkActionHandler(URL, linkDisplayText(range: characterRange))
        return false
    }

    override var intrinsicContentSize: CGSize {
        guard !isScrollEnabled else { return super.intrinsicContentSize }
        let targetWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let size = sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            setNeedsDisplay()
            invalidateIntrinsicContentSize()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        notifyMermaidContentWidthIfNeeded()
        notifyContentSizeIfNeeded()
        if !isScrollEnabled {
            invalidateIntrinsicContentSize()
        }
    }

    private func notifyMermaidContentWidthIfNeeded() {
        let insets = textContainerInset
        let width = bounds.width - insets.left - insets.right
        let normalized = width > 0 ? width : nil
        let bucket = normalized.map { Int(($0 / 8).rounded(.toNearestOrAwayFromZero)) }
        guard bucket != lastMermaidWidthBucket else { return }
        lastMermaidWidthBucket = bucket
        onMermaidContentWidthChanged?(normalized)
    }

    private func notifyContentSizeIfNeeded() {
        guard let onContentSizeChanged, bounds.width > 0 else { return }
        let fitted = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        let newSize = CGSize(width: bounds.width, height: fitted.height)
        guard abs(newSize.width - lastReportedContentSize.width) > 0.5
                || abs(newSize.height - lastReportedContentSize.height) > 0.5 else { return }
        lastReportedContentSize = newSize
        onContentSizeChanged(newSize)
    }
}

@available(iOS 16.0, *)
@MainActor
private final class StreamingTextKit2View: UITextView, UITextViewDelegate, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph,
           paragraph.attributedString.length > 0,
           paragraph.attributedString.attribute(.picoBlockquoteLevel, at: 0, effectiveRange: nil) != nil {
            return BlockquoteBarTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    var onMermaidContentWidthChanged: ((CGFloat?) -> Void)?
    var onContentSizeChanged: ((CGSize) -> Void)?
    var linkActionHandler: ((URL, String) -> Void)?
    private var lastMermaidWidthBucket: Int?
    private var lastReportedContentSize: CGSize = CGSize(width: -1, height: -1)

    init(backend: TextKitStreamingBackend) {
        super.init(frame: .zero, textContainer: nil)
        // UITextView has no `textContentStorage` accessor (that is NSTextView
        // API); reach the storage through the layout manager's content manager.
        if let layoutManager = textLayoutManager,
           let contentStorage = layoutManager.textContentManager as? NSTextContentStorage {
            backend.connect(to: contentStorage, layoutManager: layoutManager)
            // Blockquote bars are drawn by custom layout fragments (see
            // BlockquoteBarDecoration.swift).
            layoutManager.delegate = self
        }
        delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        guard let linkActionHandler else { return true }
        linkActionHandler(URL, linkDisplayText(range: characterRange))
        return false
    }

    override var intrinsicContentSize: CGSize {
        guard !isScrollEnabled else { return super.intrinsicContentSize }
        let targetWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let size = sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            setNeedsDisplay()
            invalidateIntrinsicContentSize()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        notifyMermaidContentWidthIfNeeded()
        notifyContentSizeIfNeeded()
        if !isScrollEnabled {
            invalidateIntrinsicContentSize()
        }
    }

    private func notifyMermaidContentWidthIfNeeded() {
        let insets = textContainerInset
        let width = bounds.width - insets.left - insets.right
        let normalized = width > 0 ? width : nil
        let bucket = normalized.map { Int(($0 / 8).rounded(.toNearestOrAwayFromZero)) }
        guard bucket != lastMermaidWidthBucket else { return }
        lastMermaidWidthBucket = bucket
        onMermaidContentWidthChanged?(normalized)
    }

    private func notifyContentSizeIfNeeded() {
        guard let onContentSizeChanged, bounds.width > 0 else { return }
        let fitted = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        let newSize = CGSize(width: bounds.width, height: fitted.height)
        guard abs(newSize.width - lastReportedContentSize.width) > 0.5
                || abs(newSize.height - lastReportedContentSize.height) > 0.5 else { return }
        lastReportedContentSize = newSize
        onContentSizeChanged(newSize)
    }
}

private extension UITextView {
    /// The visible text of the link at `range`, used to populate a tag's
    /// `displayText` when routing taps. Clamped defensively against the
    /// current storage length.
    func linkDisplayText(range: NSRange) -> String {
        let storage = textStorage
        let clamped = range.clamped(maxLength: storage.length)
        guard clamped.length > 0 else { return "" }
        return storage.attributedSubstring(from: clamped).string
    }
}

#elseif canImport(AppKit)
@MainActor
private final class StreamingTextKit1View: NSTextView {
    var onMermaidContentWidthChanged: ((CGFloat?) -> Void)?
    var onContentSizeChanged: ((CGSize) -> Void)?
    var linkActionHandler: ((URL, String) -> Void)?
    private var lastMermaidWidthBucket: Int?
    private var lastLaidOutWidth: CGFloat = -1
    private var lastReportedContentSize: CGSize = CGSize(width: -1, height: -1)
    var hoverHandler: ((URL?, String, CGRect?) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private var lastHoverLinkStart: Int?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        notifyHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    private func notifyHover(at point: NSPoint) {
        guard let hoverHandler else { return }
        if let info = hoverLink(at: point) {
            guard info.linkStart != lastHoverLinkStart else { return }
            lastHoverLinkStart = info.linkStart
            hoverHandler(info.url, info.displayText, info.rect)
        } else {
            clearHover()
        }
    }

    private func clearHover() {
        guard lastHoverLinkStart != nil, let hoverHandler else { return }
        lastHoverLinkStart = nil
        hoverHandler(nil, "", nil)
    }

    init(backend: TextKitStreamingBackend) {
        let layoutManager = BlockquoteBarLayoutManager()
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

    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let handler = linkActionHandler, let url = Self.linkURL(from: link) else {
            super.clicked(onLink: link, at: charIndex)
            return
        }
        handler(url, linkDisplayText(at: charIndex))
    }

    override var intrinsicContentSize: NSSize {
        guard !isVerticallyResizable else { return super.intrinsicContentSize }
        return sizeThatFits()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            needsLayout = true
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }

    override func layout() {
        super.layout()
        notifyMermaidContentWidthIfNeeded()
        notifyContentSizeIfNeeded()
        relayoutIfUsableWidthChanged()
        invalidateIntrinsicContentSize()
    }

    private func notifyContentSizeIfNeeded() {
        guard let onContentSizeChanged, bounds.width > 0,
              let textContainer, let layoutManager else { return }
        textContainer.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let newSize = CGSize(width: bounds.width, height: used.height + textContainerInset.height * 2)
        guard abs(newSize.width - lastReportedContentSize.width) > 0.5
                || abs(newSize.height - lastReportedContentSize.height) > 0.5 else { return }
        lastReportedContentSize = newSize
        onContentSizeChanged(newSize)
    }

    /// Force a one-shot full text relayout when the usable width changes. On a cold
    /// launch the first blocks (notably the H1 title) can be laid out at a transient
    /// narrow width before the split view settles; the automatic width tracking does
    /// not always reflow that early layout, leaving the heading wrapped/stale until a
    /// later relayout (which is why re-selecting the example "fixes" it). Re-laying out
    /// whenever the width actually changes makes the settled width win on first render.
    private func relayoutIfUsableWidthChanged() {
        guard let layoutManager, let textContainer else { return }
        let width = bounds.width
        guard width > 0, abs(width - lastLaidOutWidth) > 0.5 else { return }
        lastLaidOutWidth = width
        let length = layoutManager.textStorage?.length ?? 0
        guard length > 0 else { return }
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: length),
                                       actualCharacterRange: nil)
        layoutManager.ensureLayout(for: textContainer)
        needsDisplay = true
    }

    private func sizeThatFits() -> NSSize {
        guard let textContainer = textContainer, let layoutManager = layoutManager else {
            return super.intrinsicContentSize
        }
        // Defer measurement until SwiftUI has assigned a real width. The old fallback
        // laid out at an infinite container width when bounds.width == 0, which happens
        // on a cold launch: ContentView auto-selects the first example in .onAppear, so
        // the text view starts receiving streamed edits before its frame is set. Measuring
        // (and drawing) at infinite width mis-sizes the content and leaves stale glyph
        // fragments stacked at the top. Reporting "no intrinsic metric" here is corrected
        // automatically — layout()/viewDidMoveToWindow() invalidate the intrinsic size as
        // soon as a real width arrives.
        guard bounds.width > 0 else {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        textContainer.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: used.height + textContainerInset.height * 2)
    }

    private func notifyMermaidContentWidthIfNeeded() {
        let width = bounds.width - textContainerInset.width * 2
        let normalized = width > 0 ? width : nil
        let bucket = normalized.map { Int(($0 / 8).rounded(.toNearestOrAwayFromZero)) }
        guard bucket != lastMermaidWidthBucket else { return }
        lastMermaidWidthBucket = bucket
        onMermaidContentWidthChanged?(normalized)
    }
}

@available(macOS 13.0, *)
@MainActor
private final class StreamingTextKit2View: NSTextView {
    var onMermaidContentWidthChanged: ((CGFloat?) -> Void)?
    var onContentSizeChanged: ((CGSize) -> Void)?
    var linkActionHandler: ((URL, String) -> Void)?
    private var lastMermaidWidthBucket: Int?
    private var lastLaidOutWidth: CGFloat = -1
    private var lastReportedContentSize: CGSize = CGSize(width: -1, height: -1)
    var hoverHandler: ((URL?, String, CGRect?) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private var lastHoverLinkStart: Int?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        notifyHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    private func notifyHover(at point: NSPoint) {
        guard let hoverHandler else { return }
        if let info = hoverLink(at: point) {
            guard info.linkStart != lastHoverLinkStart else { return }
            lastHoverLinkStart = info.linkStart
            hoverHandler(info.url, info.displayText, info.rect)
        } else {
            clearHover()
        }
    }

    private func clearHover() {
        guard lastHoverLinkStart != nil, let hoverHandler else { return }
        lastHoverLinkStart = nil
        hoverHandler(nil, "", nil)
    }

    init(backend: TextKitStreamingBackend) {
        // Use TextKit 1 initialization: the backend storage connection works by
        // adding a layout manager to the backend's own NSTextStorage. TextKit 2's
        // NSTextContentStorage observation chain does not properly relay
        // programmatic NSTextStorage edits on macOS, resulting in blank views.
        let layoutManager = BlockquoteBarLayoutManager()
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

    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let handler = linkActionHandler, let url = Self.linkURL(from: link) else {
            super.clicked(onLink: link, at: charIndex)
            return
        }
        handler(url, linkDisplayText(at: charIndex))
    }

    override var intrinsicContentSize: NSSize {
        guard !isVerticallyResizable else { return super.intrinsicContentSize }
        return sizeThatFits()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            needsLayout = true
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }

    override func layout() {
        super.layout()
        notifyMermaidContentWidthIfNeeded()
        notifyContentSizeIfNeeded()
        relayoutIfUsableWidthChanged()
        if !isVerticallyResizable {
            invalidateIntrinsicContentSize()
        }
    }

    private func notifyContentSizeIfNeeded() {
        guard let onContentSizeChanged, bounds.width > 0,
              let textContainer, let layoutManager else { return }
        textContainer.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let newSize = CGSize(width: bounds.width, height: used.height + textContainerInset.height * 2)
        guard abs(newSize.width - lastReportedContentSize.width) > 0.5
                || abs(newSize.height - lastReportedContentSize.height) > 0.5 else { return }
        lastReportedContentSize = newSize
        onContentSizeChanged(newSize)
    }

    /// Force a one-shot full text relayout when the usable width changes. On a cold
    /// launch the first blocks (notably the H1 title) can be laid out at a transient
    /// narrow width before the split view settles; the automatic width tracking does
    /// not always reflow that early layout, leaving the heading wrapped/stale until a
    /// later relayout (which is why re-selecting the example "fixes" it). Re-laying out
    /// whenever the width actually changes makes the settled width win on first render.
    private func relayoutIfUsableWidthChanged() {
        guard let layoutManager, let textContainer else { return }
        let width = bounds.width
        guard width > 0, abs(width - lastLaidOutWidth) > 0.5 else { return }
        lastLaidOutWidth = width
        let length = layoutManager.textStorage?.length ?? 0
        guard length > 0 else { return }
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: length),
                                       actualCharacterRange: nil)
        layoutManager.ensureLayout(for: textContainer)
        needsDisplay = true
    }

    private func sizeThatFits() -> NSSize {
        guard let textContainer = textContainer, let layoutManager = layoutManager else {
            return super.intrinsicContentSize
        }
        // Defer measurement until SwiftUI has assigned a real width. The old fallback
        // laid out at an infinite container width when bounds.width == 0, which happens
        // on a cold launch: ContentView auto-selects the first example in .onAppear, so
        // the text view starts receiving streamed edits before its frame is set. Measuring
        // (and drawing) at infinite width mis-sizes the content and leaves stale glyph
        // fragments stacked at the top. Reporting "no intrinsic metric" here is corrected
        // automatically — layout()/viewDidMoveToWindow() invalidate the intrinsic size as
        // soon as a real width arrives.
        guard bounds.width > 0 else {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        textContainer.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: used.height + textContainerInset.height * 2)
    }

    private func notifyMermaidContentWidthIfNeeded() {
        let width = bounds.width - textContainerInset.width * 2
        let normalized = width > 0 ? width : nil
        let bucket = normalized.map { Int(($0 / 8).rounded(.toNearestOrAwayFromZero)) }
        guard bucket != lastMermaidWidthBucket else { return }
        lastMermaidWidthBucket = bucket
        onMermaidContentWidthChanged?(normalized)
    }
}

private extension NSTextView {
    /// Normalizes the `link` value AppKit hands to `clicked(onLink:at:)` — it
    /// may be an `URL` or a `String` depending on how the attribute was set —
    /// into a `URL`. Our renderer stores `.link` as an `URL`, but accepting
    /// both keeps this robust.
    static func linkURL(from link: Any) -> URL? {
        if let url = link as? URL { return url }
        if let string = link as? String { return URL(string: string) }
        return nil
    }

    /// The visible text of the link containing `charIndex`, used to populate a
    /// tag's `displayText`. Walks the `.link` attribute's effective range so
    /// the whole link substring is returned, not just the clicked glyph.
    func linkDisplayText(at charIndex: Int) -> String {
        guard let storage = textStorage, charIndex >= 0, charIndex < storage.length else { return "" }
        var effectiveRange = NSRange(location: 0, length: 0)
        _ = storage.attribute(.link, at: charIndex, longestEffectiveRange: &effectiveRange,
                              in: NSRange(location: 0, length: storage.length))
        let clamped = effectiveRange.clamped(maxLength: storage.length)
        guard clamped.length > 0 else { return "" }
        return storage.attributedSubstring(from: clamped).string
    }

    /// Hit-tests a point (in view coordinates) against the laid-out glyphs and,
    /// if it lands on a `.link` run, returns the link URL, its visible text, the
    /// link's start character index, and its bounding rect in view coordinates
    /// (for a host to anchor a hover popover). Returns `nil` when the point is
    /// past the text or not on a link.
    ///
    /// `linkStart` is the location of the link's `.link` effective range — the
    /// same value for every character within one link — so callers can de-dup
    /// hover events on it and fire only when entering or switching links, not on
    /// every character the cursor crosses inside the same link (which would
    /// re-report an identical url/displayText/rect).
    func hoverLink(at point: NSPoint) -> (url: URL?, displayText: String, linkStart: Int, rect: CGRect?)? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        // Reject points beyond the glyphs so trailing whitespace doesn't match.
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                                  fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1),
                                                   in: textContainer)
        guard glyphRect.contains(containerPoint) else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length else { return nil }
        var effectiveRange = NSRange(location: 0, length: 0)
        guard let link = storage.attribute(.link, at: charIndex, longestEffectiveRange: &effectiveRange,
                                           in: NSRange(location: 0, length: storage.length)) else { return nil }
        let url = Self.linkURL(from: link)
        let displayText = linkDisplayText(at: charIndex)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: effectiveRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        return (url, displayText, effectiveRange.location, rect)
    }
}
#endif

#endif
