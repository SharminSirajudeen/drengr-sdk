import Foundation

/// Seal-by-default body splitter (port of classify.ts). One pass over a captured
/// body splits every leaf into DROP (credentials/PCI -> [REDACTED-*], never stored),
/// SEAL (PII/unknown free-text -> raw into piiMap, typed placeholder into projection),
/// or KEEP (business signal: numbers/bools whose NAME doesn't read as PII, single-token
/// allowlisted enums -> plaintext). Typed placeholders keep leaf type stable.
/// GUARANTEE (honest scope): every free-text/spaced string, and every value matching a
/// PII PATTERN, seals by default; a value whose NAME hints PII seals even as a number.
/// The one residual is a BARE NUMBER under a name that gives no hint it is PII (a raw
/// coordinate named "x") — genuinely ambiguous, best-effort, not "never".
/// piiMap is collected for the (future) encrypt layer; only `projection` ships today.
enum Classify {
    struct Classified {
        let projection: String?
        let piiMap: [String: String]
        let piiPaths: [String]
    }

    private static let maxKeys = 512
    private static let maxDepth = 12
    private static let maxStr = 1024

    // DROP — pure secrets + PCI card data.
    private static let credentialNames: Set<String> = [
        "password", "passwd", "pwd", "pass", "passphrase", "secret", "clientsecret", "token",
        "apikey", "apisecret", "accesstoken", "refreshtoken", "idtoken", "oauthtoken", "bearertoken",
        "privatekey", "secretkey", "sessiontoken", "authorization", "auth", "otp", "totp",
        "csrf", "xsrf", "csrftoken", "xsrftoken",
        "cvv", "cvc", "cvv2", "csc", "pin", "cardnumber", "cardno", "ccnumber", "creditcard", "pan",
    ]

    // SEAL — PII the tenant may want decrypted, but Drengr must not.
    private static let piiNames: Set<String> = [
        "email", "phone", "mobile", "tel", "telephone", "fax",
        "firstname", "lastname", "middlename", "fullname", "username", "nickname",
        "customername", "recipientname", "sendername", "contactname",
        "ssn", "sin", "iban", "accountnumber", "routingnumber", "sortcode",
        "passport", "nationality", "dob", "dateofbirth", "birthdate",
        "address", "street", "zip", "zipcode", "postal", "postalcode",
        "lat", "latitude", "lng", "lon", "longitude", "geo", "coordinates",
        "ip", "ipaddress", "deviceid", "idfa", "gaid", "adid", "imei", "macaddress",
        "promocode", "promotioncode", "coupon", "giftmessage", "messagetext",
    ]

    // KEEP — business signal the discovery engine names events from.
    private static let businessAllowlist: Set<String> = [
        "status", "statuscode", "httpstatus", "responsecode", "code", "state", "result", "outcome",
        "declinereason", "declinecode", "reason", "errorcode",
        "currency", "amount", "price", "total", "subtotal", "tax", "shipping", "discount", "fee",
        "balance", "cost", "revenue", "quantity", "qty", "count",
        "sku", "productid", "itemid", "variantid", "orderid", "transactionid", "paymentid", "invoiceid",
        "plan", "planid", "tier", "type", "kind", "category", "subcategory",
        "event", "eventname", "action", "method", "httpmethod", "verb",
        "success", "ok", "enabled", "active", "error",
        "duration", "latency", "elapsed", "level", "score", "rating", "stars",
        "version", "appversion", "build", "step", "index", "page", "pagesize", "limit", "offset",
    ]

