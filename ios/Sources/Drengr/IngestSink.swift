import Foundation
import CryptoKit

/// Batches captured signals and ships them to the Drengr ingest endpoint,
/// authenticated by a publishable key. Port of the proven Dart/JS/Kotlin
/// IngestSink, carrying every device-run lesson from birth:
///  - delivery uses a URLSession with NO Drengr protocol, so the sink can never
///    capture its own POSTs (the self-capture loop can't exist);
///  - a serial DispatchQueue is the whole concurrency model — enqueue, flush,
///    persist all run on it, so the queue needs no locks and no write can overlap
///    another (no starvation loop);
///  - the envelope carries sent_at_ms for server-side clock-skew correction.
///
/// Best-effort and non-blocking: never throws into the app, drops oldest on
/// overflow, retries with exponential backoff + full jitter, persists the queue
/// to a JSONL file in Application Support so an app kill doesn't lose events.
final class IngestSink {
    private let url: URL
    private let publishableKey: String
    private var context: [String: Any]   // mutated only on `queue` (session rotation)
    private let maxBatch: Int
    private let maxQueue: Int
    private let flushInterval: TimeInterval

    private let queue = DispatchQueue(label: "dev.drengr.sink")
    private var events: [[String: Any]] = []
    private var flushScheduled = false
    private var retries = 0
    private let fileURL: URL

    // Session-scoped identity/experiment state, merged into every envelope (see
    // flush()). Mutated only on `queue`, same as `events`.
    private var externalId: String?
    private var experimentsMap: [String: String] = [:]

    // On-device sealing config. nil = fail-closed: PII ships as typed placeholders,
    // never raw. Mutated/read only on `queue`.
    private var vault: VaultConfig?

    // Delivery session WITHOUT the Drengr protocol → invisible to capture.
    let delivery: URLSession

    init(url: URL, publishableKey: String, context: [String: Any],
         maxBatch: Int = 50, maxQueue: Int = 500, flushInterval: TimeInterval = 10,
         session: URLSession? = nil) {
        self.url = url
        self.publishableKey = publishableKey
        self.context = context
        self.maxBatch = maxBatch
        self.maxQueue = maxQueue
        self.flushInterval = flushInterval
        self.delivery = session ?? {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 30
            return URLSession(configuration: cfg)
        }()
        URLSessionCapture.markInternal(self.delivery)
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        self.fileURL = dir.appendingPathComponent("drengr_queue.jsonl")
        queue.async { [weak self] in self?.restore() }
    }

    func addNetwork(_ e: NetworkEvent) {
        let (ev, pii) = toNet(e)
        queue.async { [weak self] in self?.ingest(ev, pii: pii) }
    }

    /// Activate (or clear) on-device sealing after the org's signed config verifies.
    /// Until set, the sink is fail-closed: PII ships as placeholders, never raw.
    func setVault(_ v: VaultConfig?) {
        queue.async { [weak self] in self?.vault = v }
    }

    // Seal captured PII into the event when a vault is set, else fail-closed. Mirrors
    // the JS sealAndEnqueue: attach subject_hash + the HPKE envelope as `pii`.
    private func ingest(_ event: [String: Any], pii: [String: String]) {
        var event = event
        if let v = vault, !pii.isEmpty { sealInto(&event, pii: pii, vault: v) }
        enqueue(event)
    }

    private func sealInto(_ event: inout [String: Any], pii: [String: String], vault: VaultConfig) {
        let sh = externalId.map { Identity.subjectHash(pepper: vault.orgPepper, externalId: $0) } ?? ""
        if !sh.isEmpty { event["subject_hash"] = sh }
        let bh = sha256hex((event["req_body"] as? String ?? "") + "|" + (event["body"] as? String ?? ""))
        guard #available(iOS 17, macOS 14, tvOS 17, *) else { return }
        let ctx = SealContext(subjectHash: sh, sealUlid: event["event_id"] as? String ?? "",
                              bodyHash: bh, tenantId: vault.tenantId)
        if let env = Seal.sealPii(pii, ctx: ctx, orgPubKey: vault.orgPubKey, kid: vault.kid) {
            event["pii"] = ["pii_alg": env.pii_alg, "kid": env.kid, "enc": env.enc, "ct": env.ct]
        }
    }

    private func sha256hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Enqueue an already-redacted semantic tap (kind "tap" — ingest-allowlisted).
    func addTap(_ e: TapEvent) {
        var o: [String: Any] = [
            "kind": "tap",
            "event_id": randomID(),
            "ts_ms": e.timestampMs,
            "screen": e.screen,
            "label": e.label ?? "",
            "label_source": e.labelSource,
            "role": e.role,
            "element_class": e.elementClass,
            "x": e.x,
            "y": e.y,
        ]
        if let v = e.value { o["value"] = v }
        queue.async { [weak self] in self?.enqueue(o) }
    }

