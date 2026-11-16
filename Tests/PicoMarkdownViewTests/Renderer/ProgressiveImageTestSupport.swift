#if os(macOS)
import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PicoMarkdownView

/// Generated entirely in the test: no downloaded image or third-party fixture.
struct ProgressiveImageFixture: Sendable {
    let data: Data
    let size: CGSize
    let mimeType: String
    static let jpeg = Result { try make(type: .jpeg, progressive: true) }
    static let baseline = Result { try make(type: .jpeg, progressive: false) }
    static let png = Result { try make(type: .png, progressive: false) }
    static let rotated = Result { try make(type: .jpeg, progressive: true, orientation: 6) }

    private static func make(type: UTType, progressive: Bool, orientation: Int = 1) throws -> Self {
        let width = 1536, height = 768
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 37 + y * 13) % 256)
                pixels[offset + 1] = UInt8((x * 11 + y * 29) % 256)
                pixels[offset + 2] = UInt8((x ^ y) % 256)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.75,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: progressive],
            kCGImagePropertyOrientation: orientation
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        let encoded = data as Data
        if type == .jpeg {
            let marker: UInt8 = progressive ? 0xc2 : 0xc0
            try #require(encoded.range(of: Data([0xff, marker])) != nil,
                         "The fixture must use the requested progressive/baseline JPEG frame type")
        }
        return Self(data: encoded,
                    size: orientation == 6 ? CGSize(width: height, height: width) : CGSize(width: width, height: height),
                    mimeType: type == .png ? "image/png" : "image/jpeg")
    }
}

final class ProgressivePreviewCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MarkdownImageResult] = []
    private let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (events, continuation) = AsyncStream<Void>.makeStream() }
    var results: [MarkdownImageResult] { lock.withLock { values } }
    func append(_ result: MarkdownImageResult) {
        lock.withLock { values.append(result) }
        continuation.yield()
    }
    func waitForCount(_ count: Int) async throws {
        var iterator = events.makeAsyncIterator()
        while results.count < count {
            try Task.checkCancellation()
            _ = try #require(await iterator.next())
        }
    }
    deinit { continuation.finish() }
}

final class ProgressiveCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    var value: Bool { lock.withLock { completed } }
    func finish() { lock.withLock { completed = true } }
}

/// The test decides exactly when bytes and network completion are released.
/// URLProtocol callbacks are serialized; no timer or live server is involved.
final class ControlledProgressiveImageTransfer: @unchecked Sendable {
    let url: URL
    private let fixture: ProgressiveImageFixture
    private let queue = DispatchQueue(label: "PicoMarkdownViewTests.progressive-transfer")
    private let lock = NSLock()
    private var connection: ProgressiveImageURLProtocol?
    private var starts = 0
    private var stops = 0
    private var completed = false
    private let startEvents: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private let stopEvents: AsyncStream<Void>
    private let stopContinuation: AsyncStream<Void>.Continuation

    init(fixture: ProgressiveImageFixture, url: URL? = nil) {
        self.fixture = fixture
        self.url = url ?? URL(string: "https://progressive.invalid/\(UUID().uuidString).image")!
        (startEvents, startContinuation) = AsyncStream<Void>.makeStream()
        (stopEvents, stopContinuation) = AsyncStream<Void>.makeStream()
        ProgressiveImageURLProtocol.register(self)
    }
    var requestCount: Int { lock.withLock { starts } }
    var stoppedCount: Int { lock.withLock { stops } }
    var hasCompleted: Bool { lock.withLock { completed } }

    func attach(_ sender: ProgressiveImageURLProtocol) {
        queue.async { [self] in
            lock.withLock { connection = sender; starts += 1 }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": fixture.mimeType, "Content-Length": String(fixture.data.count)])!
            sender.client?.urlProtocol(sender, didReceive: response, cacheStoragePolicy: .notAllowed)
            startContinuation.yield()
        }
    }
    func stop(_ sender: ProgressiveImageURLProtocol) {
        queue.async { [self] in
            let stopped = lock.withLock {
                guard connection === sender else { return false }
                connection = nil
                stops += 1
                return true
            }
            if stopped { stopContinuation.yield() }
        }
    }
    func send(_ data: Data) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let sender = lock.withLock({ connection }) {
                    sender.client?.urlProtocol(sender, didLoad: data)
                }
                continuation.resume()
            }
        }
    }
    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let sender = lock.withLock { () -> ProgressiveImageURLProtocol? in
                    completed = true
                    let value = connection
                    connection = nil
                    return value
                }
                if let sender { sender.client?.urlProtocolDidFinishLoading(sender) }
                continuation.resume()
            }
        }
    }
    func waitForStart() async throws {
        var iterator = startEvents.makeAsyncIterator()
        while requestCount == 0 {
            try Task.checkCancellation()
            _ = try #require(await iterator.next())
        }
    }
    func waitForStop() async throws {
        var iterator = stopEvents.makeAsyncIterator()
        while stoppedCount == 0 {
            try Task.checkCancellation()
            _ = try #require(await iterator.next())
        }
    }
    func unregister() { ProgressiveImageURLProtocol.unregister(url) }
}

final class ProgressiveImageURLProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var transfers: [URL: ControlledProgressiveImageTransfer] = [:]
    }
    private static let registry = Registry()
    private let bindingLock = NSLock()
    private var transfer: ControlledProgressiveImageTransfer?

    static func register(_ transfer: ControlledProgressiveImageTransfer) {
        registry.lock.withLock { registry.transfers[transfer.url] = transfer }
    }
    static func unregister(_ url: URL) {
        registry.lock.withLock { registry.transfers[url] = nil }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "progressive.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let transfer = Self.registry.lock.withLock({ Self.registry.transfers[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        bindingLock.withLock { self.transfer = transfer }
        transfer.attach(self)
    }
    override func stopLoading() { bindingLock.withLock { transfer }?.stop(self) }
}

func progressiveImageSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProgressiveImageURLProtocol.self]
    return URLSession(configuration: configuration)
}

func awaitProgressiveSubscribers(_ expected: Int, provider: URLSessionMarkdownImageProvider, url: URL) async throws {
    while await provider.activeProgressiveSubscriberCount(for: url) != expected {
        try Task.checkCancellation()
        await Task.yield()
    }
}
#endif
