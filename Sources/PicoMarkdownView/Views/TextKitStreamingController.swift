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
#if canImport(AppKit)
    private var lastAppliedDocumentIdentity: UInt64?
#endif

#if canImport(UIKit)
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
    func makeTextKit2View(configuration: PicoTextKitConfiguration) -> NSTextView {
        let textView = StreamingTextKit2View(backend: backend)
        configure(textView, with: configuration)
        return textView
    }

    func update(textView: NSTextView,
                blocks: [RenderedBlock],
                diffs: [AssemblerDiff],
                replaceToken: UInt64,
                configuration: PicoTextKitConfiguration,
                documentIdentity: UInt64? = nil) {
        Self.logger.debug("Updating text view: blocks=\(blocks.count), replacementToken=\(replaceToken), appliedReplacementToken=\(self.lastAppliedReplaceToken), storageLength=\(self.backend.length)")
        configure(textView, with: configuration)
        let currentSelection = configuration.isSelectable ? textView.selectedRange() : NSRange(location: backend.length, length: 0)
        backend.setPaused(configuration.isPaused)
        let documentChanged = documentIdentity != nil && documentIdentity != lastAppliedDocumentIdentity
        if documentChanged {
            lastAppliedDocumentIdentity = documentIdentity
            backend.resetDocumentOnNextApply()
        }
        if replaceToken != lastAppliedReplaceToken || documentChanged {
            lastAppliedReplaceToken = replaceToken
            lastAppliedVersion = 0
            if documentIdentity == nil { backend.resetDocumentOnNextApply() }
            let selection = backend.apply(blocks: blocks, selection: currentSelection)
            if configuration.isSelectable { textView.setSelectedRange(selection.clamped(maxLength: backend.length)) }
            Self.logger.debug("Text view content replaced: storageLength=\(self.backend.length)")
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
        view.isHorizontallyResizable = false
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
        (textView as? StreamingTextKit2View)?.onMermaidContentWidthChanged = observer
        observer(mermaidContentWidth(for: textView))
    }

    func installContentSizeObserver(on textView: UITextView, _ observer: ((CGSize) -> Void)?) {
        (textView as? StreamingTextKit2View)?.onContentSizeChanged = observer
    }

    func installLinkHandler(on textView: UITextView, _ handler: ((URL, String) -> Void)?) {
        (textView as? StreamingTextKit2View)?.linkActionHandler = handler
    }
#elseif canImport(AppKit)
    func mermaidContentWidth(for textView: NSTextView) -> CGFloat? {
        let inset = textView.textContainerInset
        let width = textView.bounds.width - inset.width * 2
        return width > 0 ? width : nil
    }

    func installMermaidWidthObserver(on textView: NSTextView, _ observer: @escaping (CGFloat?) -> Void) {
        (textView as? StreamingTextKit2View)?.onMermaidContentWidthChanged = observer
        observer(mermaidContentWidth(for: textView))
    }

    func installContentSizeObserver(on textView: NSTextView, _ observer: ((CGSize) -> Void)?) {
        (textView as? StreamingTextKit2View)?.onContentSizeChanged = observer
    }

    func installLinkHandler(on textView: NSTextView, _ handler: ((URL, String) -> Void)?) {
        (textView as? StreamingTextKit2View)?.linkActionHandler = handler
        backend.onHostedLink = handler
    }

    func installHoverHandler(on textView: NSTextView, _ handler: ((URL?, String, CGRect?) -> Void)?) {
        (textView as? StreamingTextKit2View)?.hoverHandler = handler
        backend.onHostedHover = handler
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
#if canImport(AppKit)
        var table: RenderedTable? = nil
        var tableSnapshot: TableSnapshot? = nil
        var hostedAttachments: [HostedRecord] = []
#endif
    }

#if canImport(AppKit)
    private struct HostedRecord {
        var attachment: PicoHostedAttachment
        var offset: Int
        var indent: CGFloat
    }
#endif

    private struct DeferredUpdate {
        var blocks: [RenderedBlock]
        var diffs: [AssemblerDiff]
    }

    private var storage = NSTextStorage()
#if canImport(AppKit)
    private weak var contentStorage: NSTextContentStorage?
    private var hostedTables: [BlockID: (model: PicoHostedTableModel, attachment: PicoHostedAttachment)] = [:]
    private var hostedRefreshIDs: Set<BlockID> = []
    private var shouldResetDocument = false
    var onHostedHover: ((URL?, String, CGRect?) -> Void)?
    var onHostedLink: ((URL, String) -> Void)?
    var onHostedContentSizeChanged: ((NSRange) -> Void)?
#endif

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
#if canImport(AppKit)
        if let contentStorage {
            var result = selection
            contentStorage.performEditingTransaction {
                result = applyToStorage(blocks: blocks, diffs: diffs, selection: selection)
            }
            return result
        }
#endif
        return applyToStorage(blocks: blocks, diffs: diffs, selection: selection)
    }

    private func applyToStorage(blocks: [RenderedBlock], diffs: [AssemblerDiff], selection: NSRange) -> NSRange {
        if isPaused {
            deferred = DeferredUpdate(blocks: blocks, diffs: diffs)
            return selection.clamped(maxLength: storage.length)
        }
#if canImport(AppKit)
        let selection = shouldResetDocument ? NSRange(location: 0, length: 0) : selection
        if shouldResetDocument {
            shouldResetDocument = false
            if storage.length > 0 {
                storage.beginEditing()
                storage.setAttributedString(NSAttributedString())
                storage.endEditing()
            }
            records.removeAll()
            blockOffsets = [0]
            indexByID.removeAll()
            hostedTables.removeAll()
        }
#endif
        if deferred != nil {
            deferred = nil
        }
#if canImport(AppKit)
        hostedRefreshIDs = diffs.isEmpty ? Set(blocks.map(\.id)) : Set(diffs.flatMap { diff in
            diff.changes.compactMap { change in
                if case .blockEnded(let id) = change { return id }
                return nil
            }
        })
        defer { hostedRefreshIDs.removeAll(keepingCapacity: true) }
#endif
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
#if canImport(AppKit)
                hostedTables.removeAll()
#endif
                return NSRange(location: 0, length: 0)
            }
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString())
            storage.endEditing()
            records = []
            blockOffsets = [0]
            indexByID = [:]