    /// Enqueue a pre-built behavior event (screen_view / rage_tap / dead_tap /
    /// crash — already redacted by the capture layer). Fills event_id/ts_ms
    /// when absent, mirroring the Flutter sink. Fail-open.
    func addBehavior(_ ev: [String: Any]) {
        var o = ev
        if o["event_id"] == nil { o["event_id"] = randomID() }
        if o["ts_ms"] == nil { o["ts_ms"] = Int64(Date().timeIntervalSince1970 * 1000) }
        queue.async { [weak self] in self?.enqueue(o) }
    }

    /// app_foreground: process entered the foreground on `screen`. Lets the
    /// backend subtract backgrounded gaps when computing true screen dwell.
    /// Mirrors Android `IngestSink.addAppForeground`.
    func addAppForeground(_ screen: String) { addLifecycle("app_foreground", screen: screen) }

    /// app_background: process left the foreground on `screen`.
    func addAppBackground(_ screen: String) { addLifecycle("app_background", screen: screen) }

    private func addLifecycle(_ kind: String, screen: String) {
        var o: [String: Any] = [
            "kind": kind,
            "event_id": randomID(),
            "ts_ms": Int64(Date().timeIntervalSince1970 * 1000),
        ]
        if !screen.isEmpty { o["screen"] = screen }
        queue.async { [weak self] in self?.enqueue(o) }
    }

    /// Crash-path enqueue: waits (bounded) until the event is queued AND
    /// persisted to disk, so the imminent process death can't lose it. The
    /// timeout guarantees a wedged queue can never turn a crash into a hang.
    func addCrashSync(_ ev: [String: Any], timeout: TimeInterval = 1.0) {
        var o = ev
        if o["event_id"] == nil { o["event_id"] = randomID() }
        if o["ts_ms"] == nil { o["ts_ms"] = Int64(Date().timeIntervalSince1970 * 1000) }
        let sem = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            if let self = self {
                self.events.append(o)
                while self.events.count > self.maxQueue { self.events.removeFirst() }
                self.persist()
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
    }

    /// Sets external_id (all events hereafter) and emits one identify event;
    /// traits go through the same redact+project pipeline as bodies. Fail-open.
    func identify(_ externalId: String, traits: [String: Any] = [:]) {
        guard !externalId.isEmpty else { return }
        var redactedTraits: String?
        if !traits.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: traits, options: []),
           let json = String(data: data, encoding: .utf8) {
            redactedTraits = Classify.classifyBody(Redact.redactBody(json)).projection
        }
        var ev: [String: Any] = [
            "kind": "identify",
            "event_id": randomID(),
            "ts_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "external_id": externalId,
        ]
        if let rt = redactedTraits { ev["traits"] = rt }
        queue.async { [weak self] in
            self?.externalId = externalId
            self?.enqueue(ev)
        }
    }

