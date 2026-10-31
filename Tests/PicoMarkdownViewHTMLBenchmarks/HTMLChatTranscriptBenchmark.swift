#if os(macOS)
import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import PicoMarkdownView
@testable import PicoMarkdownViewHTML

/// Real public views in SwiftUI's lazy chat layout, separate from the direct
/// pipeline/controller micro-measurements in HTMLTranscriptBenchmark.
@MainActor
@Suite(.serialized)
struct HTMLChatTranscriptBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PICO_HTML_CHAT_BENCHMARK"] == "1"), .timeLimit(.minutes(15)))
    func lazyTranscript() async throws {
        _ = NSApplication.shared
        let env = ProcessInfo.processInfo.environment
        let html = env["PICO_HTML_BENCH_SCENARIO"] == "html"
        let count = Int(env["PICO_HTML_BENCH_CARDS"] ?? "80") ?? 80
        let iterations = Int(env["PICO_HTML_BENCH_ITERATIONS"] ?? "3") ?? 3
        let output = try #require(env["PICO_HTML_BENCH_OUTPUT"])
        let sources = HTMLTranscriptBenchmark.messages(cards: count)
        var passes: [ChatPass] = []
        for iteration in 0..<iterations {
            passes.append(try await run(sources: sources, html: html, iteration: iteration))
            print("HTML_CHAT_BENCH pass=\(iteration) html=\(html) visits=\(passes.last!.visitedMessages) live_peak=\(passes.last!.memory.map(\.observedLivePages).max() ?? 0)")
        }
        let data = ChatResult(revision: env["PICO_HTML_BENCH_REVISION"] ?? "unspecified", scenario: html ? "html" : "native",
                              os: ProcessInfo.processInfo.operatingSystemVersionString,
                              processors: ProcessInfo.processInfo.processorCount,
                              physicalMemory: ProcessInfo.processInfo.physicalMemory,
                              messages: count, sourceBytes: sources.joined(separator: "\n").utf8.count,
                              sourceSHA256: HTMLTranscriptBenchmark.hash(Data(sources.joined(separator: "\n").utf8)),
                              streamChunkBytes: 512, streamPacingMS: 50, streamedMessages: 1,
                              build: HTMLTranscriptBenchmark.buildConfiguration,
                              sourceHashes: try HTMLTranscriptBenchmark.sourceHashes(), passes: passes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(data).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    private func run(sources: [String], html: Bool, iteration: Int) async throws -> ChatPass {
        let observer = Observer()
        let delivery = ChatDelivery()
        var session: ChatSession? = ChatSession(sources: sources, html: html, delivery: delivery)
        defer { session?.detach() }
        let heartbeat = Heartbeat()
        heartbeat.start()
        var memory = [HTMLTranscriptBenchmark.memory("beforeChat", observer: observer)]
        var visits: [Double] = []
        var visited: Set<Int> = []
        var timeouts = 0
        var firstReadyMS: Double?
        var streamedReadyMS: Double?
        var firstCopy: String?
        var firstSelection: NSRange?
        var heightBefore: CGFloat?
        var copyOnReturn: Bool?
        var selectionOnReturn: Bool?
        var maximumSettledDrift: CGFloat = 0
        let begin = HTMLTranscriptBenchmark.now
        let targets = Array(sources.indices) + sources.indices.reversed()
        for (visit, target) in targets.enumerated() {
            let start = HTMLTranscriptBenchmark.now
            session!.request(target)
            let ready = try await wait(target: target, html: html, session: session!, observer: observer)
            let end = HTMLTranscriptBenchmark.now
            visits.append(HTMLTranscriptBenchmark.ms(start, end))
            if ready { visited.insert(target) }
            else {
                print("HTML_CHAT_FIXTURE unreachable=\(target) delivery=\(await delivery.snapshot()) views=\(session!.diagnosticViews)")
                throw ChatFixtureError.unreachableMessage(target)
            }
            if target == 0, firstReadyMS == nil, ready {
                firstReadyMS = HTMLTranscriptBenchmark.ms(begin, end)
                if html {
                    firstCopy = session!.selectAttachmentAndCopy(message: 0)
                    firstSelection = session!.selection(message: 0)
                    heightBefore = session!.previewHeight(message: 0)
                }
            }
            if target == sources.count - 1, streamedReadyMS == nil, ready,
               let closure = await delivery.snapshot().closingYield {
                streamedReadyMS = HTMLTranscriptBenchmark.ms(closure, end)
            }
            let offset = session!.outerOffset
            try await Task.sleep(for: .milliseconds(50))
            session!.layout()
            session!.observe(observer)
            maximumSettledDrift = max(maximumSettledDrift, abs(session!.outerOffset - offset))
            memory.append(HTMLTranscriptBenchmark.memory("visit-\(visit)-message-\(target)", observer: observer))
        }
        if html {
            selectionOnReturn = session!.selection(message: 0) == firstSelection
            copyOnReturn = firstCopy?.contains("```html-preview") == true && session!.selectAttachmentAndCopy(message: 0) == firstCopy
        }
        try await Task.sleep(for: .milliseconds(500))
        session!.layout()
        session!.observe(observer)
        memory.append(HTMLTranscriptBenchmark.memory("settledAtFirstMessage", observer: observer))
        let streamAndScrollGaps = heartbeat.drain().map(\.milliseconds)

        // Keep message 0 offscreen while changing width, then revisit it. The
        // actual public view must reflow on return without replaying old input.
        let offscreenTarget = max(0, sources.count / 2)
        session!.request(offscreenTarget)
        if try await !wait(target: offscreenTarget, html: html, session: session!, observer: observer) { timeouts += 1 }
        session!.resize(width: 320)
        try await Task.sleep(for: .milliseconds(100))
        session!.observe(observer)
        memory.append(HTMLTranscriptBenchmark.memory("resizedWhileFirstOffscreen", observer: observer))
        session!.request(0)
        if try await !wait(target: 0, html: html, session: session!, observer: observer) { timeouts += 1 }
        let narrowHeight = html ? session!.previewHeight(message: 0) : nil
        session!.resize(width: 800)
        try await Task.sleep(for: .milliseconds(150))
        if try await !wait(target: 0, html: html, session: session!, observer: observer) { timeouts += 1 }
        let restoredHeight = html ? session!.previewHeight(message: 0) : nil
        session!.observe(observer)
        memory.append(HTMLTranscriptBenchmark.memory("settledAfterResize", observer: observer))
        let deliveryResult = await delivery.snapshot()
        session!.detach()
        try await Task.sleep(for: .milliseconds(250))
        memory.append(HTMLTranscriptBenchmark.memory("detachedWindow", observer: observer))
        session = nil
        try await Task.sleep(for: .milliseconds(500))
        memory.append(HTMLTranscriptBenchmark.memory("releasedDocument", observer: observer))
        await heartbeat.stop()
        return ChatPass(iteration: iteration, temperature: iteration == 0 ? "first-in-process" : "warm-in-process",
                        visitedMessages: visited.count, visitTimeouts: timeouts,
                        visitToReady: Distribution(visits), mainActorHeartbeat: Distribution(streamAndScrollGaps),
                        firstMessageReadyMS: firstReadyMS, streamedClosureToReadyMS: streamedReadyMS,
                        streamingAttempts: deliveryResult.attempts, streamingChunksDelivered: deliveryResult.chunks,
                        sourceCopyOnReturn: copyOnReturn, nativeSelectionOnReturn: selectionOnReturn,
                        initialPreviewHeight: heightBefore, narrowPreviewHeight: narrowHeight,
                        restoredPreviewHeight: restoredHeight,
                        maximumPostReadyScrollDriftPoints: maximumSettledDrift, memory: memory)
    }

    private func wait(target: Int, html: Bool, session: ChatSession, observer: Observer) async throws -> Bool {
        let deadline = HTMLTranscriptBenchmark.now + 5_000_000_000
        var nextRequest = HTMLTranscriptBenchmark.now + 100_000_000
        while HTMLTranscriptBenchmark.now < deadline {
            session.layout()
            session.observe(observer)
            if session.isComplete(message: target), !html || session.isPreviewReady(message: target) { return true }
            if HTMLTranscriptBenchmark.now >= nextRequest {
                // Lazy rows acquire their real height asynchronously. Request
                // the same identity again until it actually reaches the viewport.
                session.request(target)
                nextRequest = HTMLTranscriptBenchmark.now + 100_000_000
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private struct ChatMessage: Identifiable, Sendable { let id: Int; let source: String }

@MainActor
@Observable
private final class ChatScrollState {
    var target = 0
    var serial = 0
    func request(_ id: Int) { target = id; serial += 1 }
}

@MainActor
private struct ChatTranscriptView: View {
    let messages: [ChatMessage]
    let state: ChatScrollState
    let html: Bool
    let delivery: ChatDelivery

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        ChatMessageView(message: message, streamed: message.id == messages.count - 1,
                                        html: html, delivery: delivery)
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 1, alignment: .topLeading)
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: state.serial, initial: true) { _, _ in
                proxy.scrollTo(state.target, anchor: .top)
            }
        }
    }
}

@MainActor
private struct ChatMessageView: View {
    let message: ChatMessage
    let streamed: Bool
    let html: Bool
    let delivery: ChatDelivery
    var body: some View {
        if streamed {
            PicoMarkdownView(stream: { [message, delivery] in await delivery.stream(message.source) }, streamID: message.id,
                             embeddedBlockRenderers: html ? [.htmlPreview] : [])
        } else {
            PicoMarkdownView(message.source, embeddedBlockRenderers: html ? [.htmlPreview] : [])
        }
    }
}

private actor ChatDelivery {
    struct Snapshot: Sendable { let attempts: Int; let chunks: Int; let closingYield: UInt64? }
    private var attempts = 0
    private var chunks = 0
    private var closingYield: UInt64?
    func snapshot() -> Snapshot { Snapshot(attempts: attempts, chunks: chunks, closingYield: closingYield) }
    func stream(_ source: String) -> AsyncStream<String> {
        attempts += 1
        let bytes = Array(source.utf8)
        let closeEnd = source.range(of: "\n```\n", options: .backwards).map { source.utf8.distance(from: source.utf8.startIndex, to: $0.upperBound) }
        return AsyncStream { continuation in
            let task = Task {
                for offset in stride(from: 0, to: bytes.count, by: 512) {
                    guard !Task.isCancelled else { break }
                    let end = min(offset + 512, bytes.count)
                    continuation.yield(String(decoding: bytes[offset..<end], as: UTF8.self))
                    self.chunks += 1
                    if let closeEnd, offset < closeEnd, end >= closeEnd { self.closingYield = DispatchTime.now().uptimeNanoseconds }
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
private final class ChatSession {
    private var host: NSHostingView<ChatTranscriptView>?
    private var window: NSWindow?
    private let state = ChatScrollState()
    init(sources: [String], html: Bool, delivery: ChatDelivery) {
        let messages = sources.enumerated().map { ChatMessage(id: $0.offset, source: $0.element) }
        let root = ChatTranscriptView(messages: messages, state: state, html: html, delivery: delivery)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.host = host; self.window = window
        window.orderFront(nil)
        layout()
    }
    func request(_ id: Int) { state.request(id) }
    func layout() {
        host?.layoutSubtreeIfNeeded()
        if let host {
            // The command-line host has no NSApplication event-tracking loop;
            // explicitly service native layout as a normal window update does.
            for view in Observer.textViews(in: host) where Observer.isVisible(view) {
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
            }
            host.layoutSubtreeIfNeeded()
        }
        window?.displayIfNeeded()
    }
    func observe(_ observer: Observer) { if let host { observer.observeTree(host) } }
    func textView(message: Int) -> StreamingTextKit2View? {
        guard let host else { return nil }
        return Observer.textViews(in: host).first { $0.string.hasPrefix("Report \(message)\n") && Observer.isVisible($0) }
    }
    func isComplete(message: Int) -> Bool {
        textView(message: message)?.string.contains("Native paragraph after item \(message).") == true
    }
    func isPreviewReady(message: Int) -> Bool {
        guard let view = textView(message: message) else { return false }
        guard let storage = view.textStorage else { return false }
        var attachmentHeight: CGFloat?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if let attachment = value as? PicoHostedAttachment { attachmentHeight = attachment.measuredSize.height; stop.pointee = true }
        }
        return Observer().observe(view).contains { container in
            container.isReady && container.page != nil && abs(container.bounds.height - container.measuredHeight) <= 2
                && attachmentHeight.map { abs($0 - container.measuredHeight) <= 2 } == true
        }
    }
    func previewHeight(message: Int) -> CGFloat? {
        guard let view = textView(message: message) else { return nil }
        return Observer().observe(view).first?.measuredHeight
    }
    func selection(message: Int) -> NSRange? { textView(message: message)?.selectedRange() }
    func selectAttachmentAndCopy(message: Int) -> String? {
        guard let view = textView(message: message), let storage = view.textStorage else { return nil }
        var marker: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value is PicoHostedAttachment { marker = range; stop.pointee = true }
        }
        guard let marker else { return nil }
        view.setSelectedRange(marker)
        return view.markdownForSelection()
    }
    var outerOffset: CGFloat {
        func firstScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for child in view.subviews { if let scroll = firstScroll(child) { return scroll } }
            return nil
        }
        guard let host else { return 0 }
        return firstScroll(host)?.contentView.bounds.origin.y ?? 0
    }
    var diagnosticViews: [String] {
        guard let host else { return [] }
        return Observer.textViews(in: host).map { view in
            let containers = Observer().observe(view).map { "bounds=\($0.bounds) measuredHeight=\($0.measuredHeight) visible=\($0.visibleRect) mounted=\($0.window != nil) hidden=\($0.isHiddenOrHasHiddenAncestor) ready=\($0.isReady) failed=\($0.hasFailed) page=\($0.page != nil) loads=\($0.loadCount)" }
            var attachments = 0
            view.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.textStorage?.length ?? 0)) { value, _, _ in
                if value != nil { attachments += 1 }
            }
            return "\(String(view.string.prefix(36))) attachments=\(attachments) rawHTML=\(view.string.contains("<html>")) frame=\(view.frame) visible=\(view.visibleRect) containers=\(containers)"
        }
    }
    func resize(width: CGFloat) { window?.setContentSize(NSSize(width: width, height: 640)); layout() }
    func detach() {
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        host = nil
    }
}

private enum ChatFixtureError: Error { case unreachableMessage(Int) }

private struct ChatPass: Codable {
    let iteration: Int
    let temperature: String
    let visitedMessages: Int
    let visitTimeouts: Int
    let visitToReady: Distribution
    let mainActorHeartbeat: Distribution
    let firstMessageReadyMS: Double?
    let streamedClosureToReadyMS: Double?
    let streamingAttempts: Int
    let streamingChunksDelivered: Int
    let sourceCopyOnReturn: Bool?
    let nativeSelectionOnReturn: Bool?
    let initialPreviewHeight: CGFloat?
    let narrowPreviewHeight: CGFloat?
    let restoredPreviewHeight: CGFloat?
    let maximumPostReadyScrollDriftPoints: CGFloat
    let memory: [MemorySample]
}
private struct ChatResult: Codable {
    let revision: String
    let scenario: String
    let os: String
    let processors: Int
    let physicalMemory: UInt64
    let messages: Int
    let sourceBytes: Int
    let sourceSHA256: String
    let streamChunkBytes: Int
    let streamPacingMS: Int
    let streamedMessages: Int
    let build: String
    let sourceHashes: [String: String]
    let passes: [ChatPass]
}
#endif
