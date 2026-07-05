import Foundation

public enum Drengr {
    public static let version = "0.1.0"

    private static let lock = NSLock()
    private static var sink: IngestSink?
    private static var enabled = true
    private static var installed = false

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

    @available(*, deprecated, message: "No longer needed — all sessions are captured automatically.")
    public static func register(on configuration: URLSessionConfiguration) {}

    public static func setEnabled(_ value: Bool) {
        lock.lock(); enabled = value; lock.unlock()
    }

    public static func optOut() {
        UserDefaults.standard.set(true, forKey: optOutKey)
        setEnabled(false)
    }

    public static func optIn() {
        UserDefaults.standard.removeObject(forKey: optOutKey)
        setEnabled(true)
    }

    public static func identify(_ externalId: String, traits: [String: Any] = [:]) {
        lock.lock(); let s = sink; lock.unlock()
        s?.identify(externalId, traits: traits)
    }

    public static func setExperiment(_ key: String, variant: String?) {
        lock.lock(); let s = sink; lock.unlock()
        s?.setExperiment(key, variant: variant)
    }

    private static func enabledFlag() -> Bool {
        lock.lock(); defer { lock.unlock() }; return enabled
    }

    private static let optOutKey = "dev.drengr.opt_out"
    private static func isOptedOut() -> Bool { UserDefaults.standard.bool(forKey: optOutKey) }

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
