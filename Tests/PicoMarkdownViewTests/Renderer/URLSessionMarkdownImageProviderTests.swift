import Foundation
import XCTest
@testable import PicoMarkdownView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

final class URLSessionMarkdownImageProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testPrefetchCachesDecodedImageAndImageForReturnsCachedResult() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/image.png"))
        let data = try makePNGData(size: CGSize(width: 24, height: 12))

        StubURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url ?? url,
                                                         statusCode: 200,
                                                         httpVersion: nil,
                                                         headerFields: ["Content-Type": "image/png"]))
            return StubURLProtocol.Response(response: response, data: data)
        }

        let session = makeStubSession()
        defer { session.invalidateAndCancel() }
        let provider = URLSessionMarkdownImageProvider(session: session)

        let uncached = await provider.image(for: url)
        XCTAssertNil(uncached)
        let loaded = await provider.prefetch(url)
        XCTAssertNotNil(loaded)
        let cached = await provider.image(for: url)
        XCTAssertEqual(cached?.size, loaded?.size)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testUnsupportedSchemesAreRejected() async throws {
        let session = makeStubSession()
        defer { session.invalidateAndCancel() }
        let provider = URLSessionMarkdownImageProvider(session: session)

        let fileURL = URL(fileURLWithPath: "/tmp/test.png")
        let fileImage = await provider.image(for: fileURL)
        XCTAssertNil(fileImage)
        let filePrefetch = await provider.prefetch(fileURL)
        XCTAssertNil(filePrefetch)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)

        let dataURL = try XCTUnwrap(URL(string: "data:image/png;base64,AAAA"))
        let dataImage = await provider.image(for: dataURL)
        XCTAssertNil(dataImage)
        let dataPrefetch = await provider.prefetch(dataURL)
        XCTAssertNil(dataPrefetch)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testConcurrentPrefetchesDeduplicateInFlightRequest() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/slow.png"))
        let data = try makePNGData(size: CGSize(width: 16, height: 16))

        StubURLProtocol.handler = { request in
            try awaitTaskFriendlyDelay()
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url ?? url,
                                                         statusCode: 200,
                                                         httpVersion: nil,
                                                         headerFields: ["Content-Type": "image/png"]))
            return StubURLProtocol.Response(response: response, data: data)
        }

        let session = makeStubSession()
        defer { session.invalidateAndCancel() }
        let provider = URLSessionMarkdownImageProvider(session: session)

        async let first = provider.prefetch(url)
        async let second = provider.prefetch(url)
        let (a, b) = await (first, second)

        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testNonImageResponseReturnsNil() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/not-image.txt"))

        StubURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url ?? url,
                                                         statusCode: 200,
                                                         httpVersion: nil,
                                                         headerFields: ["Content-Type": "text/plain"]))
            return StubURLProtocol.Response(response: response, data: Data("hello".utf8))
        }

        let session = makeStubSession()
        defer { session.invalidateAndCancel() }
        let provider = URLSessionMarkdownImageProvider(session: session)

        let result = await provider.prefetch(url)
        XCTAssertNil(result)
        let cached = await provider.image(for: url)
        XCTAssertNil(cached)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private func awaitTaskFriendlyDelay() throws {
    // Run loop delay inside URLProtocol callback so concurrent prefetch calls overlap.
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
}

private func makePNGData(size: CGSize) throws -> Data {
    #if canImport(UIKit)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let image = renderer.image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
    return try XCTUnwrap(image.pngData())
    #else
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation else {
        throw NSError(domain: "URLSessionMarkdownImageProviderTests", code: 1)
    }
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    #endif
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let response: URLResponse
        let data: Data
    }

    typealias Handler = (URLRequest) throws -> Response

    private static let lock = NSLock()
    nonisolated(unsafe) private(set) static var requestCount: Int = 0
    nonisolated(unsafe) static var handler: Handler?

    static func reset() {
        lock.lock()
        requestCount = 0
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "StubURLProtocol", code: -1))
            return
        }

        do {
            let response = try handler(request)
            client?.urlProtocol(self, didReceive: response.response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
