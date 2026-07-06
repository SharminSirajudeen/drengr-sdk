import XCTest
@testable import Drengr

/// Delegate-stack body capture (the forwarding proxy): the app's own delegate must
/// receive every callback it implements, unchanged, AND the body must be teed into
/// the captured event. Completion-handler behavior stays untouched.
@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
final class BodyCaptureTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        CaptureHub.installOnce()
    }

    private func session(delegate: URLSessionDelegate?) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    private func pollFor(_ path: String) -> NetworkEvent? {
        for _ in 0..<50 {
            if let e = CaptureHub.eventsFor(path).first { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return CaptureHub.eventsFor(path).first
    }

    final class RecordingDelegate: NSObject, URLSessionDataDelegate {
        let done: XCTestExpectation?
        var gotResponse = false
        var receivedBytes = 0
        var completed = false
        init(_ e: XCTestExpectation? = nil) { done = e }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            gotResponse = true
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            receivedBytes += data.count
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            completed = true
            done?.fulfill()
        }
    }

    // Session-delegate task (Alamofire shape): delegate gets ALL callbacks + body captured.
    func testDelegateSessionKeepsCallbacksAndCapturesBody() {
        let done = expectation(description: "delegate completed")
        let delegate = RecordingDelegate(done)
        let s = session(delegate: delegate)
        s.dataTask(with: URL(string: "https://example.test/proxybody")!).resume()
        wait(for: [done], timeout: 5)

        XCTAssertTrue(delegate.gotResponse, "app delegate still gets didReceive response")
        XCTAssertEqual(delegate.receivedBytes, 29, "app delegate still gets every data chunk")
        XCTAssertTrue(delegate.completed, "app delegate still gets didComplete")

        let ev = pollFor("/proxybody")
        XCTAssertNotNil(ev, "delegate-based task must emit an event")
        XCTAssertEqual(ev?.statusCode, 200)
        XCTAssertTrue(ev?.responseBody?.contains("amount") ?? false,
                      "delegate-path body captured: \(ev?.responseBody ?? "nil")")
        XCTAssertEqual(CaptureHub.eventsFor("/proxybody").count, 1, "exactly one event per task")
    }

    // data(for:delegate:) — the platform itself never routes data-delivery callbacks
    // to a per-task delegate on async tasks (baseline-verified, no swizzles); the
    // proxy must not change that, the app's data stays intact, and the body is
    // still captured via the async completion wrap (layer A2).
    func testPerTaskDelegateAsyncBodyCaptured() async throws {
        let delegate = RecordingDelegate()
        let (data, _) = try await session(delegate: nil)
            .data(for: URLRequest(url: URL(string: "https://example.test/taskdelegate")!), delegate: delegate)
        XCTAssertEqual(data.count, 29, "the app still receives the full body")

        var ev: NetworkEvent?
        for _ in 0..<50 {
            if let e = CaptureHub.eventsFor("/taskdelegate").first { ev = e; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(ev)
        XCTAssertTrue(ev?.responseBody?.contains("amount") ?? false)
        XCTAssertEqual(CaptureHub.eventsFor("/taskdelegate").count, 1, "exactly one event per task")
    }

    // Bodies over maxBodyBytes are dropped whole (metadata still exact) — the cap holds.
    func testDelegateBodyOverCapIsDropped() {
        let done = expectation(description: "delegate completed")
        let delegate = RecordingDelegate(done)
        let s = session(delegate: delegate)
        s.dataTask(with: URL(string: "https://example.test/bigbody")!).resume()
        wait(for: [done], timeout: 5)
        let ev = pollFor("/bigbody")
        XCTAssertNotNil(ev)
        XCTAssertNil(ev?.responseBody, "body over the cap must not ship")
        XCTAssertEqual(delegate.receivedBytes, 80_000, "the app still receives the full oversized body")
    }
}