#if canImport(AppKit)
            hostedTables.removeAll()
#endif
            return NSRange(location: 0, length: 0)
        }

        let blockData: [(block: RenderedBlock, attributed: NSAttributedString)] = blocks.enumerated().map { index, block in
            if index < records.count && records[index].id == block.id && recordMatches(records[index], block: block) {
                return (block: block, attributed: records[index].nsAttributed)
            } else {
                return (block: block, attributed: attributedString(for: block))
            }
        }

        if records.count != blockData.count || !zip(records, blockData).allSatisfy({ $0.0.id == $0.1.block.id }) {
            return replaceAll(with: blockData, selection: selection)
        }

        // Check if any content actually changed before editing
        let hasChanges = zip(records, blockData).contains { !recordMatches($0.0, block: $0.1.block) }
        guard hasChanges else {
            return selection.clamped(maxLength: storage.length)
        }

        var updatedSelection = selection

        storage.beginEditing()
        defer { storage.endEditing() }
        for index in records.indices {
            let record = records[index]
            let data = blockData[index]
            if recordMatches(record, block: data.block) { continue }
#if canImport(AppKit)
            if updateHostedTableOnly(at: index, block: data.block) { continue }
#endif

            let oldLength = record.length
            let range = rangeForBlock(at: index, data: blockData)
            storage.replaceCharacters(in: range, with: data.attributed)
            updatedSelection = adjust(selection: updatedSelection, editedRange: range, replacementLength: data.attributed.length)

            records[index].content = data.block.content
            records[index].length = data.attributed.length
            records[index].nsAttributed = data.attributed
            updateTableRecord(at: index, block: data.block)

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
                // A new child changes what its parent renders (container-only
                // quote parents render nothing once a child exists) and the
                // diff carries no change entry for the parent — sync its
                // record too. No-op when the parent's content is unchanged.
                if let parentID = blocks[index].snapshot.parentID {
                    updatedSelection = updateRecord(id: parentID, blocks: blocks, selection: updatedSelection)
                }
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
        let attributed = attributedString(for: block)
        let record = BlockRecord(id: block.id,
                                 content: block.content,
                                 nsAttributed: attributed,
                                 length: attributed.length)
        let clampedIndex = max(0, min(index, records.count))
        let location = clampedIndex < blockOffsets.count ? blockOffsets[clampedIndex] : storage.length
        let editedRange = NSRange(location: location, length: 0)

        storage.replaceCharacters(in: editedRange, with: attributed)

        records.insert(record, at: clampedIndex)
        updateTableRecord(at: clampedIndex, block: block)
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
        guard !recordMatches(record, block: block) else { return selection }
#if canImport(AppKit)
        if updateHostedTableOnly(at: index, block: block) { return selection }
#endif

        let newAttributed = attributedString(for: block)
        let range = rangeForRecord(at: index)
#if canImport(AppKit)
        // Preserve the already-rendered prefix of an open paragraph/code block.
        // Its terminal newline moves as text streams; only that tail is edited.
        let prefixLength = reusablePrefixLength(old: record.nsAttributed, new: newAttributed)
        let edit = NSRange(location: range.location + prefixLength, length: range.length - prefixLength)
        let replacement = newAttributed.attributedSubstring(from: NSRange(location: prefixLength, length: newAttributed.length - prefixLength))
        storage.replaceCharacters(in: edit, with: replacement)
        let updatedSelection = adjust(selection: selection, editedRange: edit, replacementLength: replacement.length)
#else
        storage.replaceCharacters(in: range, with: newAttributed)
        let updatedSelection = adjust(selection: selection, editedRange: range, replacementLength: newAttributed.length)
#endif

        let oldLength = record.length
        records[index].content = block.content
        records[index].length = newAttributed.length
        records[index].nsAttributed = newAttributed
        updateTableRecord(at: index, block: block)

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
#if canImport(AppKit)
            hostedTables.removeValue(forKey: record.id)
#endif
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
#if canImport(AppKit)
        let liveIDs = Set(blockData.map { $0.block.id })
        hostedTables = hostedTables.filter { liveIDs.contains($0.key) }
#endif
        return selection.clamped(maxLength: storage.length)
    }

    private func rebuildRecords(using blockData: [(block: RenderedBlock, attributed: NSAttributedString)]) {
        records = blockData.map { BlockRecord(id: $0.block.id, content: $0.block.content, nsAttributed: $0.attributed, length: $0.attributed.length) }
        for index in records.indices { updateTableRecord(at: index, block: blockData[index].block) }
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

#if canImport(AppKit)
        if delta == 0 { return result }
        if editEnd <= result.location {
            result.location += delta
        } else if editedRange.location < selectionEnd {
            let start = min(result.location, editedRange.location)
            let end = selectionEnd >= editEnd
                ? selectionEnd + delta
                : editedRange.location + min(replacementLength, selectionEnd - editedRange.location)
            result = NSRange(location: start, length: max(0, end - start))
        }
        return result
#else
        if editEnd <= result.location {
            result.location += delta
        } else if editedRange.location >= selectionEnd {
            return result
        } else {
            result.location = editedRange.location
            result.length = max(0, min(replacementLength, selectionEnd - editedRange.location))
        }

        return result
#endif
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
    func connect(to textContentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager) {
        contentStorage = textContentStorage
        if let existingStorage = textContentStorage.textStorage {
            storage = existingStorage
        } else {
            textContentStorage.textStorage = storage
        }
    }

#endif

    private func recordMatches(_ record: BlockRecord, block: RenderedBlock) -> Bool {
#if canImport(AppKit)
        return record.content == block.content && record.table == block.table && record.tableSnapshot == block.snapshot.table
#else
        return record.content == block.content
#endif
    }

    private func updateTableRecord(at index: Int, block: RenderedBlock) {
#if canImport(AppKit)
        records[index].table = block.table
        records[index].tableSnapshot = block.snapshot.table
        let attributed = records[index].nsAttributed
        var hosted: [HostedRecord] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let attachment = value as? PicoHostedAttachment else { return }
            let paragraph = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let indent = max(paragraph?.headIndent ?? 0, paragraph?.firstLineHeadIndent ?? 0)
            hosted.append(HostedRecord(attachment: attachment, offset: range.location, indent: indent))
            let id = block.id
            attachment.onLayoutInvalidated = { [weak self] _ in
                guard let self, let index = self.indexByID[id] else { return }
                self.onHostedContentSizeChanged?(self.rangeForRecord(at: index))
            }
        }
        records[index].hostedAttachments = hosted
#endif
    }

    private func attributedString(for block: RenderedBlock) -> NSAttributedString {
#if canImport(AppKit)
        guard let table = block.table, let snapshot = block.snapshot.table else {
            hostedTables.removeValue(forKey: block.id)
            return NSAttributedString.picoConverted(from: block.content)
        }
        let entry: (model: PicoHostedTableModel, attachment: PicoHostedAttachment)
        if let existing = hostedTables[block.id] {
            entry = existing
            entry.model.update(table: table, snapshot: snapshot, refreshExisting: hostedRefreshIDs.contains(block.id))
        } else {
            let model = PicoHostedTableModel(table: table, snapshot: snapshot)
            model.onOpenLink = { [weak self] url, text in
                if let handler = self?.onHostedLink { handler(url, text) }
                else { NSWorkspace.shared.open(url) }
            }
            model.onHoverLink = { [weak self] url, text, rect in self?.onHostedHover?(url, text, rect) }
            let attachment = PicoHostedAttachment(interaction: .selectableBlock,
                markdown: { model.markdownRepresentation() }) { context in
                    PicoHostedTableView(model: model, context: context)
                }
            entry = (model, attachment)
            hostedTables[block.id] = entry
        }
        let attributed = NSMutableAttributedString(attributedString: .picoConverted(from: block.content))
        let marker = (attributed.string as NSString).range(of: "\u{FFFC}")
        if marker.location != NSNotFound {
            attributed.addAttribute(.attachment, value: entry.attachment, range: marker)
        }
        return attributed
#else
        return NSAttributedString.picoConverted(from: block.content)
#endif
    }

