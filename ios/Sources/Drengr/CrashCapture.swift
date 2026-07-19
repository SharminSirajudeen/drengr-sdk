import Foundation

/// Crash autocapture: NSSetUncaughtExceptionHandler for NSExceptions plus
/// sigaction handlers for the fatal signals (SIGABRT/SIGSEGV/SIGBUS/SIGILL/
/// SIGFPE/SIGTRAP — Swift fatalError traps as SIGTRAP). Both paths persist a
/// contract-shaped crash event `{kind: crash, error_kind, screen}` and then
/// CHAIN to the previous handler / re-raise — the app crashes exactly as it
/// did without the SDK, never swallowed.
///
/// The signal path is async-signal-safe by construction: the JSON line is
/// pre-serialized per signal into a double-buffered region (re-baked on every
/// screen change; the handler reads whichever slot the atomic index points at),
/// and the handler only patches the timestamp digits in place, then
/// open()/write()/fsync()/close() on a dedicated crash file — all
/// async-signal-safe syscalls. No allocation, no locks, no Objective-C. The
/// file is drained into the sink on the next launch.
///
/// The NSException path runs in a normal (pre-abort) context, so it enqueues
/// through the sink with a bounded synchronous persist + flush before chaining.
enum CrashCapture {
    /// The consent gate is the lock-free Int32 set via setEnabled (shared with
    /// the signal handler) — a crash-time check must never contend for a lock.
    struct Config {
        var onCrash: ([String: Any]) -> Void
    }

    static let signalDefs: [(Int32, String)] = [
        (SIGABRT, "SIGABRT"), (SIGSEGV, "SIGSEGV"), (SIGBUS, "SIGBUS"),
        (SIGILL, "SIGILL"), (SIGFPE, "SIGFPE"), (SIGTRAP, "SIGTRAP"),
    ]
    static let signalCount = 6
    static let lineCap = 1024
    static let maxScreenChars = 256

    private static var config: Config?
    private static var installed = false
    private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
    private static let lock = NSLock()
    private static let bakeLock = NSLock()

    // Signal-handler state. Allocated once, never freed (a handler may hold a
    // pointer at any time), and force-touched at install so Swift's lazy static
    // initialization can never first-run inside a signal handler.
    static let pathBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
    static let lines = UnsafeMutablePointer<UInt8>.allocate(capacity: 2 * signalCount * lineCap)
    static let lineLens = UnsafeMutablePointer<Int32>.allocate(capacity: 2 * signalCount)
    static let tsOffsets = UnsafeMutablePointer<Int32>.allocate(capacity: 2 * signalCount)
    static let sigNums = UnsafeMutablePointer<Int32>.allocate(capacity: signalCount)
    static let prevActions = UnsafeMutablePointer<sigaction>.allocate(capacity: signalCount)
    static let activeSlot = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    static let handled = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    static let enabledInt = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    /// Idempotent; re-install just swaps the config.
    static func install(config newConfig: Config) {
        lock.lock(); defer { lock.unlock() }
        config = newConfig
        if installed { return }
        bootstrap()
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(exceptionHandler)
        var action = sigaction()
        action.__sigaction_u = __sigaction_u(__sa_handler: signalHandler)
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_ONSTACK   // use an alternate stack if one exists (stack-overflow SIGSEGV)
        for i in 0..<signalCount {
            sigaction(sigNums[i], &action, prevActions + i)
        }
        installed = true
        bake(screen: ScreenState.screen)
    }

    /// Restore the previous exception handler and signal dispositions.
    static func uninstall() {
        lock.lock(); defer { lock.unlock() }
        guard installed else { return }
        NSSetUncaughtExceptionHandler(previousExceptionHandler)
        previousExceptionHandler = nil
        for i in 0..<signalCount {
            sigaction(sigNums[i], prevActions + i, nil)
        }
        installed = false
        config = nil
        handled.pointee = 0
    }

