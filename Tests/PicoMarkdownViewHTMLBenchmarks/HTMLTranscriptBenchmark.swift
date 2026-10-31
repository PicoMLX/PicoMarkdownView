#if os(macOS)
import AppKit
import CryptoKit
import Darwin
import Foundation
import Testing
import WebKit
@testable import PicoMarkdownView
@testable import PicoMarkdownViewHTML

/// Opt-in diagnostic experiment, never a timing gate. Both modes receive the
/// same source/chunks; `native` leaves the HTML fences in their source renderer.
@MainActor
@Suite(.serialized)
struct HTMLTranscriptBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PICO_HTML_BENCHMARK"] == "1"), .timeLimit(.minutes(10)))
    func longTranscript() async throws {
        _ = NSApplication.shared
        let environment = ProcessInfo.processInfo.environment
        let mode = environment["PICO_HTML_BENCH_SCENARIO"] ?? "html"
        let count = Int(environment["PICO_HTML_BENCH_CARDS"] ?? "80") ?? 80
        let iterations = Int(environment["PICO_HTML_BENCH_ITERATIONS"] ?? "3") ?? 3
        let output = try #require(environment["PICO_HTML_BENCH_OUTPUT"])
        let source = Self.transcript(cards: count)
        let bytes = Array(source.utf8)
        let chunks = stride(from: 0, to: bytes.count, by: 512).map { offset in
            return String(decoding: bytes[offset..<min(offset + 512, bytes.count)], as: UTF8.self)
        }
        var passes: [Pass] = []
        for iteration in 0..<iterations {
            passes.append(try await run(chunks: chunks, html: mode == "html", iteration: iteration))
            print("HTML_BENCH pass=\(iteration) mode=\(mode) cards=\(count) ui_p95_ms=\(passes.last!.uiApply.p95) heartbeat_max_ms=\(passes.last!.streamHeartbeat.max)")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = ["Sources/PicoMarkdownViewHTML/HTMLPreview.swift", "Sources/PicoMarkdownViewHTML/HTMLPreviewPolicy.swift", "Sources/PicoMarkdownViewHTML/HTMLPreviewPreparation.swift", "Tests/PicoMarkdownViewHTMLBenchmarks/HTMLTranscriptBenchmark.swift"]
        let hashes = try Dictionary(uniqueKeysWithValues: files.map { path in
            let url = root.appendingPathComponent(path)
            return (path, FileManager.default.fileExists(atPath: url.path) ? Self.hash(try Data(contentsOf: url)) : "absent")
        })
        let result = ResultFile(revision: environment["PICO_HTML_BENCH_REVISION"] ?? "unspecified", scenario: mode,
                                os: ProcessInfo.processInfo.operatingSystemVersionString,
                                processors: ProcessInfo.processInfo.processorCount,
                                physicalMemory: ProcessInfo.processInfo.physicalMemory,
                                cards: count, sourceBytes: source.utf8.count, sourceSHA256: Self.hash(Data(source.utf8)),
                                chunkBytes: 512, chunkCount: chunks.count, build: Self.buildConfiguration,
                                sourceHashes: hashes, passes: passes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: URL(fileURLWithPath: output), options: .atomic)
        print("HTML_BENCH wrote \(output)")
    }

    private func run(chunks: [String], html: Bool, iteration: Int) async throws -> Pass {
        let observer = Observer()
        var pipeline: MarkdownStreamingPipeline? = MarkdownStreamingPipeline(embeddedBlockRenderers: html ? [.htmlPreview] : [])
        var session: Session? = Session()
        defer { session?.detach() }
        let heartbeat = Heartbeat()
        var feed: [Double] = [], ui: [Double] = [], closures: [Double] = [], scroll: [Double] = [], resize: [Double] = []
        var memory: [MemorySample] = []
        var ended: Set<BlockID> = []
        var closedAt: UInt64?
        var firstReadyMS: Double?
        var readinessTimeouts = 0
        var closedHTMLBlocks = 0
        var closingWindows: [(UInt64, UInt64)] = []
        let begin = Self.now
        heartbeat.start()
        await Task.yield()
        memory.append(Self.memory("beforeStream", observer: observer))

        for (index, chunk) in chunks.enumerated() {
            let start = Self.now
            let update = await pipeline!.feed(chunk)
            let fed = Self.now
            feed.append(Self.ms(start, fed))
            if let update {
                let newClosed = update.blocks.filter { block in
                    guard block.snapshot.isClosed, !ended.contains(block.id), case .fencedCode(let language) = block.kind else { return false }
                    return language == "html-preview"
                }
                for block in newClosed { ended.insert(block.id) }
                closedHTMLBlocks += newClosed.count
                if !newClosed.isEmpty, closedAt == nil { closedAt = fed }
                let applied = Self.now
                session!.apply(update)
                let finished = Self.now
                ui.append(Self.ms(applied, finished))
                if !newClosed.isEmpty {
                    closures.append(Self.ms(start, finished))
                    closingWindows.append((start, finished))
                }
            }
            if index % 8 == 0 {
                observer.observe(session!.view!)
                if firstReadyMS == nil, observer.readyContainers > 0, let closedAt { firstReadyMS = Self.ms(closedAt, Self.now) }
                memory.append(Self.memory("stream-\(index)", observer: observer))
            }
            // Cooperative burst streaming, not an LLM rate simulation. Allow
            // SwiftUI/WebKit callbacks to run; this wait is outside feed/UI times.
            try await Task.sleep(for: .milliseconds(1))
        }
        if let update = await pipeline!.finish() {
            let start = Self.now
            session!.apply(update)
            ui.append(Self.ms(start, Self.now))
        }
        observer.observe(session!.view!)
        if html {
            let deadline = Self.now + 5_000_000_000
            while observer.readyContainers == 0 && Self.now < deadline {
                session!.layout()
                observer.observe(session!.view!)
                if firstReadyMS == nil, observer.readyContainers > 0, let closedAt { firstReadyMS = Self.ms(closedAt, Self.now) }
                try await Task.sleep(for: .milliseconds(10))
            }
            if observer.readyContainers == 0 { readinessTimeouts += 1 }
        }
        let streamEnd = Self.now
        let streamTicks = heartbeat.drain()
        let streamGaps = streamTicks.map(\.milliseconds)
        let closingGaps = streamTicks.filter { tick in
            closingWindows.contains { tick.start < $0.1 && tick.end > $0.0 }
        }.map(\.milliseconds)
        memory.append(Self.memory("afterStream", observer: observer))

        // Visit the viewport in both directions. Layout/display is measured;
        // the fixed 100ms settling interval is reported separately/excluded.
        let positions = session!.attachmentPositions
        let visits = positions.isEmpty ? Array(repeating: -1, count: 26) : positions + positions.reversed()
        let fractions = (0...12).map { CGFloat($0) / 12 } + (0...12).reversed().map { CGFloat($0) / 12 }
        for (index, position) in visits.enumerated() {
            let start = Self.now
            if position < 0 { session!.scroll(to: fractions[index]) }
            else { session!.scrollAttachment(to: position) }
            scroll.append(Self.ms(start, Self.now))
            for _ in 0..<10 {
                observer.observe(session!.view!)
                try await Task.sleep(for: .milliseconds(10))
            }
            session!.layout()
            observer.observe(session!.view!)
            memory.append(Self.memory("scroll", observer: observer))
        }
        let scrollGaps = heartbeat.drain().map(\.milliseconds)
        for width in [CGFloat(480), 800] {
            let start = Self.now
            session!.resize(width: width)
            resize.append(Self.ms(start, Self.now))
            try await Task.sleep(for: .milliseconds(100))
            session!.layout()
            observer.observe(session!.view!)
        }
        memory.append(Self.memory("afterScrollAndResize", observer: observer))
        session!.detach()
        try await Task.sleep(for: .milliseconds(250))
        memory.append(Self.memory("detachedWindow", observer: observer))
        session = nil
        pipeline = nil
        try await Task.sleep(for: .milliseconds(500))
        memory.append(Self.memory("releasedDocument", observer: observer))
        await heartbeat.stop()
        return Pass(iteration: iteration, temperature: iteration == 0 ? "first-in-process" : "warm-in-process",
                    feed: Distribution(feed), uiApply: Distribution(ui), closingChunk: Distribution(closures),
                    streamHeartbeat: Distribution(streamGaps), closingHeartbeat: Distribution(closingGaps), scrollLayout: Distribution(scroll),
                    scrollHeartbeat: Distribution(scrollGaps), resizeLayout: Distribution(resize),
                    streamWallMS: Self.ms(begin, streamEnd), firstPreviewReadyMS: firstReadyMS,
                    closedHTMLBlocks: closedHTMLBlocks, readinessTimeouts: readinessTimeouts,
                    observedContainers: observer.containers.count, observedPages: observer.pages.count,
                    memory: memory)
    }

    private static func transcript(cards: Int) -> String {
        (0..<cards).map { index in
            let rows = (0..<12).map { row in
                "<tr><td>Line \(row)</td><td>Stable detail for item \(index), with text and <strong>emphasis</strong>.</td><td>\(index * 12 + row)</td></tr>"
            }.joined(separator: "\n")
            return """
            ## Report \(index)

            Native paragraph before item \(index), with **bold**, *emphasis*, and a short list.

            - First native item.
            - Second native item.

            ```html-preview
            <html><head><style>.report {padding:12px;border:1px solid #789;border-radius:8px} .report table {border-collapse:collapse;width:100%;font-size:12px} .report td {padding:3px;border-bottom:1px solid #999} .report h3 {margin:0 0 8px}</style></head><body>
            <section class="report"><h3>Static report \(index)</h3><table><tbody>
            \(rows)
            </tbody></table></section></body></html>
            ```

            Native paragraph after item \(index). Streaming continues incrementally in the same document.

            """
        }.joined(separator: "\n")
    }

    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(to - from) / 1_000_000 }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static var buildConfiguration: String {
#if DEBUG
        "debug"
#else
        "release"
#endif
    }

    private static func memory(_ phase: String, observer: Observer) -> MemorySample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return MemorySample(phase: phase, hostFootprintBytes: status == KERN_SUCCESS ? info.phys_footprint : nil,
                            hostResidentBytes: status == KERN_SUCCESS ? info.resident_size : nil,
                            observedRetainedContainers: observer.retainedContainers, observedLivePages: observer.livePages,
                            attachedPages: observer.attachedPages, readyContainers: observer.readyContainers,
                            failedContainers: observer.failedContainers, mountedContainers: observer.mountedContainers)
    }
}

