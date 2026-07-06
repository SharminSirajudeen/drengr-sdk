import Foundation

/// Session id lifecycle: reuse across launches inside the idle window, rotate when
/// idle or max age is exceeded. Persists {session_id, started_at, last_activity_at}
/// in UserDefaults (same idiom as install_id). Thread-safe; never throws.
final class SessionTracker {
    static let SESSION_IDLE_MS: Int64 = 1800000
    static let SESSION_MAX_MS: Int64 = 86400000

    private static let idKey = "dev.drengr.session_id"
    private static let startKey = "dev.drengr.session_started_at"
    private static let lastKey = "dev.drengr.session_last_activity_at"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var sessionId: String
    private var startedAt: Int64
    private var lastActivityAt: Int64

    init(defaults: UserDefaults = .standard, now: Int64 = SessionTracker.nowMs()) {
        self.defaults = defaults
        let id = defaults.string(forKey: Self.idKey)
        let started = Int64(defaults.integer(forKey: Self.startKey))
        let last = Int64(defaults.integer(forKey: Self.lastKey))
        if let id = id, started > 0, last > 0,
           now - last < Self.SESSION_IDLE_MS, now - started < Self.SESSION_MAX_MS {
            sessionId = id
            startedAt = started
        } else {
            sessionId = Self.mintId(now)
            startedAt = now
        }
        lastActivityAt = now
        persistLocked()
    }

    var id: String {
        lock.lock(); defer { lock.unlock() }
        return sessionId
    }

    /// Called on every captured event and on background transition.
    func touch(now: Int64 = SessionTracker.nowMs()) {
        lock.lock(); defer { lock.unlock() }
        lastActivityAt = now
        persistLocked()
    }

    /// True when the idle gap or the session age has expired.
    func isStale(now: Int64 = SessionTracker.nowMs()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return now - lastActivityAt > Self.SESSION_IDLE_MS || now - startedAt > Self.SESSION_MAX_MS
    }

    /// Mint + persist a fresh session id; caller flushes the old queue first.
    func rotate(now: Int64 = SessionTracker.nowMs()) -> String {
        lock.lock(); defer { lock.unlock() }
        sessionId = Self.mintId(now)
        startedAt = now
        lastActivityAt = now
        persistLocked()
        return sessionId
    }

    private func persistLocked() {
        defaults.set(sessionId, forKey: Self.idKey)
        defaults.set(Int(startedAt), forKey: Self.startKey)
        defaults.set(Int(lastActivityAt), forKey: Self.lastKey)
    }

    private static func mintId(_ now: Int64) -> String { "s-\(now)" }
    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
