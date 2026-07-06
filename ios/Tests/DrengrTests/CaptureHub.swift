import Foundation
@testable import Drengr

/// Shared one-shot installer for the process-global swizzle capture. Test classes
/// filter the shared event log by unique URL path; `shouldCapture` is mutable so
/// individual tests can exercise gating.
enum CaptureHub {
    private static let lock = NSLock()
    private static var events: [NetworkEvent] = []
    private static var gate: (String) -> Bool = { _ in true }
    private static var installedOnce = false

    static func installOnce() {
        lock.lock(); defer { lock.unlock() }
        if installedOnce { return }
        installedOnce = true
        URLSessionCapture.install(config: URLSessionCapture.Config(
            maxBodyBytes: 64 * 1024,
            redactHeaderNames: [],
            onEvent: { record($0) },
            isEnabled: { true },
            shouldCapture: { url in shouldCapture(url) }
        ))
    }

    static var shouldCapture: (String) -> Bool {
        get { lock.lock(); defer { lock.unlock() }; return gate }
        set { lock.lock(); gate = newValue; lock.unlock() }
    }

    static func record(_ e: NetworkEvent) { lock.lock(); events.append(e); lock.unlock() }
    static func eventsFor(_ path: String) -> [NetworkEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.url.contains(path) }
    }
}