    /// Sets/clears a session-scoped experiment variant (all events hereafter, as
    /// `experiments`). A nil/empty `variant` clears `key`. Fail-open.
    func setExperiment(_ key: String, variant: String?) {
        guard !key.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            if let v = variant, !v.isEmpty {
                self.experimentsMap[key] = v
            } else {
                self.experimentsMap.removeValue(forKey: key)
            }
        }
    }

    /// Flush the pending queue under the CURRENT (old) session id, then adopt the
    /// new one — rotation never mislabels queued events.
    func rotateSession(to newId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.flush()   // envelope snapshots the old session_id synchronously
            self.context["session_id"] = newId
        }
    }

    /// Force-send everything queued now, bypassing batch/backoff timers.
    func forceFlush(_ completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { completion?(); return }
            self.retries = 0
            self.flush(completion)
        }
    }

    private func toNet(_ e: NetworkEvent) -> ([String: Any], [String: String]) {
        let status = e.statusCode ?? 0
        let failed = e.errorText != nil || status >= 400
        var o: [String: Any] = [
            "kind": failed ? "net_fail" : "net",
            "event_id": randomID(),
            "ts_ms": e.timestampMs,
            "method": e.method,
            "url": e.url,
            "status": status,
            "error_kind": failed ? (e.errorText != nil ? "transport" : (status >= 500 ? "server" : "client")) : "",
            "duration_ms": e.durationMs,
            "req_bytes": e.requestBodyBytes,
            "resp_bytes": e.responseBodyBytes,
        ]
        // Seal-by-default classifier: free-text PII that value-scrubbing can't
        // pattern-match seals to a typed placeholder in the projection; the raw value
        // goes to piiMap for HPKE sealing (see sealInto). projection is leak-free.
        let reqC = Classify.classifyBody(e.requestBody)
        let respC = Classify.classifyBody(e.responseBody)
        var pii: [String: String] = [:]
        for (k, v) in reqC.piiMap { pii["req." + k] = v }
        for (k, v) in respC.piiMap { pii["resp." + k] = v }
        if let rb = reqC.projection { o["req_body"] = rb }
        if let sb = respC.projection { o["body"] = sb }
        o["req_headers"] = capHeaders(e.requestHeaders)
        o["resp_headers"] = capHeaders(e.responseHeaders)
        return (o, pii)
    }

    /// Cap the already-redacted header map: 48 entries max; oversized serialization → {}.
    private func capHeaders(_ h: [String: String]) -> [String: String] {
        var out = h
        if out.count > Self.headersMaxEntries {
            out = Dictionary(uniqueKeysWithValues:
                h.sorted { $0.key < $1.key }.prefix(Self.headersMaxEntries).map { ($0.key, $0.value) })
        }
        guard let d = try? JSONSerialization.data(withJSONObject: out, options: []) else { return [:] }
        return d.count > Self.headersMaxJsonBytes ? [:] : out
    }

    private static let headersMaxEntries = 48
    private static let headersMaxJsonBytes = 8192

    private func enqueue(_ ev: [String: Any]) {
        events.append(ev)
        while events.count > maxQueue { events.removeFirst() }
        schedulePersist()
        if retries > 0 { return }
        if events.count >= maxBatch { flush() } else { scheduleFlush() }
    }

    private func scheduleFlush() {
        if flushScheduled { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            self?.flushScheduled = false
            self?.flush()
        }
    }

    private func flush(_ completion: (() -> Void)? = nil) {
        if events.isEmpty { completion?(); return }
        let batch = Array(events.prefix(1000))
        events.removeFirst(batch.count)

        var envelope = context
        envelope["sent_at_ms"] = Int64(Date().timeIntervalSince1970 * 1000)
        envelope["events"] = batch
        if let id = externalId { envelope["external_id"] = id }
        if !experimentsMap.isEmpty { envelope["experiments"] = experimentsMap }
        guard let body = try? JSONSerialization.data(withJSONObject: envelope, options: []) else {
            // Unserializable batch: drop it rather than loop forever.
            completion?()
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let task = delivery.dataTask(with: req) { [weak self] _, response, _ in
            guard let self = self else { completion?(); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let acked = (200..<300).contains(code)
            // A 4xx (revoked/invalid key 401, bad batch 400/413, quota 429-excepted)
            // will NEVER succeed on retry — retrying it forever head-of-line-blocks
            // the queue and drops every newer event + drains the battery. DROP the
            // batch on a non-retriable 4xx; only 5xx/network errors retry. 429 is
            // retriable (transient rate-limit).
            let permanent = (400..<500).contains(code) && code != 429 && code != 408
            self.queue.async {
                if acked || permanent {
                    self.retries = 0
                    self.schedulePersist()          // batch consumed (delivered or dropped)
                    if !self.events.isEmpty { self.scheduleFlush() }
                } else {
                    self.events.insert(contentsOf: batch, at: 0)
                    while self.events.count > self.maxQueue { self.events.removeLast() }
                    self.schedulePersist()
                    self.armBackoff()
                }
                completion?()
            }
        }
        URLSessionCapture.markInternal(task)
        task.resume()
    }

    private func armBackoff() {
        let exp = Double(Self.baseBackoffMs) * pow(2, Double(min(retries, 20)))
        let capped = min(exp, Double(Self.maxBackoffMs))
        let delay = (Double(Self.baseBackoffMs) + Double.random(in: 0..<capped)) / 1000.0
        retries += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush() }
    }

    // --- persistence (serialized on `queue`; one write per tick, no loop) ---
    private func schedulePersist() {
        queue.async { [weak self] in self?.persist() }
    }

    private func persist() {
        do {
            if events.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                let lines = events.compactMap { ev -> String? in
                    guard let d = try? JSONSerialization.data(withJSONObject: ev, options: []) else { return nil }
                    return String(data: d, encoding: .utf8)
                }
                let tmp = fileURL.appendingPathExtension("tmp")
                try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
                _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            }
        } catch {
            // best-effort
        }
    }

    private func restore() {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        for line in content.split(separator: "\n") {
            if events.count >= maxQueue { break }
            if let d = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                events.append(obj)
            }
        }
        if !events.isEmpty { scheduleFlush() }
    }

    private func randomID() -> String {
        var s = ""
        for _ in 0..<16 { s += String(format: "%02x", Int.random(in: 0..<256)) }
        return s
    }

    private static let baseBackoffMs = 2_000
    private static let maxBackoffMs = 5 * 60_000
}