#if canImport(AppKit)
    private func updateHostedTableOnly(at index: Int, block: RenderedBlock) -> Bool {
        guard records[index].content == block.content,
              let table = block.table, let snapshot = block.snapshot.table,
              let entry = hostedTables[block.id] else { return false }
        entry.model.update(table: table, snapshot: snapshot, refreshExisting: hostedRefreshIDs.contains(block.id))
        entry.attachment.invalidateSize()
        updateTableRecord(at: index, block: block)
        return true
    }

    private func reusablePrefixLength(old: NSAttributedString, new: NSAttributedString) -> Int {
        guard old.length > 0, new.length >= old.length else { return 0 }
        let length = old.string.hasSuffix("\n") ? old.length - 1 : old.length
        guard length > 0,
              old.attributedSubstring(from: NSRange(location: 0, length: length))
                .isEqual(to: new.attributedSubstring(from: NSRange(location: 0, length: length))) else { return 0 }
        return length
    }

    func updateHostedAttachments(width: CGFloat, selection: [NSRange]) {
        for index in records.indices where !records[index].hostedAttachments.isEmpty {
            let range = rangeForRecord(at: index)
            for hosted in records[index].hostedAttachments {
                let markerRange = NSRange(location: range.location + hosted.offset, length: 1)
                let selected = selection.contains { NSIntersectionRange($0, markerRange).length > 0 }
                hosted.attachment.update(availableWidth: max(1, width - hosted.indent), isSelected: selected)
            }
        }
    }

    func resetDocumentOnNextApply() { shouldResetDocument = true }

    func hostedAttachment(for id: BlockID) -> PicoHostedAttachment? { hostedTables[id]?.attachment }
