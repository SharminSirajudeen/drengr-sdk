import Foundation

/// Seal-by-default body splitter (port of classify.ts). One pass over a captured
/// body splits every leaf into DROP (credentials/PCI -> [REDACTED-*], never stored),
/// SEAL (PII/unknown free-text -> raw into piiMap, typed placeholder into projection),
/// or KEEP (business signal -> plaintext). Typed placeholders keep leaf type stable.
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
    private static let normalizeChars = CharacterSet(charactersIn: "_-$@. \t\n")
    private static func norm(_ name: String) -> String {
        name.lowercased().components(separatedBy: normalizeChars).joined()
    }

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
    private static let credRes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "eyJ[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]*"),
        try! NSRegularExpression(pattern: "[Bb]earer\\s+[A-Za-z0-9\\-._~+/]+=*"),
        try! NSRegularExpression(pattern: "\\b(?:(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[opusr]_[A-Za-z0-9]{36,}|xox[baprs]-[A-Za-z0-9-]{10,})\\b"),
        try! NSRegularExpression(pattern: "-----BEGIN[A-Z0-9 ]*PRIVATE KEY-----"),
    ]
    private static let emailRe = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    private static let ssnRe = try! NSRegularExpression(pattern: "\\b\\d{3}-\\d{2}-\\d{4}\\b")
    private static let phoneRe = try! NSRegularExpression(pattern: "(?:\\+\\d{1,3}[ .-]?)?\\(?\\d{3}\\)?[ .-]\\d{3}[ .-]\\d{4}\\b")
    private static let ipv4Re = try! NSRegularExpression(pattern: "\\b(?:(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)\\b")
    private static let ipv6Re = try! NSRegularExpression(pattern: "\\b(?:[A-Fa-f0-9]{1,4}:){2,7}[A-Fa-f0-9]{0,4}\\b")
    private static let uuidRe = try! NSRegularExpression(pattern: "\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b")
    private static let digitRunRe = try! NSRegularExpression(pattern: "[0-9](?:[ -]?[0-9]){11,}")
    private static let doubleSpaceRe = try! NSRegularExpression(pattern: "\\s{2,}")

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    private static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func luhn(_ digits: String) -> Bool {
        if digits.count < 13 { return false }
        var sum = 0
        var alt = false
        for ch in digits.reversed() {
            guard let d = ch.wholeNumberValue, d >= 0, d <= 9 else { return false }
            var n = d
            if alt { n *= 2; if n > 9 { n -= 9 } }
            sum += n
            alt.toggle()
        }
        return sum % 10 == 0
    }

    private static func credentialValue(_ s: String) -> Bool {
        credRes.contains { matches($0, s) }
    }

    private static func panValue(_ s: String) -> Bool {
        let ns = s as NSString
        guard let m = digitRunRe.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return false }
        let d = ns.substring(with: m.range).replacingOccurrences(of: "[ -]", with: "", options: .regularExpression)
        if d.count > 40 { return true }
        let chars = Array(d)
        var len = 13
        while len <= 19 && len <= chars.count {
            var i = 0
            while i + len <= chars.count {
                if luhn(String(chars[i..<(i + len)])) { return true }
                i += 1
            }
            len += 1
        }
        return false
    }

    private static func piiKind(_ s: String) -> String? {
        if matches(emailRe, s) { return "email" }
        if matches(ssnRe, s) { return "ssn" }
        if matches(phoneRe, s) { return "phone" }
        if matches(ipv4Re, s) || matches(ipv6Re, s) { return "ip" }
        if matches(uuidRe, s) { return "deviceid" }
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
        let n = norm(key)
        if let s = v as? String, credentialValue(s) || panValue(s) { return .drop(sameTyped(v, "[REDACTED-SECRET]")) }
        if credentialNames.contains(n) { return .drop(sameTyped(v, "[REDACTED-SECRET]")) }

        if let s = v as? String, let vk = piiKind(s) { return .seal("[PII:\(vk)]", jsonRaw(v), path) }
        if piiNames.contains(n) { return .seal(sameTyped(v, "[PII:\(n)]"), jsonRaw(v), path) }

        if v is NSNumber { return .keep(v) }

        if let s = v as? String {
            if s.isEmpty { return .keep(s) }
            if s.count > maxStr { return .drop("[FREETEXT:len=\(s.count)]") }
            if businessAllowlist.contains(n), s.count <= 64, !matches(doubleSpaceRe, s) { return .keep(s) }
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
