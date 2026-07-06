import XCTest
@testable import Drengr

/// Envelope spec for req_headers/resp_headers: already-redacted maps ship as JSON
/// objects, capped at 48 entries; if the serialized map exceeds 8192 bytes, {} ships.
final class HeadersEnvelopeTests: XCTestCase {

    private func makeSink() -> IngestSink {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RecordingURLProtocol.self]
        return IngestSink(
            url: URL(string: "https://ingest.test/functions/v1/ingest")!,
            publishableKey: "drengr_pk_test",
            context: ["app_package": "test", "install_id": "test"],
            maxBatch: 1,
            session: URLSession(configuration: cfg)
        )
    }

    override func setUp() {
        super.setUp()
        RecordingURLProtocol.reset()
    }

    private func netEvent(reqHeaders: [String: String], respHeaders: [String: String]) -> NetworkEvent {
        NetworkEvent(method: "GET", url: "https://api.example.com/x", statusCode: 200,
                     durationMs: 5, requestBodyBytes: 0, responseBodyBytes: 2,
                     requestHeaders: reqHeaders, responseHeaders: respHeaders,
                     requestBody: nil, responseBody: nil, errorText: nil,
                     timestampMs: Int64(Date().timeIntervalSince1970 * 1000))
    }

    private func firstNetEvent() -> [String: Any]? {
        guard let data = RecordingURLProtocol.waitForNextBody(timeout: 5),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = envelope["events"] as? [[String: Any]] else { return nil }
        return events.first { ($0["kind"] as? String) == "net" }
    }

    func testHeadersShipAsSnakeCaseMaps() {
        let sink = makeSink()
        sink.addNetwork(netEvent(reqHeaders: ["Accept": "application/json", "Authorization": "[REDACTED]"],
                                 respHeaders: ["Content-Type": "application/json"]))
        guard let ev = firstNetEvent() else { return XCTFail("no net event received") }
        let req = ev["req_headers"] as? [String: String]
        let resp = ev["resp_headers"] as? [String: String]
        XCTAssertEqual(req?["Accept"], "application/json")
        XCTAssertEqual(req?["Authorization"], "[REDACTED]")
        XCTAssertEqual(resp?["Content-Type"], "application/json")
    }

    func testHeadersCappedAt48Entries() {
        let sink = makeSink()
        var many = [String: String]()
        for i in 0..<60 { many["h\(i)"] = "v" }
        sink.addNetwork(netEvent(reqHeaders: many, respHeaders: [:]))
        guard let ev = firstNetEvent() else { return XCTFail("no net event received") }
        XCTAssertEqual((ev["req_headers"] as? [String: String])?.count, 48)
        XCTAssertEqual((ev["resp_headers"] as? [String: String])?.count, 0)
    }

    func testOversizedHeadersShipEmpty() {
        let sink = makeSink()
        let big = ["x-big": String(repeating: "a", count: 9000)]
        sink.addNetwork(netEvent(reqHeaders: big, respHeaders: ["ok": "small"]))
        guard let ev = firstNetEvent() else { return XCTFail("no net event received") }
        XCTAssertEqual((ev["req_headers"] as? [String: String])?.count, 0, "over 8192 bytes → {}")
        XCTAssertEqual((ev["resp_headers"] as? [String: String])?["ok"], "small")
    }
}
