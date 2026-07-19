import Foundation

/// Secret + PII redaction for captured events (port of redact.dart/js/kt): structural
/// key-masking + value-level scrubbing; best-effort, never throws (input unchanged).
enum Redact {
    static let mask = "[REDACTED]"

    /// Header names (lowercase) whose values are always masked.
    static let sensitiveHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie",
        "x-auth-token", "x-api-key", "x-access-token", "x-session-token",
        "x-secret", "www-authenticate", "proxy-authenticate",
        "x-csrf-token", "x-xsrf-token",
    ]

    // Whole-name matches (short tokens here, not as substrings).
    private static let sensitiveExact: Set<String> = [
        "password", "passwd", "pwd", "pass", "passphrase", "secret", "token",
        "authorization", "pin", "cvv", "cvc", "csc", "cvv2", "ssn", "sin",
        "otp", "totp", "iban",
    ]

    // Longer fragments safe as substrings of a normalized name.
    private static let sensitiveFragments: [String] = [
        "token", "secret", "password", "passphrase", "apikey", "apisecret",
        "accesstoken", "refreshtoken", "idtoken", "oauthtoken", "privatekey",
        "secretkey", "sessiontoken", "cardnumber", "cardno", "ccnumber",
        "creditcard", "accountnumber", "routingnumber", "sortcode",
        // Rare-substring credential tokens as fragments so COMPOUND names are
        // caught (card_cvv, payment_otp, user_ssn); pin/pass/sin stay exact-only.
        "cvv", "cvc", "cvv2", "ssn", "otp", "totp",
        // PII, redacted by default — 0-code means 0-code PII safety.
        "email", "phone", "firstname", "lastname", "fullname", "username",
        "recipientname", "customername", "sendername", "passport", "nationality",
        "address", "birthdate", "dateofbirth", "promocode", "promotioncode",
        "messagetext", "giftmessage",
        // Long, low-FP numeric-PII fragments — a national/tax id or geo coordinate sent
        // as a JSON NUMBER survives value-scrubbing; name-masking is the only catch for it.
        "latitude", "longitude", "nationalid", "taxid", "driverlicense", "driverslicense", "socialsecurity",
    ]

    static func isSensitiveName(_ name: String) -> Bool {
        let n = Patterns.norm(name)
        if sensitiveExact.contains(n) { return true }
        return sensitiveFragments.contains { n.contains($0) }
    }

    static func redactHeaders(_ headers: [String: String], extra: Set<String>) -> [String: String] {
        var out = [String: String]()
        for (k, v) in headers {
            let lk = k.lowercased()
            // Name-sensitive (fixed set, caller extras, or a PII-denoting name like
            // X-User-Phone) → full mask; else scrub PII values (a value can be PII
            // under a benign header name, e.g. X-Client-IP / X-Device-Id).
            out[k] = (sensitiveHeaders.contains(lk) || extra.contains(lk) || isSensitiveName(k)) ? mask : scrubValues(v)
        }
        return out
    }

    // --- value-level scrubbers ---
    // Value/secret/checksum patterns live in Patterns.swift (shared with Classify so a
    // hardening fix can't land in one file and be missed in the other). cookieLine is
    // redact-only (a whole-line mask, never a classifier detector), so it stays here.
    private static let cookieLine = try! NSRegularExpression(pattern: "^(set-cookie|cookie)\\s*:\\s*.*$", options: [.caseInsensitive, .anchorsMatchLines])

    /// ISO 7064 MOD-97-10 (the IBAN check). Re-exported from Patterns to preserve the
    /// public Redact API the parity suite calls.
    static func mod97(_ iban: String) -> Int { Patterns.mod97(iban) }

    /// An IBAN only if it matches the format AND passes mod-97. Re-exported from Patterns.
    static func isIbanValue(_ s: String) -> Bool { Patterns.isIbanValue(s) }

    private static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func scrubValues(_ s: String) -> String {
        // Structured PII FIRST — before the generic PAN digit-run, so an IBAN/E.164's
        // embedded digit run can't be swallowed and mislabeled a card. MAC before IPv6.
        var out = replaceAll(Patterns.ibanRe, in: s) { m in isIbanValue(m) ? "[REDACTED-IBAN]" : m } // mod-97 gate
        out = replaceAll(Patterns.cryptoRe, in: out) { _ in "[REDACTED-WALLET]" }
        out = replaceAll(Patterns.e164Re, in: out) { _ in "[REDACTED-PHONE]" }
        out = replaceAll(Patterns.macRe, in: out) { _ in "[REDACTED-MAC]" } // before ipv6 — a MAC's colons must not be half-eaten
        out = replaceAll(Patterns.ipv6Re, in: out) { _ in "[REDACTED-IP]" }
        out = replaceAll(Patterns.digitRunRe, in: out) { m in
            Patterns.looksLikePan(m.replacingOccurrences(of: "[ -]", with: "", options: .regularExpression)) ? "[REDACTED-PAN]" : m
        }
        out = replaceAll(Patterns.jwtRe, in: out) { _ in "[REDACTED-JWT]" }
        out = replaceAll(Patterns.bearerRe, in: out) { _ in "Bearer \(mask)" }
        out = replaceAll(cookieLine, in: out) { m in
            let prefix = m.lowercased().hasPrefix("set-cookie") ? "set-cookie" : "cookie"
            return "\(prefix): \(mask)"
        }
        out = replaceAll(Patterns.emailRe, in: out) { _ in "[REDACTED-EMAIL]" }
        out = replaceAll(Patterns.ssnRe, in: out) { _ in "[REDACTED-SSN]" }
        out = replaceAll(Patterns.phoneRe, in: out) { _ in "[REDACTED-PHONE]" }
        out = replaceAll(Patterns.secretTokenRe, in: out) { _ in "[REDACTED-SECRET]" }
        out = replaceAll(Patterns.pemBlockRe, in: out) { _ in "[REDACTED-KEY]" }
        out = replaceAll(Patterns.uuidRe, in: out) { _ in "[REDACTED-ID]" }
        out = replaceAll(Patterns.ipv4Re, in: out) { _ in "[REDACTED-IP]" }
        return out
    }

    static func redactURL(_ url: String) -> String {
        // Substring-based so RELATIVE urls (/api/pay?token=…) still get masked.
        guard let q = url.firstIndex(of: "?") else { return scrubValues(url) }
        let base = String(url[..<q])
        let afterQ = url.index(after: q)
        let fragIdx = url[afterQ...].firstIndex(of: "#")
        let queryEnd = fragIdx ?? url.endIndex
        let query = String(url[afterQ..<queryEnd])
        let tail = fragIdx != nil ? String(url[fragIdx!...]) : ""
        let maskedQuery = query.split(separator: "&", omittingEmptySubsequences: false).map { pairSub -> String in
            let pair = String(pairSub)
            if let eq = pair.firstIndex(of: "="), eq > pair.startIndex {
                let name = String(pair[..<eq])
                if isSensitiveName(name) { return "\(name)=\(mask)" }
            }
            return pair
        }.joined(separator: "&")
        return scrubValues("\(base)?\(maskedQuery)\(tail)")
    }

    // --- name-adjacent value scrubbers (bodies key-masking can't reach) ---
    // Mask a value whenever its adjacent NAME is sensitive — for bodies key-masking
    // misses (JSON truncated past the cap, XML/SOAP) and inline literals in a parsed
    // JSON string (GraphQL `query`). Value stops at any backslash/quote so a nested
    // literal matches the INNERMOST name:"value" pair. Bounded → linear, ReDoS-free.
    // escNamed runs FIRST (anchored on the escaped quote) so a plain-quote wrapper
    // can't shadow the first inner literal.
    private static let escNamed = try! NSRegularExpression(pattern: "([A-Za-z][A-Za-z0-9_.\\-]{0,63})(\\s*[:=]\\s*)\\\\\"[^\"\\\\]{0,8192}\\\\\"")
    private static let dqNamed = try! NSRegularExpression(pattern: "([\"']?)([A-Za-z][A-Za-z0-9_.\\-]{0,63})\\1(\\s*[:=]\\s*\\\\?\")[^\"\\\\]{0,8192}(\\\\?\")")
    private static let sqNamed = try! NSRegularExpression(pattern: "([\"']?)([A-Za-z][A-Za-z0-9_.\\-]{0,63})\\1(\\s*[:=]\\s*\\\\?')[^'\\\\]{0,8192}(\\\\?')")
    // XML element text: <name>value</name>
    private static let xmlElem = try! NSRegularExpression(pattern: "<([A-Za-z][A-Za-z0-9_.\\-:]{0,63})>[^<]{0,8192}</\\1\\s*>")
    // Bare numeric/bool under a quoted JSON key ("cvv":123) — value-scrubbing skips
    // short digit runs, so a truncated JSON's numeric secret would leak.
    private static let jsonNum = try! NSRegularExpression(pattern: "(\"[A-Za-z][A-Za-z0-9_.\\-]{0,63}\"\\s*:\\s*)(-?\\d[\\d.eE+\\-]{0,40}|true|false)")

    /// Mask values whose adjacent name is sensitive (see note above). Best-effort.
    static func scrubNamedValues(_ s: String) -> String {
        // First: escaped-quote inner literals, so a plain-quote wrapper can't shadow them.
        var out = replaceGroups(escNamed, in: s) { m, ns in
            let name = grp(m, 1, ns)
            guard isSensitiveName(name) else { return ns.substring(with: m.range) }
            return "\(name)\(grp(m, 2, ns))\\\"\(mask)\\\""
        }
        out = replaceGroups(dqNamed, in: out) { m, ns in
            let name = grp(m, 2, ns)
            guard isSensitiveName(name) else { return ns.substring(with: m.range) }
            return "\(grp(m, 1, ns))\(name)\(grp(m, 1, ns))\(grp(m, 3, ns))\(mask)\(grp(m, 4, ns))"
        }
        out = replaceGroups(sqNamed, in: out) { m, ns in
            let name = grp(m, 2, ns)
            guard isSensitiveName(name) else { return ns.substring(with: m.range) }
            return "\(grp(m, 1, ns))\(name)\(grp(m, 1, ns))\(grp(m, 3, ns))\(mask)\(grp(m, 4, ns))"
        }
        out = replaceGroups(xmlElem, in: out) { m, ns in
            let name = grp(m, 1, ns)
            return isSensitiveName(name) ? "<\(name)>\(mask)</\(name)>" : ns.substring(with: m.range)
        }
        out = replaceGroups(jsonNum, in: out) { m, ns in
            let head = grp(m, 1, ns) // `"name"\s*:\s*` — name is between the first two quotes
            guard let a = head.firstIndex(of: "\"") else { return ns.substring(with: m.range) }
            let afterA = head.index(after: a)
            guard let b = head[afterA...].firstIndex(of: "\"") else { return ns.substring(with: m.range) }
            let name = String(head[afterA..<b])
            return isSensitiveName(name) ? "\(head)\(mask)" : ns.substring(with: m.range)
        }
        return out
    }

    static func redactBody(_ body: String) -> String {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let out: String
        if (t.hasPrefix("{") || t.hasPrefix("[")),
           let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let red = try? JSONSerialization.data(withJSONObject: redactJSON(obj), options: []),
           let str = String(data: red, encoding: .utf8) {
            out = scrubValues(str)
        } else if looksFormEncoded(body) {
            out = scrubValues(redactForm(body))
        } else {
            out = scrubValues(body)
        }
        // Net values sensitive by NAME that survived structural + value passes
        // (truncated/XML bodies, GraphQL inline literals). See scrubNamedValues.
        return scrubNamedValues(out)
    }

    private static func redactJSON(_ v: Any) -> Any {
        if let dict = v as? [String: Any] {
            var out = [String: Any]()
            for (k, val) in dict { out[k] = isSensitiveName(k) ? mask : redactJSON(val) }
            return out
        }
        if let arr = v as? [Any] { return arr.map { redactJSON($0) } }
        // A card number sent as a JSON NUMBER → mask as a STRING here, in the typed walk.
        // Otherwise the later scrubValues pass rewrites the bare number to a bareword token
        // in a numeric slot → invalid JSON → downstream drops the ENTIRE event.
        if let n = v as? NSNumber, !isBool(n), !CFNumberIsFloatType(n), Patterns.looksLikePan(String(abs(n.int64Value))) {
            return "[REDACTED-PAN]"
        }
        return v
    }

    private static func looksFormEncoded(_ body: String) -> Bool {
        if !body.contains("=") || body.contains("\n") || body.contains(" ") { return false }
        return body.range(of: "^[^=&]+=[^&]*(?:&[^=&]+=[^&]*)*$", options: .regularExpression) != nil
    }

    private static func redactForm(_ body: String) -> String {
        body.split(separator: "&", omittingEmptySubsequences: false).map { pairSub -> String in
            let pair = String(pairSub)
            guard let eq = pair.firstIndex(of: "="), eq > pair.startIndex else { return pair }
            let key = String(pair[..<eq])
            let name = key.removingPercentEncoding ?? key
            if isSensitiveName(name) { return "\(key)=\(mask)" }
            // Scrub the DECODED value — an encoded value slips past the outer
            // scrub, then projectBody decodes and ships the real secret.
            let rawVal = String(pair[pair.index(after: eq)...])
            let decoded = rawVal.removingPercentEncoding ?? rawVal
            return "\(key)=\(scrubValues(decoded))"
        }.joined(separator: "&")
    }

    // --- safe projection (the annotatable DTO shipped to the server) ---
    private static let projMaxKeys = 512
    private static let projMaxDepth = 12
    private static let projMaxStr = 1024

    /// Project an already-redacted body into `dotted.path -> scalar`, keeping only
    /// analytics scalars. Returns nil when nothing structured/safe remains.
    static func projectBody(_ body: String?) -> String? {
        guard let body = body, !body.isEmpty, let data = body.data(using: .utf8) else { return nil }
        var out = [String: Any]()
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{") || t.hasPrefix("[") {
            guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
            flatten("", obj, &out, 0)
        } else if looksFormEncoded(body) {
            for pairSub in body.split(separator: "&", omittingEmptySubsequences: false) {
                let pair = String(pairSub)
                guard let eq = pair.firstIndex(of: "="), eq > pair.startIndex else { continue }
                let k = String(pair[..<eq]).removingPercentEncoding ?? String(pair[..<eq])
                let v = String(pair[pair.index(after: eq)...]).removingPercentEncoding ?? ""
                putScalar(&out, k, v)
            }
        } else {
            return nil
        }
        if out.isEmpty { return nil }
        guard let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    private static func flatten(_ prefix: String, _ v: Any, _ out: inout [String: Any], _ depth: Int) {
        if out.count >= projMaxKeys || depth > projMaxDepth { return }
        if let dict = v as? [String: Any] {
            for (k, val) in dict {
                if out.count >= projMaxKeys { break }
                flatten(prefix.isEmpty ? k : "\(prefix).\(k)", val, &out, depth + 1)
            }
        } else if let arr = v as? [Any] {
            var i = 0
            while i < arr.count && out.count < projMaxKeys {
                flatten(prefix.isEmpty ? "\(i)" : "\(prefix).\(i)", arr[i], &out, depth + 1); i += 1
            }
        } else if let s = v as? String {
            putScalar(&out, prefix, s)
        } else if v is NSNumber {
            // JSONSerialization gives bool/number as NSNumber — keep as-is.
            out[prefix] = v
        }
        // NSNull / other: skip
    }

    private static func putScalar(_ out: inout [String: Any], _ key: String, _ v: String) {
        if v.isEmpty || v.count > projMaxStr { return }
        if v.hasPrefix("[REDACTED") { return }
        out[key] = v
    }

    // NSRegularExpression replace-with-closure helper (Foundation has no native one).
    private static func replaceAll(_ re: NSRegularExpression, in s: String, _ transform: (String) -> String) -> String {
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return s }
        var result = ""
        var last = 0
        for m in matches {
            let r = m.range
            result += ns.substring(with: NSRange(location: last, length: r.location - last))
            result += transform(ns.substring(with: r))
            last = r.location + r.length
        }
        result += ns.substring(from: last)
        return result
    }

    // Same as replaceAll but exposes capture groups to the transform.
    private static func replaceGroups(_ re: NSRegularExpression, in s: String, _ transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return s }
        var result = ""
        var last = 0
        for m in matches {
            let r = m.range
            result += ns.substring(with: NSRange(location: last, length: r.location - last))
            result += transform(m, ns)
            last = r.location + r.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func grp(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> String {
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : ns.substring(with: r)
    }
}