    // --- value detectors ---
    // The credential/PII value patterns + checksum primitives live in Patterns.swift,
    // shared with Redact so a hardening fix can't land in one file and miss the other.
    // credRes uses pemDetectRe (BEGIN prefix only) so a TRUNCATED private key still DROPs.
    private static let credRes: [NSRegularExpression] = [
        Patterns.jwtRe, Patterns.bearerRe, Patterns.secretTokenRe, Patterns.pemDetectRe,
    ]
    // Any whitespace at all — the single-token KEEP gate. A spaced/prose value under a
    // business-allowlisted name ("Jane Doe") is free-text PII, not an enum, so it seals.
    // Classify-only (not a PII value detector), so it stays here.
    private static let whitespaceRe = try! NSRegularExpression(pattern: "\\s")
    // Long, low-false-positive PII name fragments — a field whose NAME contains one seals
    // even a NUMERIC value (a national/tax id or geo coord sent as a number would otherwise
    // KEEP as a measure). Only long unambiguous tokens — never 'lat'/'ip' (→ 'latency'/'flip').
    private static let piiNameFragments: [String] = [
        "latitude", "longitude", "nationalid", "taxid", "passport", "driverlicense", "driverslicense",
        "socialsecurity", "accountnumber", "routingnumber", "creditcard", "cardnumber", "dateofbirth",
    ]
    private static func nameLooksPii(_ n: String) -> Bool {
        piiNameFragments.contains { n.contains($0) }
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    private static func firstMatchString(_ re: NSRegularExpression, _ s: String) -> String? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }

    private static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func credentialValue(_ s: String) -> Bool {
        credRes.contains { matches($0, s) }
    }

