import XCTest
@testable import Drengr

/// Session rotation spec: SESSION_IDLE_MS/SESSION_MAX_MS windows, persistence,
/// reuse-on-launch, rotate-flushes-old-queue-first, and forced flush.
final class SessionTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "dev.drengr.tests.session"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        RecordingURLProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testConstants() {
        XCTAssertEqual(SessionTracker.SESSION_IDLE_MS, 1_800_000)
        XCTAssertEqual(SessionTracker.SESSION_MAX_MS, 86_400_000)
    }

    func testLaunchReusesWithinIdleWindow() {
        let t0: Int64 = 1_000_000_000_000
        let a = SessionTracker(defaults: defaults, now: t0)
        let id = a.id
        let b = SessionTracker(defaults: defaults, now: t0 + SessionTracker.SESSION_IDLE_MS - 1)
        XCTAssertEqual(b.id, id, "persisted session reused inside the idle window")
    }

    func testLaunchMintsAfterIdleWindow() {
        let t0: Int64 = 1_000_000_000_000
        let a = SessionTracker(defaults: defaults, now: t0)
        let id = a.id
        let b = SessionTracker(defaults: defaults, now: t0 + SessionTracker.SESSION_IDLE_MS + 1)
        XCTAssertNotEqual(b.id, id, "idle gap over SESSION_IDLE_MS mints a new session")
    }

    func testLaunchMintsAfterMaxAgeDespiteActivity() {
        let t0: Int64 = 1_000_000_000_000
        let a = SessionTracker(defaults: defaults, now: t0)
        let id = a.id
        let almostMax = t0 + SessionTracker.SESSION_MAX_MS - 1
        a.touch(now: almostMax)
        let b = SessionTracker(defaults: defaults, now: t0 + SessionTracker.SESSION_MAX_MS + 1)
        XCTAssertNotEqual(b.id, id, "session older than SESSION_MAX_MS mints a new one")
    }

    func testStaleAndRotate() {
        let t0: Int64 = 1_000_000_000_000
        let t = SessionTracker(defaults: defaults, now: t0)
        XCTAssertFalse(t.isStale(now: t0 + 1000))
        XCTAssertTrue(t.isStale(now: t0 + SessionTracker.SESSION_IDLE_MS + 1))
        let old = t.id
        let fresh = t.rotate(now: t0 + SessionTracker.SESSION_IDLE_MS + 1)
        XCTAssertNotEqual(fresh, old)
        XCTAssertEqual(t.id, fresh)
        XCTAssertFalse(t.isStale(now: t0 + SessionTracker.SESSION_IDLE_MS + 2))
    }

    func testTouchExtendsIdleWindow() {
        let t0: Int64 = 1_000_000_000_000
        let t = SessionTracker(defaults: defaults, now: t0)
        let mid = t0 + SessionTracker.SESSION_IDLE_MS - 1
        t.touch(now: mid)
        XCTAssertFalse(t.isStale(now: mid + SessionTracker.SESSION_IDLE_MS - 1))
    }

    // --- sink integration ---

    private func makeSink(maxBatch: Int = 1, sessionId: String) -> IngestSink {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RecordingURLProtocol.self]
        return IngestSink(
            url: URL(string: "https://ingest.test/functions/v1/ingest")!,
            publishableKey: "drengr_pk_test",
            context: ["app_package": "test", "install_id": "test", "session_id": sessionId],
            maxBatch: maxBatch,
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

    private func awaitEnvelope() -> [String: Any]? {
        guard let data = RecordingURLProtocol.waitForNextBody(timeout: 5) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func testRotateFlushesPendingUnderOldSessionThenSwitches() {
        // High batch + long interval: the event stays queued until rotation flushes it.
        let sink = makeSink(maxBatch: 100, sessionId: "s-old")
        sink.addNetwork(sampleEvent())
        sink.rotateSession(to: "s-new")
        guard let oldEnvelope = awaitEnvelope() else { return XCTFail("no flush on rotation") }
        XCTAssertEqual(oldEnvelope["session_id"] as? String, "s-old", "pending queue ships under the OLD session")

        sink.addNetwork(sampleEvent())
        sink.forceFlush()
        guard let newEnvelope = awaitEnvelope() else { return XCTFail("no flush after rotation") }
        XCTAssertEqual(newEnvelope["session_id"] as? String, "s-new", "post-rotation events ship under the NEW session")
    }

    func testForceFlushSendsImmediatelyAndCallsCompletion() {
        let sink = makeSink(maxBatch: 100, sessionId: "s-1")
        sink.addNetwork(sampleEvent())
        let done = expectation(description: "flush completion")
        sink.forceFlush { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(RecordingURLProtocol.waitForNextBody(timeout: 1), "queue was force-sent")
    }

    func testForceFlushOnEmptyQueueStillCompletes() {
        let sink = makeSink(sessionId: "s-1")
        let done = expectation(description: "flush completion")
        sink.forceFlush { done.fulfill() }
        wait(for: [done], timeout: 5)
    }
}
