import XCTest
@testable import Drengr

final class URLSessionCaptureTests: XCTestCase {

    static var events: [NetworkEvent] = []
    private static let lock = NSLock()

    static func record(_ e: NetworkEvent) { lock.lock(); events.append(e); lock.unlock() }
    static func eventsFor(_ path: String) -> [NetworkEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.url.contains(path) }
    }

    override class func setUp() {
        super.setUp()
        URLSessionCapture.install(config: URLSessionCapture.Config(
            maxBodyBytes: 64 * 1024,
            redactHeaderNames: [],
            onEvent: { record($0) },
            isEnabled: { true },
            shouldCapture: { _ in true }
        ))
    }

    private func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    func testCompletionHandlerCapturesBody() {
        let url = URL(string: "https://example.test/completion")!
        let done = expectation(description: "completion")
        session().dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        let ev = pollFor("/completion")
        XCTAssertNotNil(ev, "completion-handler task must emit an event")
        XCTAssertEqual(ev?.statusCode, 200)
        XCTAssertEqual(ev?.method, "GET")
        XCTAssertNotNil(ev?.responseBody, "completion-handler task must capture the body")
        XCTAssertTrue(ev?.responseBody?.contains("amount") ?? false, "body content present: \(ev?.responseBody ?? "nil")")
    }

    func testAsyncAwaitCapturesMetadata() async throws {
        let url = URL(string: "https://example.test/asyncawait")!
        _ = try await session().data(from: url)
        let ev = await pollForAsync("/asyncawait")
        XCTAssertNotNil(ev, "async/await task must emit a (metadata) event")
        XCTAssertEqual(ev?.statusCode, 200)
        XCTAssertNil(ev?.responseBody, "async/await body is not captured passively (metadata-only)")
    }

    private func pollForAsync(_ path: String) async -> NetworkEvent? {
        for _ in 0..<50 {
            if let e = Self.eventsFor(path).first { return e }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return Self.eventsFor(path).first
    }

    func testDelegateTaskCapturesMetadata() {
        let url = URL(string: "https://example.test/delegate")!
        let delegate = NoopDelegate()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let s = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        s.dataTask(with: url).resume()
        let ev = pollFor("/delegate")
        XCTAssertNotNil(ev, "delegate-based task must emit a (metadata) event")
        XCTAssertEqual(ev?.statusCode, 200)
    }

    private func pollFor(_ path: String) -> NetworkEvent? {
        for _ in 0..<50 {
            if let e = Self.eventsFor(path).first { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return Self.eventsFor(path).first
    }
}

final class MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Data(#"{"amount":42.5,"status":"ok"}"#.utf8)
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class NoopDelegate: NSObject, URLSessionDataDelegate {}