    /// Consent gate mirrored into an Int32 the signal handler can read.
    static func setEnabled(_ v: Bool) {
        enabledInt.pointee = v ? 1 : 0
    }

    /// Re-bake the pre-serialized signal lines with the new screen. Called by
    /// screen_view capture on every transition; cheap and off the hot path.
    static func noteScreen(_ name: String) {
        lock.lock(); let ok = installed; lock.unlock()
        if ok { bake(screen: name) }
    }

    /// Ship crash events persisted by a previous run's signal handler, then
    /// delete the file (delete-before-enqueue: never double-sends).
    static func drainPending(into sink: IngestSink) {
        let url = crashFileURL()
        DispatchQueue.global(qos: .utility).async {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: url)
            for line in content.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      obj["kind"] as? String == "crash" else { continue }
                sink.addBehavior(obj)
            }
        }
    }

    static func crashFileURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("drengr_crash.jsonl")
    }

    // --- NSException path (normal context: report through the sink, then chain) ---

    private static let exceptionHandler: @convention(c) (NSException) -> Void = { e in
        CrashCapture.handleException(e)
    }

    static func handleException(_ e: NSException) {
        if handled.pointee == 0 {
            handled.pointee = 1   // the abort() that follows must not double-report via SIGABRT
            reportException(e)
        }
        lock.lock(); let prev = previousExceptionHandler; lock.unlock()
        prev?(e)   // never swallow — the runtime aborts after this returns, as before
    }

    /// Type + first symbolicated frame only — exception REASONS can carry PII,
    /// never ship them (same rule as Flutter/JS).
    private static func reportException(_ e: NSException) {
        lock.lock(); let cfg = config; lock.unlock()
        guard let cfg = cfg, enabledInt.pointee == 1 else { return }
        let kind = Redact.scrubValues(String(e.name.rawValue.prefix(128)))
        let frame = e.callStackSymbols.first.map {
            Redact.scrubValues(String($0.trimmingCharacters(in: .whitespaces).prefix(200)))
        } ?? ""
        cfg.onCrash([
            "kind": "crash",
            "ts_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "screen": ScreenState.screen,
            "error_kind": kind,
            "exception_type": kind,   // pipeline crash grouping reads exception_type; same value
            "message": frame,
        ])
    }

    // --- Signal path (async-signal-safe: pre-baked line, syscalls only) ---

    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        var idx = -1
        var i = 0
        while i < CrashCapture.signalCount {
            if CrashCapture.sigNums[i] == sig { idx = i; break }
            i += 1
        }
        if idx >= 0 {
            if CrashCapture.handled.pointee == 0 && CrashCapture.enabledInt.pointee == 1 {
                CrashCapture.handled.pointee = 1
                let li = Int(CrashCapture.activeSlot.pointee) * CrashCapture.signalCount + idx
                let len = Int(CrashCapture.lineLens[li])
                if len > 0 {
                    let ptr = CrashCapture.lines + li * CrashCapture.lineCap
                    CrashCapture.patchTimestamp(ptr + Int(CrashCapture.tsOffsets[li]))
                    let fd = open(CrashCapture.pathBuf, O_WRONLY | O_APPEND | O_CREAT, mode_t(0o600))
                    if fd >= 0 {
                        _ = write(fd, ptr, len)
                        fsync(fd)
                        close(fd)
                    }
                }
            }
            // Restore the previous disposition and re-raise — NEVER swallow. The
            // signal is blocked while we run, so raise() marks it pending and it
            // delivers to the restored handler the moment we return.
            sigaction(sig, CrashCapture.prevActions + idx, nil)
        }
        raise(sig)
    }

    /// Overwrite the fixed 13-digit ts_ms zone with the current epoch-ms.
    /// clock_gettime + a digit loop — both async-signal-safe. Leaves the
    /// bake-time timestamp when the clock is implausible.
    static func patchTimestamp(_ p: UnsafeMutablePointer<UInt8>) {
        var ts = timespec()
        guard clock_gettime(CLOCK_REALTIME, &ts) == 0 else { return }
        var ms = Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
        guard ms >= 1_000_000_000_000, ms <= 9_999_999_999_999 else { return }
        var i = 12
        while i >= 0 {
            p[i] = UInt8(48 + ms % 10)
            ms /= 10
            i -= 1
        }
    }

    /// One pre-serialized crash line for a signal; the returned offset marks the
    /// fixed-width ts_ms zone the handler patches. Pure — unit-tested off-device.
    static func signalLine(name: String, screen: String, eventId: String, tsMs: Int64) -> (line: String, tsOffset: Int) {
        let head = "{\"kind\":\"crash\",\"event_id\":\"\(eventId)\",\"ts_ms\":"
        let clamped = min(max(tsMs, 1_000_000_000_000), 9_999_999_999_999)
        let scrubbed = Redact.scrubValues(String(screen.prefix(maxScreenChars)))
        let tail = ",\"screen\":\"\(jsonEscape(scrubbed))\"," +
            "\"error_kind\":\"\(name)\",\"exception_type\":\"\(name)\"}\n"
        return (head + String(clamped) + tail, head.utf8.count)
    }

    static func jsonEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// Write all six signal lines into the INACTIVE slot, then flip the atomic
    /// slot index — the handler always reads a fully-written slot.
    private static func bake(screen: String) {
        bakeLock.lock(); defer { bakeLock.unlock() }
        let slot = 1 - Int(activeSlot.pointee)
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        for (i, def) in signalDefs.enumerated() {
            var (line, tsOff) = signalLine(name: def.1, screen: screen, eventId: randomHex(), tsMs: ts)
            var bytes = Array(line.utf8)
            if bytes.count > lineCap {   // pathological escaped screen: bake without it
                (line, tsOff) = signalLine(name: def.1, screen: "", eventId: randomHex(), tsMs: ts)
                bytes = Array(line.utf8)
            }
            let idx = slot * signalCount + i
            bytes.withUnsafeBufferPointer { buf in
                (lines + idx * lineCap).update(from: buf.baseAddress!, count: buf.count)
            }
            tsOffsets[idx] = Int32(tsOff)
            lineLens[idx] = Int32(bytes.count)
        }
        activeSlot.pointee = Int32(slot)
    }

    /// Force-initialize every static the handler touches and load the crash-file
    /// path as a C string. Runs once, inside install's lock.
    private static func bootstrap() {
        for (i, def) in signalDefs.enumerated() {
            sigNums[i] = def.0
            prevActions[i] = sigaction()
        }
        for i in 0..<(2 * signalCount) {
            lineLens[i] = 0
            tsOffsets[i] = 0
        }
        activeSlot.pointee = 0
        handled.pointee = 0
        enabledInt.pointee = 1
        let path = crashFileURL().path
        _ = path.withCString { strlcpy(pathBuf, $0, 1024) }
        _ = patchTimestamp   // touch the remaining lazily-initialized statics
        _ = signalHandler
    }

    private static func randomHex() -> String {
        var s = ""
        for _ in 0..<16 { s += String(format: "%02x", Int.random(in: 0..<256)) }
        return s
    }

    /// Test seam: clear the one-shot crash flag between simulated crashes.
    static func resetHandledForTesting() {
        handled.pointee = 0
    }

    /// Test seam: the currently-active pre-baked line for a signal.
    static func bakedLine(for sig: Int32) -> String? {
        guard let idx = signalDefs.firstIndex(where: { $0.0 == sig }) else { return nil }
        bakeLock.lock(); defer { bakeLock.unlock() }
        let li = Int(activeSlot.pointee) * signalCount + idx
        let len = Int(lineLens[li])
        guard len > 0 else { return nil }
        return String(decoding: UnsafeBufferPointer(start: lines + li * lineCap, count: len), as: UTF8.self)
    }
}