@MainActor
private final class Session {
    var controller: TextKitStreamingController?
    var view: StreamingTextKit2View?
    private var scroll: NSScrollView?
    private var window: NSWindow?
    private var width: CGFloat = 800

    init() {
        let controller = TextKitStreamingController()
        let view = controller.makeTextKit2View(configuration: .default()) as! StreamingTextKit2View
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 640))
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        self.controller = controller; self.view = view; self.scroll = scroll; self.window = window
        view.setFrameSize(NSSize(width: 800, height: 640))
        window.orderFront(nil)
    }

    func apply(_ update: StreamingUpdate) {
        controller!.update(textView: view!, blocks: update.blocks, diffs: [update.diff], replaceToken: 1, configuration: .default())
        layout()
    }

    func layout() {
        guard let view else { return }
        let height = max(640, view.intrinsicContentSize.height)
        if abs(view.frame.height - height) > 0.5 { view.setFrameSize(NSSize(width: width, height: height)) }
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
    }

    func scroll(to fraction: CGFloat) {
        guard let scroll, let view else { return }
        layout()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, view.frame.height - scroll.contentView.bounds.height) * fraction))
        scroll.reflectScrolledClipView(scroll.contentView)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
    }

    var attachmentPositions: [Int] {
        guard let storage = view?.textStorage else { return [] }
        var positions: [Int] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value is PicoHostedAttachment { positions.append(range.location) }
        }
        return positions
    }

    func scrollAttachment(to location: Int) {
        layout()
        view?.scrollRangeToVisible(NSRange(location: location, length: 1))
        view?.needsLayout = true
        view?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
    }

    func resize(width: CGFloat) {
        self.width = width
        window?.setContentSize(NSSize(width: width, height: 640))
        view?.setFrameSize(NSSize(width: width, height: view?.frame.height ?? 640))
        layout()
    }

    func detach() {
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        scroll?.documentView = nil
        scroll = nil
        view = nil
        controller = nil
    }
}

