import Foundation

/// Zero-code network analytics for iOS.
///
///     Drengr.start(
///         publishableKey: "drengr_pk_…",                                   // from drengr.dev/pro
///         ingestURL: "https://<ref>.supabase.co/functions/v1/ingest",
///         appPackage: "com.example.app"
///     )
///
/// One call installs PASSIVE capture (method-swizzled observation — see
/// `URLSessionCapture`) of every `URLSession` exchange across all sessions
/// (`.shared`, `.default`, custom configs, Alamofire, async/await). Because it
/// only observes — never re-issues — the app's certificate pinning / auth-challenge
/// delegate runs completely untouched. Redaction is on by default; the sink's own
/// delivery uses a separate session it never observes, so it can't self-capture.
///
/// Coverage: metadata (method/url/status/timing/bytes/error) is exact for every
/// task; response BODIES are captured for completion-handler tasks (delegate-based
/// and async/await tasks are metadata-only passively).
public enum Drengr {
    public static let version = "0.1.0"

    private static let lock = NSLock()
    private static var sink: IngestSink?
    private static var enabled = true
    private static var installed = false

    /// Initialize capture + delivery. Call once at launch. Subsequent calls are ignored.
    ///
    /// Capture is PASSIVE (method-swizzled observation) — the app's own certificate
    /// pinning / auth-challenge delegate runs untouched, and every session is covered
    /// automatically (no per-configuration registration needed).
    ///
    /// - Parameters:
    ///   - maxBodyBytes: cap on captured body size (default 64 KiB).
    ///   - startEnabled: false installs paused (consent gate); call `setEnabled`.
    ///   - captureWhen: optional per-URL predicate (sampling / allow-listing).
    ///   - redactHeaders: extra header names to mask (lowercased), on top of defaults.
    public static func start(
        publishableKey: String,
        ingestURL: String,
        appPackage: String,
        maxBodyBytes: Int = 64 * 1024,
        startEnabled: Bool = true,
        captureWhen: ((String) -> Bool)? = nil,
        redactHeaders: Set<String> = [],
        extraContext: [String: Any] = [:]
    ) {
        lock.lock(); defer { lock.unlock() }
        if installed { return }
        guard let url = URL(string: ingestURL) else { return }

        // A persisted opt-out always wins over startEnabled: an opted-out install
        // stays paused across restarts until optIn() is called (GDPR).
        enabled = startEnabled && !isOptedOut()

        var ctx: [String: Any] = [
            "app_package": appPackage,
            "os": "ios",
            "os_version": osVersion(),
            "device_model": deviceModel(),
            "install_id": installID(),
            "session_id": "s-\(Int64(Date().timeIntervalSince1970 * 1000))",
            "sdk_version": version,
        ]
        for (k, v) in extraContext { ctx[k] = v }
        let s = IngestSink(url: url, publishableKey: publishableKey, context: ctx)
        sink = s

        let lowerExtra = Set(redactHeaders.map { $0.lowercased() })
        URLSessionCapture.install(config: URLSessionCapture.Config(
            maxBodyBytes: maxBodyBytes,
            redactHeaderNames: lowerExtra,
            onEvent: { s.addNetwork($0) },
            isEnabled: { enabledFlag() },
            shouldCapture: { url in captureWhen?(url) ?? true }
        ))
        installed = true
    }

    /// Deprecated no-op: capture is now global (swizzled), so custom sessions are
    /// covered automatically. Kept for source compatibility.
    @available(*, deprecated, message: "No longer needed — all sessions are captured automatically.")
    public static func register(on configuration: URLSessionConfiguration) {}

    /// Pause/resume capture (consent gate). Delivery of buffered events continues.
    public static func setEnabled(_ value: Bool) {
        lock.lock(); enabled = value; lock.unlock()
    }

    /// Persistently opt this install OUT of capture (GDPR). Unlike setEnabled(false),
    /// this survives app restarts — start() reads it and stays paused next launch.
    public static func optOut() {
        UserDefaults.standard.set(true, forKey: optOutKey)
        setEnabled(false)
    }

    /// Reverse optOut(): clear the persisted flag and resume capture.
    public static func optIn() {
        UserDefaults.standard.removeObject(forKey: optOutKey)
        setEnabled(true)
    }

    /// Sets external_id — your own stable, non-PII user id (not an email) — on
    /// the session and all events hereafter; emits one identify event. `traits`
    /// are redacted before delivery. Fail-open: no-op if `start` hasn't run yet
    /// or `externalId` is empty.
    public static func identify(_ externalId: String, traits: [String: Any] = [:]) {
        lock.lock(); let s = sink; lock.unlock()
        s?.identify(externalId, traits: traits)
    }

    /// Tags the session with an experiment variant, attached to all events
    /// hereafter as `experiments`. A nil/empty `variant` clears `key`.
    public static func setExperiment(_ key: String, variant: String?) {
        lock.lock(); let s = sink; lock.unlock()
        s?.setExperiment(key, variant: variant)
    }

    private static func enabledFlag() -> Bool {
        lock.lock(); defer { lock.unlock() }; return enabled
    }

    // --- persisted opt-out (mirrors install id) ---
    private static let optOutKey = "dev.drengr.opt_out"
    private static func isOptedOut() -> Bool { UserDefaults.standard.bool(forKey: optOutKey) }

    // --- install id (persisted in UserDefaults) ---
    private static let installKey = "dev.drengr.install_id"
    private static func installID() -> String {
        let d = UserDefaults.standard
        if let existing = d.string(forKey: installKey) { return existing }
        let id = UUID().uuidString
        d.set(id, forKey: installKey)
        return id
    }

    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func deviceModel() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }
}
