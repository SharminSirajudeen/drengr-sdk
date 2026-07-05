import Foundation
import ObjectiveC.runtime

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

    static func install(config newConfig: Config) {
        lock.lock(); defer { lock.unlock() }
        if installed { return }
        config = newConfig
        installLayerA()
        installLayerB()
        installed = true
    }

    private final class TaskState {
        var startMs: Int64 = 0
        var completionHandled = false
    }
    private static var stateKey: UInt8 = 0
    private static func state(for task: URLSessionTask) -> TaskState {
        if let s = objc_getAssociatedObject(task, &stateKey) as? TaskState { return s }
        let s = TaskState()
        objc_setAssociatedObject(task, &stateKey, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    private static func installLayerA() {
        let cls: AnyClass = object_getClass(URLSession.shared) ?? URLSession.self

        typealias ReqIMP = @convention(c) (URLSession, Selector, URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask
        typealias ReqBlock = @convention(block) (URLSession, URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask
        swizzle(cls, NSSelectorFromString("dataTaskWithRequest:completionHandler:")) { (orig: ReqIMP, sel) -> ReqBlock in
            { (session, request, completion) in
                let start = nowMs()
                let wrapped: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                    emitCompletion(request: request, data: data, response: response, error: error, startMs: start)
                    completion(data, response, error)
                }
                let task = orig(session, sel, request, wrapped)
                let st = state(for: task); st.startMs = start; st.completionHandled = true
                return task
            }
        }

        typealias URLIMP = @convention(c) (URLSession, Selector, URL, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask
        typealias URLBlock = @convention(block) (URLSession, URL, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask
        swizzle(cls, NSSelectorFromString("dataTaskWithURL:completionHandler:")) { (orig: URLIMP, sel) -> URLBlock in
            { (session, url, completion) in
                let start = nowMs()
                let request = URLRequest(url: url)
                let wrapped: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                    emitCompletion(request: request, data: data, response: response, error: error, startMs: start)
                    completion(data, response, error)
                }
                let task = orig(session, sel, url, wrapped)
                let st = state(for: task); st.startMs = start; st.completionHandled = true
                return task
            }
        }
    }

    private static func installLayerB() {
        guard let taskCls = NSClassFromString("__NSCFLocalSessionTask") else { return }

        typealias ResumeIMP = @convention(c) (URLSessionTask, Selector) -> Void
        typealias ResumeBlock = @convention(block) (URLSessionTask) -> Void
        swizzle(taskCls, NSSelectorFromString("resume")) { (orig: ResumeIMP, sel) -> ResumeBlock in
            { task in
                let st = state(for: task)
                if st.startMs == 0 { st.startMs = nowMs() }
                orig(task, sel)
            }
        }

        typealias StateIMP = @convention(c) (URLSessionTask, Selector, Int) -> Void
        typealias StateBlock = @convention(block) (URLSessionTask, Int) -> Void
        swizzle(taskCls, NSSelectorFromString("setState:")) { (orig: StateIMP, sel) -> StateBlock in
            { task, newState in
                orig(task, sel, newState)
                guard newState == URLSessionTask.State.completed.rawValue else { return }
                let st = state(for: task)
                if st.completionHandled { return }
                st.completionHandled = true
                emitMetadata(task: task, startMs: st.startMs)
            }
        }
    }

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

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static func isUnsupported(_ task: URLSessionTask) -> Bool {
        let cn = NSStringFromClass(type(of: task))
        return cn.contains("AVAsset") || cn.contains("AVAggregate")
    }

    private static func gatePasses(_ url: String) -> Bool {
        guard let cfg = config else { return false }
        if !cfg.isEnabled() { return false }
        return cfg.shouldCapture(url)
    }

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

    private static func emitMetadata(task: URLSessionTask, startMs: Int64) {
        guard let cfg = config, !isUnsupported(task) else { return }
        let request = task.originalRequest ?? task.currentRequest
        let url = request?.url?.absoluteString ?? ""
        guard !url.isEmpty, gatePasses(url) else { return }
        let http = task.response as? HTTPURLResponse
        emit(cfg: cfg, method: request?.httpMethod ?? "GET", url: url,
             reqHeaders: request?.allHTTPHeaderFields ?? [:], reqBodyData: request?.httpBody,
             status: http?.statusCode, respHeaders: (http?.allHeaderFields as? [String: String]) ?? [:],
             respBody: nil, respByteCount: Int(task.countOfBytesReceived),
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