@MainActor
private final class Observer {
    final class WeakContainer { weak var value: HTMLPreviewContainer?; init(_ value: HTMLPreviewContainer) { self.value = value } }
    final class WeakPage { weak var value: WebPage?; init(_ value: WebPage) { self.value = value } }
    var containers: [ObjectIdentifier: WeakContainer] = [:]
    var pages: [ObjectIdentifier: WeakPage] = [:]
    var attachedPages: Int { containers.values.filter { $0.value?.page != nil && $0.value?.window != nil }.count }
    var readyContainers: Int { containers.values.filter { $0.value?.isReady == true && $0.value?.window != nil }.count }
    var retainedContainers: Int { containers.values.filter { $0.value != nil }.count }
    var livePages: Int { pages.values.filter { $0.value != nil }.count }
    var failedContainers: Int { containers.values.filter { $0.value?.hasFailed == true }.count }
    var mountedContainers: Int { containers.values.filter { $0.value?.window != nil }.count }

    func observe(_ view: NSTextView) {
        var visited: Set<ObjectIdentifier> = []
        var found: [HTMLPreviewContainer] = []
        func visit(_ view: NSView) {
            guard visited.insert(ObjectIdentifier(view)).inserted else { return }
            if let container = view as? HTMLPreviewContainer { found.append(container) }
            for child in view.subviews { visit(child) }
        }
        visit(view)
        if let storage = view.textStorage, storage.length > 0 {
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let attachment = value as? PicoHostedAttachment, let host = attachment.hostingView { visit(host) }
            }
        }
        for container in found {
            containers[ObjectIdentifier(container)] = WeakContainer(container)
            if let page = container.page { pages[ObjectIdentifier(page)] = WeakPage(page) }
        }
    }
}

