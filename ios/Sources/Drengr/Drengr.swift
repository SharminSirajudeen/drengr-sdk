import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
/// task; response BODIES are captured for completion-handler, async/await, and
/// delegate-based (iOS 15+) tasks.
public enum Drengr {
    public static let version = "0.2.0"

    private static let lock = NSLock()
    private static var sink: IngestSink?
    private static var tracker: SessionTracker?
    private static var enabled = true
    private static var installed = false
    private static var observers: [NSObjectProtocol] = []

    /// Initialize capture + delivery. Call once at launch. Subsequent calls are ignored.
    ///
    /// Capture is PASSIVE (method-swizzled observation) — the app's own certificate
    /// pinning / auth-challenge delegate runs untouched, and every session is covered
    /// automatically (no per-configuration registration needed).
    ///
    /// - Parameters:
    ///   - maxBodyBytes: cap on captured body size (default 64 KiB).
    ///   - startEnabled: false installs paused (consent gate); call `setEnabled`.
    ///   - behavior: default ON — captures screen_view (viewDidAppear swizzle),
    ///     taps with semantic labels, rage/dead taps, and crashes with zero
    ///     per-screen code; pass `false` to opt out of behavior autocapture.
    ///   - captureWhen: optional per-URL predicate (sampling / allow-listing).
    ///   - redactHeaders: extra header names to mask (lowercased), on top of defaults.
    ///   - vault: E2EE PII vault pin; sealing stays off until the org's signed
    ///     config is fetched and verifies against it (fail-closed).
    public static func start(
        publishableKey: String,
        ingestURL: String,
        appPackage: String,
        maxBodyBytes: Int = 64 * 1024,
        startEnabled: Bool = true,
        behavior: Bool = true,
        captureWhen: ((String) -> Bool)? = nil,
        redactHeaders: Set<String> = [],
        extraContext: [String: Any] = [:],
        vault: VaultOptions? = nil
    ) {
        lock.lock(); defer { lock.unlock() }
        if installed { return }
        guard let url = URL(string: ingestURL) else { return }

        // A persisted opt-out always wins over startEnabled: an opted-out install
        // stays paused across restarts until optIn() is called (GDPR).
        enabled = startEnabled && !isOptedOut()

        let t = SessionTracker()
        tracker = t
        var ctx: [String: Any] = [
            "app_package": appPackage,
            "os": "ios",
            "os_version": osVersion(),
            "device_model": deviceModel(),
            "install_id": installID(),
            "session_id": t.id,
            "sdk_version": version,
        ]
        for (k, v) in extraContext { ctx[k] = v }
        let s = IngestSink(url: url, publishableKey: publishableKey, context: ctx)
        sink = s

        let lowerExtra = Set(redactHeaders.map { $0.lowercased() })
        URLSessionCapture.install(config: URLSessionCapture.Config(
            maxBodyBytes: maxBodyBytes,
            redactHeaderNames: lowerExtra,
            onEvent: { s.addNetwork($0); t.touch() },
            isEnabled: { enabledFlag() },
            shouldCapture: captureGate(ingestHost: url.host, captureWhen)
        ))
        installLifecycleObservers()
        installed = true

        if behavior { installBehaviorCapture(sink: s) }

        if let v = vault {
            VaultActivation.configure(sink: s, options: v, ingestURL: ingestURL,
                                      publishableKey: publishableKey, session: s.delivery)
        }
    }

    /// Behavior autocapture (default ON via start): taps + rage/dead taps,
    /// screen_view, and crash — all through the sink's redacted event path.
    /// Also drains crash events a previous run's signal handler persisted.
    private static func installBehaviorCapture(sink s: IngestSink) {
        #if canImport(UIKit) && !os(watchOS)
        installTapCapture()
        ScreenViewCapture.install(config: ScreenViewCapture.Config(
            onEvent: { ev in
                lock.lock(); let s = sink; let t = tracker; lock.unlock()
                s?.addBehavior(ev); t?.touch()
            },
            isEnabled: { enabledFlag() }
        ))
        #endif
        // The crash closure captures the sink directly: at crash time it must
        // never contend for Drengr's lock (a wedged lock would hang the crash).
        CrashCapture.install(config: CrashCapture.Config(
            onCrash: { ev in
                s.addCrashSync(ev)
                let sem = DispatchSemaphore(value: 0)
                s.forceFlush { sem.signal() }
                _ = sem.wait(timeout: .now() + 2)   // bounded: never turn a crash into a hang
            }
        ))
        CrashCapture.setEnabled(enabled)   // start() holds the lock — read the flag directly
        CrashCapture.drainPending(into: s)
    }