    private static func panValue(_ s: String) -> Bool {
        let ns = s as NSString
        guard let m = Patterns.digitRunRe.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return false }
        let d = ns.substring(with: m.range).replacingOccurrences(of: "[ -]", with: "", options: .regularExpression)
        return Patterns.looksLikePan(d)
    }

    private static func piiKind(_ s: String) -> String? {
        if matches(Patterns.emailRe, s) { return "email" }
        if matches(Patterns.ssnRe, s) { return "ssn" }
        if matches(Patterns.phoneRe, s) || matches(Patterns.e164Re, s) { return "phone" }
        if matches(Patterns.macRe, s) { return "macaddress" } // before ip: the loose ipv6 regex also matches a MAC
        if matches(Patterns.ipv4Re, s) || matches(Patterns.ipv6Re, s) { return "ip" }
        if matches(Patterns.uuidRe, s) { return "deviceid" }
        if let ib = firstMatchString(Patterns.ibanRe, s), Patterns.isIbanValue(ib) { return "iban" }
        if matches(Patterns.cryptoRe, s) { return "wallet" }
        return nil
    }

    private static func sameTyped(_ v: Any, _ label: String) -> Any {
        if let n = v as? NSNumber { return isBool(n) ? false : 0 }
        return label
    }

    private static func jsonRaw(_ v: Any) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: [v], options: []),
           let s = String(data: d, encoding: .utf8), s.count >= 2 {
            return String(s.dropFirst().dropLast())
        }
        return "null"
    }

    private enum Disp {
        case keep(Any)
        case drop(Any)
        case seal(Any, String, String)
    }

    private static func classifyLeaf(_ key: String, _ path: String, _ v: Any) -> Disp {
        let n = Patterns.norm(key)
        // 1. hard credentials (value or name) -> DROP (never sealed, never recoverable).
        if let s = v as? String, credentialValue(s) { return .drop(sameTyped(v, "[REDACTED-SECRET]")) }
        if credentialNames.contains(n) { return .drop(sameTyped(v, "[REDACTED-SECRET]")) }

        // 1b. oversized free text -> DROP before any value regex runs on it. The value
        //     patterns are bounded, but a huge leaf is never business signal, and this
        //     keeps the classifier's own passes cheap on a pathological body.
        if let s = v as? String, s.count > maxStr { return .drop("[FREETEXT:len=\(s.count)]") }

        // 2. a recognized PII KIND by value -> SEAL. Runs before the generic PAN drop
        //    so a recoverable-PII value (e.g. an IBAN) isn't mis-dropped as a card by a
        //    coincidental Luhn substring — a real card is not a piiKind, so it still drops below.
        if let s = v as? String, let vk = piiKind(s) { return .seal("[PII:\(vk)]", jsonRaw(v), path) }

        // 3. card-shaped digit run -> DROP (PCI: worthless as analytics, dangerous even sealed).
        if let s = v as? String, panValue(s) { return .drop(sameTyped(v, "[REDACTED-SECRET]")) }

        // 4. PII by NAME -> SEAL. Exact PII name, OR a long PII name-fragment so a national/
        //    tax id or geo coordinate sent as a NUMBER seals instead of KEEPing as a measure.
        if piiNames.contains(n) || nameLooksPii(n) { return .seal(sameTyped(v, "[PII:\(n)]"), jsonRaw(v), path) }

        // 5. numbers / booleans that survived credential+PII checks are business signal -> KEEP
        if v is NSNumber { return .keep(v) }

        // 6. strings: an allowlisted SINGLE-TOKEN enum -> KEEP; everything else seals. The
        //    no-whitespace gate closes the plaintext-name leak — a spaced/prose value
        //    ("Jane Doe", "call John back") under a business name now seals, not KEEPs.
        if let s = v as? String {
            if s.isEmpty { return .keep(s) }
            if businessAllowlist.contains(n), s.count <= 64, !matches(whitespaceRe, s) { return .keep(s) }
            return .seal("[PII]", jsonRaw(v), path)
        }
        return .drop(sameTyped(v, "[REDACTED]"))
    }

    static func classifyBody(_ body: String?) -> Classified {
        let empty = Classified(projection: nil, piiMap: [:], piiPaths: [])
        guard let body = body, !body.isEmpty else { return empty }
        guard let decoded = parseJson(body) ?? parseForm(body) else { return empty }

        var proj = [String: Any]()
        var piiMap = [String: String]()
        var piiPaths = [String]()
        walk("", "", decoded, 0, &proj, &piiMap, &piiPaths)

        if proj.isEmpty { return empty }
        guard let d = try? JSONSerialization.data(withJSONObject: proj, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return empty }
        return Classified(projection: s, piiMap: piiMap, piiPaths: piiPaths)
    }

    private static func walk(_ prefix: String, _ key: String, _ v: Any, _ depth: Int,
                             _ proj: inout [String: Any], _ piiMap: inout [String: String],
                             _ piiPaths: inout [String]) {
        if proj.count >= maxKeys || depth > maxDepth { return }
        if let arr = v as? [Any] {
            var i = 0
            while i < arr.count && proj.count < maxKeys {
                walk(prefix.isEmpty ? "\(i)" : "\(prefix).\(i)", key, arr[i], depth + 1, &proj, &piiMap, &piiPaths)
                i += 1
            }
            return
        }
        if let dict = v as? [String: Any] {
            for (k, val) in dict where proj.count < maxKeys {
                walk(prefix.isEmpty ? k : "\(prefix).\(k)", k, val, depth + 1, &proj, &piiMap, &piiPaths)
            }
            return
        }
        if v is NSNull { return }
        switch classifyLeaf(key, prefix, v) {
        case .keep(let x): proj[prefix] = x
        case .drop(let x): proj[prefix] = x
        case .seal(let ph, let raw, let path):
            proj[prefix] = ph
            piiMap[path] = raw
            piiPaths.append(path)
        }
    }

    private static func parseJson(_ body: String) -> Any? {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("["), let data = body.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func parseForm(_ body: String) -> Any? {
        if !body.contains("=") || body.contains("\n") || body.contains(" ") { return nil }
        if body.range(of: "^[^=&]+=[^&]*(?:&[^=&]+=[^&]*)*$", options: .regularExpression) == nil { return nil }
        var map = [String: Any]()
        for pairSub in body.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = String(pairSub)
            guard let eq = pair.firstIndex(of: "="), eq > pair.startIndex else { continue }
            let k = String(pair[..<eq])
            let v = String(pair[pair.index(after: eq)...])
            let key = k.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? k
            let val = v.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? v
            map[key] = val
        }
        return map.isEmpty ? nil : map
    }
}