@MainActor
private final class Heartbeat {
    private var task: Task<Void, Never>?
    struct Sample {
        let start: UInt64
        let end: UInt64
        var milliseconds: Double { Double(end - start) / 1_000_000 }
    }
    private var samples: [Sample] = []
    func start() {
        task = Task { @MainActor [weak self] in
            var previous = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                let now = DispatchTime.now().uptimeNanoseconds
                self?.samples.append(Sample(start: previous, end: now))
                previous = now
            }
        }
    }
    func drain() -> [Sample] { defer { samples.removeAll(keepingCapacity: true) }; return samples }
    func stop() async { task?.cancel(); await task?.value; task = nil }
}

private struct Distribution: Codable {
    let count: Int
    let p50: Double
    let p95: Double
    let max: Double
    init(_ samples: [Double]) {
        let values = samples.sorted()
        count = values.count
        func percentile(_ p: Double) -> Double { values.isEmpty ? 0 : values[min(values.count - 1, Int((Double(values.count) * p).rounded(.up)) - 1)] }
        p50 = percentile(0.50); p95 = percentile(0.95); max = values.last ?? 0
    }
}
private struct MemorySample: Codable {
    let phase: String
    let hostFootprintBytes: UInt64?
    let hostResidentBytes: UInt64?
    let observedRetainedContainers: Int
    let observedLivePages: Int
    let attachedPages: Int
    let readyContainers: Int
    let failedContainers: Int
    let mountedContainers: Int
}
private struct Pass: Codable {
    let iteration: Int
    let temperature: String
    let feed: Distribution
    let uiApply: Distribution
    let closingChunk: Distribution
    let streamHeartbeat: Distribution
    let closingHeartbeat: Distribution
    let scrollLayout: Distribution
    let scrollHeartbeat: Distribution
    let resizeLayout: Distribution
    let streamWallMS: Double
    let firstPreviewReadyMS: Double?
    let closedHTMLBlocks: Int
    let readinessTimeouts: Int
    let observedContainers: Int
    let observedPages: Int
    let memory: [MemorySample]
}
private struct ResultFile: Codable {
    let revision: String
    let scenario: String
    let os: String
    let processors: Int
    let physicalMemory: UInt64
    let cards: Int
    let sourceBytes: Int
    let sourceSHA256: String
    let chunkBytes: Int
    let chunkCount: Int
    let build: String
    let sourceHashes: [String: String]
    let passes: [Pass]
}
#endif