#endif

    func snapshotAttributedString() -> NSAttributedString {
        NSAttributedString(attributedString: storage)
    }

    /// Returns true when the given blocks differ from the backend's current records
    /// (different count, different IDs, or different content).
    func needsFullApply(for blocks: [RenderedBlock]) -> Bool {
        guard blocks.count == records.count else { return true }
        for i in blocks.indices {
            if blocks[i].id != records[i].id || !recordMatches(records[i], block: blocks[i]) {
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
private final class StreamingTextKit2View: UITextView, UITextViewDelegate, NSTextLayoutManagerDelegate {
    // Nonisolated: NSTextLayoutManagerDelegate is not main-actor bound (TextKit 2
    // may lay out off the main thread), and this only inspects the element.
    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
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

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        TextItemLinkAction.make(for: textItem.content, range: textItem.range,
                                in: textView, defaultAction: defaultAction, handler: linkActionHandler)
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

@MainActor
enum TextItemLinkAction {
    static func make(for content: UITextItem.Content, range: NSRange,
                     in textView: UITextView, defaultAction: UIAction,
                     handler: ((URL, String) -> Void)?) -> UIAction {
        guard case let .link(url) = content, let handler else { return defaultAction }
        let displayText = textView.linkDisplayText(range: range)
        return UIAction(title: defaultAction.title, image: defaultAction.image) { _ in
            handler(url, displayText)
        }
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

#endif

#endif
