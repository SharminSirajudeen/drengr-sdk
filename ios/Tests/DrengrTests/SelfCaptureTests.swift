import XCTest
@testable import Drengr

/// Regression for the self-capture loop: the sink's own ingest POST must emit NO
/// event. Both defenses are proven — the internal session/task marking (belt) and
/// the ingest-host shouldCapture gate (suspenders).
final class SelfCaptureTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        CaptureHub.installOnce()
    }

    private func makeSink(url: String) -> IngestSink {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RecordingURLProtocol.self]
        return IngestSink(
            url: URL(string: url)!,
            publishableKey: "drengr_pk_test",
            context: ["app_package": "test", "install_id": "test"],
            maxBatch: 1,
            session: URLSession(configuration: cfg)
        )
    }

    private func sampleEvent() -> NetworkEvent {
        NetworkEvent(method: "GET", url: "https://api.example.com/x", statusCode: 200,
                     durationMs: 5, requestBodyBytes: 0, responseBodyBytes: 2,
                     requestHeaders: [:], responseHeaders: [:],
                     requestBody: nil, responseBody: nil, errorText: nil,
                     timestampMs: Int64(Date().timeIntervalSince1970 * 1000))
    }

    // An ingest-host POST goes out (delivery works) but the capture layer emits nothing.
    func testIngestPostEmitsNoEvent() {
        RecordingURLProtocol.reset()
        let sink = makeSink(url: "https://ingest.selfcapture.test/functions/v1/ingest")
        sink.addNetwork(sampleEvent())
        XCTAssertNotNil(RecordingURLProtocol.waitForNextBody(timeout: 5), "ingest POST must still be delivered")
        // Give any (buggy) capture emit a beat to land before asserting absence.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(CaptureHub.eventsFor("ingest.selfcapture.test").isEmpty,
                      "the sink's own ingest POST must never be captured")
    }

    // Belt: the shouldCapture gate excludes the configured ingest host, keeps the rest.
    func testCaptureGateExcludesIngestHost() {
        let gate = Drengr.captureGate(ingestHost: "abc.supabase.co", nil)
        XCTAssertFalse(gate("https://abc.supabase.co/functions/v1/ingest"))
        XCTAssertFalse(gate("https://ABC.SUPABASE.CO/other"))
        XCTAssertTrue(gate("https://api.example.com/x"))
    }

    // Belt: the user predicate still applies to non-ingest URLs.
    func testCaptureGateAppliesUserPredicate() {
        let gate = Drengr.captureGate(ingestHost: "abc.supabase.co") { $0.contains("allowed") }
        XCTAssertTrue(gate("https://api.example.com/allowed"))
        XCTAssertFalse(gate("https://api.example.com/blocked"))
        XCTAssertFalse(gate("https://abc.supabase.co/allowed"))
    }
}
