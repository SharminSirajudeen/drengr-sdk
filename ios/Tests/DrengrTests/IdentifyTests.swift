import XCTest
@testable import Drengr

final class IdentifyTests: XCTestCase {

    private func makeSink(maxBatch: Int = 1) -> IngestSink {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: cfg)
        return IngestSink(
            url: URL(string: "https://ingest.test/functions/v1/ingest")!,
            publishableKey: "drengr_pk_test",
            context: ["app_package": "test", "install_id": "test"],
            maxBatch: maxBatch,
            session: session
        )
    }

    override func setUp() {
        super.setUp()
        RecordingURLProtocol.reset()
    }

    private func awaitEnvelope() -> [String: Any]? {
        guard let data = RecordingURLProtocol.waitForNextBody(timeout: 5) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func sampleEvent() -> NetworkEvent {
        NetworkEvent(method: "GET", url: "https://api.example.com/x", statusCode: 200,
                     durationMs: 5, requestBodyBytes: 0, responseBodyBytes: 2,
                     requestHeaders: [:], responseHeaders: [:],
                     requestBody: nil, responseBody: nil, errorText: nil,
                     timestampMs: Int64(Date().timeIntervalSince1970 * 1000))
    }

    func testIdentifyEmitsEventAndAttachesExternalId() {
        let sink = makeSink()
        sink.identify("user_123", traits: ["email": "a@b.com", "plan": "pro"])
        guard let envelope = awaitEnvelope() else { return XCTFail("no request received") }
        XCTAssertEqual(envelope["external_id"] as? String, "user_123")

        let events = envelope["events"] as? [[String: Any]] ?? []
        let identifyEv = events.first { ($0["kind"] as? String) == "identify" }
        XCTAssertNotNil(identifyEv, "an identify event was emitted")
        XCTAssertEqual(identifyEv?["external_id"] as? String, "user_123")
        let dump = "\(identifyEv ?? [:])"
        XCTAssertFalse(dump.contains("a@b.com"), "raw email must not appear")
        XCTAssertTrue(dump.contains("pro"), "non-PII trait survives redaction")
    }

    func testEmptyExternalIdIsNoOp() {
        let sink = makeSink()
        sink.identify("", traits: ["email": "a@b.com"])
        XCTAssertNil(RecordingURLProtocol.waitForNextBody(timeout: 0.3), "no request sent for an empty externalId")
    }

    func testExternalIdAttachesToASubsequentEvent() {
        let sink = makeSink()
        sink.identify("user_456")
        _ = awaitEnvelope()
        sink.addNetwork(sampleEvent())
        guard let envelope = awaitEnvelope() else { return XCTFail("no request received") }
        XCTAssertEqual(envelope["external_id"] as? String, "user_456")
    }

    func testSetExperimentAttachesAndClears() {
        let sink = makeSink()
        sink.setExperiment("checkout_flow", variant: "variant_b")
        sink.addNetwork(sampleEvent())
        guard let envelope = awaitEnvelope() else { return XCTFail("no request received") }
        let experiments = envelope["experiments"] as? [String: String]
        XCTAssertEqual(experiments?["checkout_flow"], "variant_b")

        sink.setExperiment("checkout_flow", variant: nil)
        sink.addNetwork(sampleEvent())
        guard let cleared = awaitEnvelope() else { return XCTFail("no request received") }
        XCTAssertNil(cleared["experiments"], "experiments omitted once empty")
    }

    func testSetExperimentBadInputIsNoOp() {
        let sink = makeSink()
        sink.setExperiment("", variant: "x")
        sink.addNetwork(sampleEvent())
        guard let envelope = awaitEnvelope() else { return XCTFail("no request received") }
        XCTAssertNil(envelope["experiments"])
    }
}

final class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var bodies: [Data] = []
    private static var waiters: [XCTestExpectation] = []

    static func reset() {
        lock.lock(); bodies = []; waiters = []; lock.unlock()
    }

    private static func record(_ data: Data) {
        lock.lock()
        bodies.append(data)
        let toFulfill = waiters
        waiters = []
        lock.unlock()
        toFulfill.forEach { $0.fulfill() }
    }

    static func waitForNextBody(timeout: TimeInterval) -> Data? {
        lock.lock()
        if let first = bodies.first {
            bodies.removeFirst()
            lock.unlock()
            return first
        }
        let exp = XCTestExpectation(description: "request body")
        waiters.append(exp)
        lock.unlock()
        _ = XCTWaiter.wait(for: [exp], timeout: timeout)
        lock.lock(); defer { lock.unlock() }
        return bodies.isEmpty ? nil : bodies.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            var out = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                out.append(buf, count: n)
            }
            stream.close()
            data = out
        }
        RecordingURLProtocol.record(data ?? Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