    private static func installTapCapture() {
        #if canImport(UIKit) && !os(watchOS)
        TapCapture.install(config: TapCapture.Config(
            onEvent: { e in
                lock.lock(); let s = sink; let t = tracker; lock.unlock()
                s?.addTap(e); t?.touch()
            },
            onBehavior: { ev in
                lock.lock(); let s = sink; let t = tracker; lock.unlock()
                s?.addBehavior(ev); t?.touch()
            },
            isEnabled: { enabledFlag() }
        ))
        #endif
    }

    /// Deprecated: tap capture is ON BY DEFAULT in `start` (behavior: true).
    /// Kept for source compatibility; still installs when start(behavior: false)
    /// was used.
    @available(*, deprecated, message: "Tap capture is on by default in start(); this call is no longer needed.")
    public static func experimentalSwiftUITapCapture() {
        installTapCapture()
    }

    /// Force-send all queued events now; `completion` fires when the attempt finishes.
    public static func flush(completion: (() -> Void)? = nil) {
        lock.lock(); let s = sink; lock.unlock()
        guard let s = s else { completion?(); return }
        s.forceFlush(completion)
    }

    // --- session lifecycle (foreground rotation check, background touch + flush) ---

    private static func installLifecycleObservers() {
        let nc = NotificationCenter.default
        #if canImport(UIKit)
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                        object: nil, queue: nil) { _ in onForeground() })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                        object: nil, queue: nil) { _ in onBackground() })
        #elseif canImport(AppKit)
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                        object: nil, queue: nil) { _ in onForeground() })
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                        object: nil, queue: nil) { _ in onBackground() })
        #endif
    }

    static func onForeground() {
        lock.lock(); let t = tracker; let s = sink; let en = enabled; lock.unlock()
        guard let t = t else { return }
        if t.isStale() {
            let newId = t.rotate()
            s?.rotateSession(to: newId)   // old queue flushes under the old id first
        } else {
            t.touch()
        }
        // Foreground marker so the backend can subtract backgrounded time from
        // screen dwell (accurate dwell is the make-or-break signal). Mirrors
        // Android onActivityStarted; rides under the new session id after rotation.
        if en { s?.addAppForeground(ScreenState.screen) }
    }

    static func onBackground() {
        lock.lock(); let t = tracker; let s = sink; let en = enabled; lock.unlock()
        t?.touch()
        // Emit BEFORE the flush so the background marker rides the same batch
        // (both hop the sink's serial queue in FIFO order). Mirrors Android
        // onActivityStopped: app_background, then flush.
        if en { s?.addAppBackground(ScreenState.screen) }
        s?.forceFlush()
    }

    /// Never capture requests to our own ingest host (self-capture loop guard);
    /// then apply the app's optional predicate.
    static func captureGate(ingestHost: String?, _ user: ((String) -> Bool)?) -> (String) -> Bool {
        let host = ingestHost?.lowercased()
        return { urlString in
            if let h = host, URL(string: urlString)?.host?.lowercased() == h { return false }
            return user?(urlString) ?? true
        }
    }

    /// Deprecated no-op: capture is now global (swizzled), so custom sessions are
    /// covered automatically. Kept for source compatibility.
    @available(*, deprecated, message: "No longer needed — all sessions are captured automatically.")
    public static func register(on configuration: URLSessionConfiguration) {}

    /// Pause/resume capture (consent gate). Delivery of buffered events continues.
    public static func setEnabled(_ value: Bool) {
        lock.lock(); enabled = value; lock.unlock()
        CrashCapture.setEnabled(value)
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
        lock.lock(); let s = sink; let t = tracker; lock.unlock()
        s?.identify(externalId, traits: traits)
        t?.touch()
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
