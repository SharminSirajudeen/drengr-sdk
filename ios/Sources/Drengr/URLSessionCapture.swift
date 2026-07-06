import Foundation
import ObjectiveC.runtime

/// Passive URLSession capture — the redesign of the old URLProtocol re-issue model
/// (task #22). It OBSERVES the app's own tasks by method-swizzling; it never
/// re-issues a request through a private session, so:
///   • the app's certificate pinning / auth-challenge delegate runs untouched
///     (no TLS downgrade — the old model's #9 blocker), and
///   • coverage is universal: every task on every session (URLSession.shared,
///     `.default`, custom-config, Alamofire, async/await) is seen, not just
///     `.shared` + hand-registered configs (the old model's #7 blocker).
///
/// Three layers, all read-only (arguments forwarded verbatim, never mutated):
///   A (public, robust): swizzle `dataTaskWithRequest:completionHandler:` +
///     `dataTaskWithURL:completionHandler:` on the concrete session class. The
///     completion handler already holds the fully-materialised body, so this is
///     the clean RESPONSE-BODY path — zero extra buffering. Public ObjC runtime
///     only; App-Store-safe.
///   A2 (private, FAIL-OPEN): swizzle `_dataTaskWith{Request,URL}:delegate:
///     completionHandler:` — the selectors async/await (`data(for:)`) tasks are
///     created through — for their bodies the same way.
///   B (private, FAIL-OPEN): swizzle `resume` + private `setState:` on
///     `__NSCFLocalSessionTask` for universal metadata (status/timing/bytes/error);
///     `resume` also attaches a forwarding-proxy per-task delegate to
///     delegate-driven tasks (Alamofire-style) that tees the response body while
///     the app's delegate receives every callback unchanged. If any private hook
///     disappears, that layer silently disables — degrade, never crash.
///
/// Honest coverage: metadata is exact for every task; bodies are captured for
/// completion-handler, async/await (A2) and delegate-driven (proxy, iOS 15+)
/// tasks — best-effort per the accuracy doctrine.
enum URLSessionCapture {

    struct Config {
        var maxBodyBytes: Int
        var redactHeaderNames: Set<String>
        var onEvent: (NetworkEvent) -> Void
        var isEnabled: () -> Bool
        var shouldCapture: (String) -> Bool
    }

    private static var config: Config?
    private static var installed = false
    private static let lock = NSLock()

    // MARK: - internal (sink) session/task marking — never capture our own delivery

    private static var internalKey: UInt8 = 0

