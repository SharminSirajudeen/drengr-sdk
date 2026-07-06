import XCTest
@testable import Drengr

/// Runtime proof for the passive swizzle capture (task #22). A MockURLProtocol
/// supplies canned responses so this is hermetic (no network/server): it asserts
/// the swizzles actually FIRE, don't crash, and honor the coverage contract —
/// completion-handler tasks get bodies; async/await + delegate tasks get metadata.
///
/// NOTE: swizzling is process-global + irreversible, so install happens ONCE in
/// class setUp and every test filters the shared event log by a unique URL path.
final class URLSessionCaptureTests: XCTestCase {

    static func eventsFor(_ path: String) -> [NetworkEvent] { CaptureHub.eventsFor(path) }

    override class func setUp() {
        super.setUp()
        CaptureHub.installOnce()
    }

    private func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    // Layer A: completion-handler task must capture the response BODY + metadata.
    func testCompletionHandlerCapturesBody() {
        let url = URL(string: "https://example.test/completion")!
        let done = expectation(description: "completion")
        session().dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        // give the emit (same call path) a beat
        let ev = pollFor("/completion")
        XCTAssertNotNil(ev, "completion-handler task must emit an event")
        XCTAssertEqual(ev?.statusCode, 200)
        XCTAssertEqual(ev?.method, "GET")
        XCTAssertNotNil(ev?.responseBody, "completion-handler task must capture the body")
        XCTAssertTrue(ev?.responseBody?.contains("amount") ?? false, "body content present: \(ev?.responseBody ?? "nil")")
    }

    // Layer A2: async/await task — metadata AND body captured (private-selector wrap).
    func testAsyncAwaitCapturesBody() async throws {
        let url = URL(string: "https://example.test/asyncawait")!
        let (data, _) = try await session().data(from: url)
        XCTAssertEqual(data.count, 29, "the app still receives the full body")
        // The emit lands a few ms after data(from:) returns; poll with Task.sleep —
        // RunLoop-spin is a no-op on the Swift Concurrency pool this test runs on.
        let ev = await pollForAsync("/asyncawait")
        XCTAssertNotNil(ev, "async/await task must emit an event")
        XCTAssertEqual(ev?.statusCode, 200)
        XCTAssertTrue(ev?.responseBody?.contains("amount") ?? false,
                      "async/await body captured: \(ev?.responseBody ?? "nil")")
        XCTAssertEqual(Self.eventsFor("/asyncawait").count, 1, "exactly one event per task (no double-emit)")
    }

    // data(for:) with an explicit URLRequest — the request-variant private selector.
    func testAsyncAwaitRequestVariantCapturesBody() async throws {
        let url = URL(string: "https://example.test/asyncreq")!
        _ = try await session().data(for: URLRequest(url: url))
        let ev = await pollForAsync("/asyncreq")
        XCTAssertNotNil(ev)
        XCTAssertTrue(ev?.responseBody?.contains("amount") ?? false)
    }

    private func pollForAsync(_ path: String) async -> NetworkEvent? {
        for _ in 0..<50 {
            if let e = Self.eventsFor(path).first { return e }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return Self.eventsFor(path).first
    }

    // Layer B: delegate-based task (no completion handler) — metadata captured.
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

    // Poll the shared log briefly (emit happens on the session's delegate queue).
    private func pollFor(_ path: String) -> NetworkEvent? {
        for _ in 0..<50 {
            if let e = Self.eventsFor(path).first { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return Self.eventsFor(path).first
    }
}

/// Returns a fixed 200 + JSON body for any request — drives URLSession's real
/// completion/delegate machinery (which the swizzles observe) without a server.
final class MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let big = request.url?.path.contains("bigbody") ?? false
        let body = big ? Data(repeating: UInt8(ascii: "a"), count: 80_000)
                       : Data(#"{"amount":42.5,"status":"ok"}"#.utf8)
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class NoopDelegate: NSObject, URLSessionDataDelegate {}