    /// Mark a session or task as Drengr-internal; the capture layers skip it.
    static func markInternal(_ object: AnyObject) {
        objc_setAssociatedObject(object, &internalKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    static func isInternal(_ object: AnyObject) -> Bool {
        (objc_getAssociatedObject(object, &internalKey) as? Bool) ?? false
    }

    /// Install all capture layers once. Idempotent; safe to call from Drengr.start.
    static func install(config newConfig: Config) {
        lock.lock(); defer { lock.unlock() }
        if installed { return }
        config = newConfig
        installLayerA()   // public completion-handler swizzle (bodies)
        installLayerA2()  // private async/await completion swizzle (bodies), fail-open
        installLayerB()   // private resume/setState swizzle (universal metadata), fail-open
        installed = true
    }

    // MARK: - per-task state (associated object)

    private final class TaskState {
        var startMs: Int64 = 0
        var completionHandled = false   // a completion wrap owns this task's emit → layer B must not double-emit
        var completionEmitted = false   // public selectors can route through private ones — first wrap to fire wins
        var proxied = false             // body-capture delegate already attached
        var body = Data()               // passively teed response body (delegate/proxy path)
        var bodyOverflow = false
        var bodyAllowed: Bool?          // capture gate, decided at first chunk (whole body or nothing)
    }

    /// Lets a wrapped completion reach its task's state at fire time (the task
    /// doesn't exist yet when the wrap is built).
    private final class TaskBox { weak var task: URLSessionTask? }
    private static var stateKey: UInt8 = 0
    private static func state(for task: URLSessionTask) -> TaskState {
        if let s = objc_getAssociatedObject(task, &stateKey) as? TaskState { return s }
        let s = TaskState()
        objc_setAssociatedObject(task, &stateKey, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    // MARK: - layers A/A2: completion-handler swizzles (response bodies)

    /// Wrap a completion so the body-carrying event is emitted at most once per
    /// task — the public selectors can route through the private ones, so the
    /// first wrap to fire wins (per-task `completionEmitted`).
    private static func wrapCompletion(request: URLRequest, startMs: Int64,
                                       _ completion: @escaping (Data?, URLResponse?, Error?) -> Void)
        -> ((Data?, URLResponse?, Error?) -> Void, TaskBox) {
        let box = TaskBox()
        let wrapped: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
            var skip = false
            if let t = box.task {
                let st = state(for: t)
                skip = st.completionEmitted
                st.completionEmitted = true
            }
            if !skip { emitCompletion(request: request, data: data, response: response, error: error, startMs: startMs) }
            completion(data, response, error)
        }
        return (wrapped, box)
    }

    private static func adoptCompletionTask(_ task: URLSessionDataTask, _ box: TaskBox, _ startMs: Int64) {
        box.task = task
        let st = state(for: task)
        if st.startMs == 0 { st.startMs = startMs }
        st.completionHandled = true
    }

    private static func passthroughInternal(_ task: URLSessionDataTask) -> URLSessionDataTask {
        markInternal(task)
        state(for: task).completionHandled = true
        return task
    }

    private static func installLayerA() {
        // Swizzle on the CONCRETE session class (class cluster): all URLSession
        // instances share one concrete subclass, so swizzling it there covers
        // shared / .default / custom-config sessions alike.
        let cls: AnyClass = object_getClass(URLSession.shared) ?? URLSession.self

        typealias ReqIMP = @convention(c) (URLSession, Selector, URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask
        typealias ReqBlock = @convention(block) (URLSession, URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask
        swizzle(cls, NSSelectorFromString("dataTaskWithRequest:completionHandler:")) { (orig: ReqIMP, sel) -> ReqBlock in
            { (session, request, completion) in
                if isInternal(session) { return passthroughInternal(orig(session, sel, request, completion)) }
                let start = nowMs()
                let (wrapped, box) = wrapCompletion(request: request, startMs: start, completion)
                let task = orig(session, sel, request, wrapped)
                adoptCompletionTask(task, box, start)
                return task
            }
        }

        typealias URLIMP = @convention(c) (URLSession, Selector, URL, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask
        typealias URLBlock = @convention(block) (URLSession, URL, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask
        swizzle(cls, NSSelectorFromString("dataTaskWithURL:completionHandler:")) { (orig: URLIMP, sel) -> URLBlock in
            { (session, url, completion) in
                if isInternal(session) { return passthroughInternal(orig(session, sel, url, completion)) }
                let start = nowMs()
                let (wrapped, box) = wrapCompletion(request: URLRequest(url: url), startMs: start, completion)
                let task = orig(session, sel, url, wrapped)
                adoptCompletionTask(task, box, start)
                return task
            }
        }
    }

    /// async/await tasks (`URLSession.data(for:)` & friends) are completion tasks
    /// under the hood, created via these PRIVATE selectors — wrap their completions
    /// for bodies. If Apple renames them, this layer silently never installs and
    /// async tasks stay metadata-only via layer B — degrade, never crash.
    private static func installLayerA2() {
        let cls: AnyClass = object_getClass(URLSession.shared) ?? URLSession.self

        typealias PReqIMP = @convention(c) (URLSession, Selector, URLRequest, AnyObject?, ((Data?, URLResponse?, Error?) -> Void)?) -> URLSessionDataTask
        typealias PReqBlock = @convention(block) (URLSession, URLRequest, AnyObject?, ((Data?, URLResponse?, Error?) -> Void)?) -> URLSessionDataTask
        swizzle(cls, NSSelectorFromString("_dataTaskWithRequest:delegate:completionHandler:")) { (orig: PReqIMP, sel) -> PReqBlock in
            { (session, request, delegate, completion) in
                guard !isInternal(session), let completion = completion else {
                    let task = orig(session, sel, request, delegate, completion)
                    if isInternal(session) { return passthroughInternal(task) }
                    return task
                }
                let start = nowMs()
                let (wrapped, box) = wrapCompletion(request: request, startMs: start, completion)
                let task = orig(session, sel, request, delegate, wrapped)
                adoptCompletionTask(task, box, start)
                return task
            }
        }

        typealias PURLIMP = @convention(c) (URLSession, Selector, URL, AnyObject?, ((Data?, URLResponse?, Error?) -> Void)?) -> URLSessionDataTask
        typealias PURLBlock = @convention(block) (URLSession, URL, AnyObject?, ((Data?, URLResponse?, Error?) -> Void)?) -> URLSessionDataTask
        swizzle(cls, NSSelectorFromString("_dataTaskWithURL:delegate:completionHandler:")) { (orig: PURLIMP, sel) -> PURLBlock in
            { (session, url, delegate, completion) in
                guard !isInternal(session), let completion = completion else {
                    let task = orig(session, sel, url, delegate, completion)
                    if isInternal(session) { return passthroughInternal(task) }
                    return task
                }
                let start = nowMs()
                let (wrapped, box) = wrapCompletion(request: URLRequest(url: url), startMs: start, completion)
                let task = orig(session, sel, url, delegate, wrapped)
                adoptCompletionTask(task, box, start)
                return task
            }
        }
    }

    // MARK: - layer B: resume + setState swizzles (universal metadata), FAIL-OPEN

    private static func installLayerB() {
        // Concrete private task class. If Apple ever renames it, layer B is simply
        // never installed and layer A remains fully functional — no crash.
        guard let taskCls = NSClassFromString("__NSCFLocalSessionTask") else { return }

        // resume(): fires for EVERY task (incl. async/await + delegate) before I/O
        // starts — the universal start-time hook.
        typealias ResumeIMP = @convention(c) (URLSessionTask, Selector) -> Void
        typealias ResumeBlock = @convention(block) (URLSessionTask) -> Void
        swizzle(taskCls, NSSelectorFromString("resume")) { (orig: ResumeIMP, sel) -> ResumeBlock in
            { task in
                let st = state(for: task)
                if st.startMs == 0 { st.startMs = nowMs() }
                attachBodyCapture(task)
                orig(task, sel)
            }
        }

        // Private setState:: the task's own state machine. State 3 == .completed,
        // 2 == .canceling. Emit metadata for tasks layer A didn't already handle.
        typealias StateIMP = @convention(c) (URLSessionTask, Selector, Int) -> Void
        typealias StateBlock = @convention(block) (URLSessionTask, Int) -> Void
        swizzle(taskCls, NSSelectorFromString("setState:")) { (orig: StateIMP, sel) -> StateBlock in
            { task, newState in
                orig(task, sel, newState)
                guard newState == URLSessionTask.State.completed.rawValue else { return }
                if isInternal(task) { return }       // Drengr's own delivery — never self-capture
                let st = state(for: task)
                if st.completionHandled { return }   // layer A already emitted the body-carrying event
                st.completionHandled = true          // guard against setState firing twice
                emitMetadata(task: task, startMs: st.startMs)
            }
        }
    }

    // MARK: - delegate-stack body capture (per-task forwarding proxy)

    /// Give a delegate-driven data task a proxy that tees `didReceive data` into
    /// the capture buffer and forwards EVERY callback to the app's own (task or
    /// session) delegate unchanged. A bare capture delegate would STEAL data
    /// delivery from a session delegate (task delegate wins per method), so the
    /// proxy always wraps the app's delegate; with no delegate anywhere there is
    /// nothing to tee (completion/async tasks are handled by layers A/A2).
    private static func attachBodyCapture(_ task: URLSessionTask) {
        guard #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *) else { return }
        guard config != nil, task is URLSessionDataTask, !isUnsupported(task), !isInternal(task) else { return }
        let st = state(for: task)
        if st.completionHandled || st.proxied { return }
        let target = task.delegate ?? sessionDelegate(of: task)
        guard let underlying = target, !(underlying is CaptureDelegateProxy) else { return }
        task.delegate = CaptureDelegateProxy(underlying: underlying)
        st.proxied = true
    }

    /// The owning session's delegate, via the task's private `session` accessor
    /// (responds-guarded — fail-open to nil).
    private static func sessionDelegate(of task: URLSessionTask) -> URLSessionDelegate? {
        let sel = NSSelectorFromString("session")
        guard task.responds(to: sel),
              let session = task.perform(sel)?.takeUnretainedValue() as? URLSession,
              !isInternal(session) else { return nil }
        return session.delegate
    }

    /// Tee one delegate-path body chunk (gate decided at first chunk: whole body or nothing).
    fileprivate static func bufferBody(_ task: URLSessionTask, _ data: Data) {
        guard let cfg = config else { return }
        let st = state(for: task)
        if st.bodyAllowed == nil {
            let url = task.originalRequest?.url?.absoluteString ?? task.currentRequest?.url?.absoluteString ?? ""
            st.bodyAllowed = !url.isEmpty && !isInternal(task) && cfg.isEnabled() && cfg.shouldCapture(url)
        }
        guard st.bodyAllowed == true, !st.bodyOverflow else { return }
        if st.body.count + data.count > cfg.maxBodyBytes {
            st.bodyOverflow = true
            st.body = Data()
            return
        }
        st.body.append(data)
    }

    // MARK: - swizzle helper (composable, fail-open)

    /// Replace `sel`'s IMP on `cls` with a block built from the original IMP.
    /// `make` receives the original C-function IMP + the selector and returns the
    /// replacement block. Silently no-ops if the method is absent.
    private static func swizzle<IMPType, BlockType>(
        _ cls: AnyClass, _ sel: Selector, _ make: (IMPType, Selector) -> BlockType
    ) {
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let originalIMP = method_getImplementation(method)
        let orig = unsafeBitCast(originalIMP, to: IMPType.self)
        let block = make(orig, sel)
        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(method, newIMP)
    }

    // MARK: - event construction

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// AVAssetDownloadTask & friends throw NSException (uncatchable in Swift) on
    /// `originalRequest`/`response` access — skip them by class name, no AVFoundation import.
    private static func isUnsupported(_ task: URLSessionTask) -> Bool {
        let cn = NSStringFromClass(type(of: task))
        return cn.contains("AVAsset") || cn.contains("AVAggregate")
    }

    private static func gatePasses(_ url: String) -> Bool {
        guard let cfg = config else { return false }
        if !cfg.isEnabled() { return false }
        return cfg.shouldCapture(url)
    }

    /// Layer A: completion-handler task — we have the full request, response, and body.
    private static func emitCompletion(request: URLRequest, data: Data?, response: URLResponse?, error: Error?, startMs: Int64) {
        guard let cfg = config else { return }
        let url = request.url?.absoluteString ?? ""
        guard gatePasses(url) else { return }
        let http = response as? HTTPURLResponse
        let ct = http?.value(forHTTPHeaderField: "Content-Type")
        var respBody: String? = nil
        if error == nil, let data = data, isTextual(ct), data.count <= cfg.maxBodyBytes,
           let text = String(data: data, encoding: .utf8) {
            respBody = Redact.redactBody(text)
        }
        emit(cfg: cfg, method: request.httpMethod ?? "GET", url: url,
             reqHeaders: request.allHTTPHeaderFields ?? [:], reqBodyData: request.httpBody,
             status: http?.statusCode, respHeaders: (http?.allHeaderFields as? [String: String]) ?? [:],
             respBody: respBody, respByteCount: data?.count ?? 0,
             expectedLen: http?.expectedContentLength ?? -1, error: error, startMs: startMs)
    }

    /// Layer B: delegate task — metadata plus any body the proxy passively teed.
    private static func emitMetadata(task: URLSessionTask, startMs: Int64) {
        guard let cfg = config, !isUnsupported(task) else { return }
        let request = task.originalRequest ?? task.currentRequest
        let url = request?.url?.absoluteString ?? ""
        guard !url.isEmpty, gatePasses(url) else { return }
        let http = task.response as? HTTPURLResponse
        let st = state(for: task)
        var respBody: String? = nil
        if task.error == nil, !st.body.isEmpty, !st.bodyOverflow,
           isTextual(http?.value(forHTTPHeaderField: "Content-Type")),
           let text = String(data: st.body, encoding: .utf8) {
            respBody = Redact.redactBody(text)
        }
        emit(cfg: cfg, method: request?.httpMethod ?? "GET", url: url,
             reqHeaders: request?.allHTTPHeaderFields ?? [:], reqBodyData: request?.httpBody,
             status: http?.statusCode, respHeaders: (http?.allHeaderFields as? [String: String]) ?? [:],
             respBody: respBody, respByteCount: Int(task.countOfBytesReceived),
             expectedLen: http?.expectedContentLength ?? -1, error: task.error, startMs: startMs)
    }

    private static func emit(cfg: Config, method: String, url: String, reqHeaders: [String: String],
                             reqBodyData: Data?, status: Int?, respHeaders: [String: String],
                             respBody: String?, respByteCount: Int, expectedLen: Int64,
                             error: Error?, startMs: Int64) {
        var reqBody: String? = nil
        if let body = reqBodyData, body.count <= cfg.maxBodyBytes,
           isTextual(reqHeaders.first(where: { $0.key.lowercased() == "content-type" })?.value),
           let s = String(data: body, encoding: .utf8) {
            reqBody = Redact.redactBody(s)
        }
        let start = startMs == 0 ? nowMs() : startMs
        let event = NetworkEvent(
            method: method.uppercased(),
            url: Redact.redactURL(url),
            statusCode: status,
            durationMs: Int(nowMs() - start),
            requestBodyBytes: reqBodyData?.count ?? 0,
            responseBodyBytes: expectedLen > 0 ? Int(expectedLen) : respByteCount,
            requestHeaders: Redact.redactHeaders(reqHeaders, extra: cfg.redactHeaderNames),
            responseHeaders: Redact.redactHeaders(respHeaders, extra: cfg.redactHeaderNames),
            requestBody: reqBody,
            responseBody: respBody,
            errorText: error.map { ($0 as NSError).domain },
            timestampMs: start
        )
        cfg.onEvent(event)
    }

    private static func isTextual(_ ct: String?) -> Bool {
        guard let ct = ct?.lowercased() else { return false }
        return ct.hasPrefix("text/") || ct.contains("json") || ct.contains("xml") ||
            ct.contains("x-www-form-urlencoded") || ct.contains("graphql")
    }
}

/// Forwarding proxy set as a task's per-task delegate: tees `didReceive data`
/// into the capture buffer, forwards every callback (incl. auth challenges,
/// redirects, metrics) to the app's own delegate unchanged.
final class CaptureDelegateProxy: NSObject, URLSessionDataDelegate {
    private let underlying: URLSessionDelegate

    init(underlying: URLSessionDelegate) {
        self.underlying = underlying
        super.init()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || underlying.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        underlying.responds(to: aSelector) ? underlying : nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        URLSessionCapture.bufferBody(dataTask, data)
        (underlying as? URLSessionDataDelegate)?.urlSession?(session, dataTask: dataTask, didReceive: data)
    }
}
