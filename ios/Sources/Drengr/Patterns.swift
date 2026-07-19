import Foundation

/// Patterns.swift — the single source of truth for PII/secret VALUE detection, shared by
/// Redact.swift (masks via replace) and Classify.swift (detects via firstMatch). Port of
/// patterns.ts. One definition here means a hardening fix can never land in one file and
/// be missed in the other — the drift that silently reopens a leak. NSRegularExpression is
/// stateless per match (no /g lastIndex concern), so both callers reference the SAME
/// compiled object; each pattern is compiled once here.
enum Patterns {
    private static let normalizeChars = CharacterSet(charactersIn: "_-$@. \t\n")

    /// Normalize a field/header/query name for set + fragment matching: lowercase, strip separators.
    static func norm(_ name: String) -> String {
        name.lowercased().components(separatedBy: normalizeChars).joined()
    }

    // --- value patterns (bounded quantifiers throughout → no ReDoS) ---
    // Bounded RFC-5321 lengths — an UNbounded local part backtracks O(n²) hunting for '@'
    // on a long no-'@' run (a 64KB body froze the app ~2s; ICU backtracking is worse than
    // V8's, so the bound matters more here).
    static let emailRe = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,255}\\.[A-Za-z]{2,24}")
    static let ssnRe = try! NSRegularExpression(pattern: "\\b\\d{3}-\\d{2}-\\d{4}\\b")
    static let phoneRe = try! NSRegularExpression(pattern: "(?:\\+\\d{1,3}[ .-]?)?\\(?\\d{3}\\)?[ .-]\\d{3}[ .-]\\d{4}\\b")
    static let e164Re = try! NSRegularExpression(pattern: "\\+[1-9]\\d{7,14}\\b")
    static let ipv4Re = try! NSRegularExpression(pattern: "\\b(?:(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)\\b")
    // IPv6: require ≥4 hextet groups OR a '::' — the old {2,7} matched HH:MM:SS times and
    // version triplets and redacted them as IPs (destroyed real duration signal).
    static let ipv6Re = try! NSRegularExpression(pattern: "\\b(?:[A-Fa-f0-9]{1,4}:){3,7}[A-Fa-f0-9]{1,4}\\b|\\b(?:[A-Fa-f0-9]{1,4}:){1,7}:[A-Fa-f0-9]{0,4}")
    static let macRe = try! NSRegularExpression(pattern: "\\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\\b")
    static let uuidRe = try! NSRegularExpression(pattern: "\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b") // IDFA/GAID
    // 13+ digits with optional single space/dash separators between digits.
    static let digitRunRe = try! NSRegularExpression(pattern: "[0-9](?:[ -]?[0-9]){11,}")
    static let ibanRe = try! NSRegularExpression(pattern: "\\b[A-Z]{2}\\d{2}[A-Z0-9]{11,30}\\b")
    // Only unambiguous wallet forms: ETH 0x+40hex, BTC bech32 (bc1…). Legacy base58 was
    // dropped — it false-matched base58 order/transaction IDs and destroyed them.
    static let cryptoRe = try! NSRegularExpression(pattern: "\\b(?:0x[a-fA-F0-9]{40}|bc1[a-z0-9]{25,62})\\b")

    // --- credential patterns ---
    static let jwtRe = try! NSRegularExpression(pattern: "eyJ[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]*")
    static let bearerRe = try! NSRegularExpression(pattern: "[Bb]earer\\s+[A-Za-z0-9\\-._~+/]+=*")
    static let secretTokenRe = try! NSRegularExpression(pattern: "\\b(?:(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[opusr]_[A-Za-z0-9]{36,}|xox[baprs]-[A-Za-z0-9-]{10,})\\b")
    // Two PEM forms on purpose: redact replaces the whole BEGIN…END block; classify needs
    // only BEGIN to DETECT (so a truncated key still DROPs rather than sealing/leaking).
    static let pemBlockRe = try! NSRegularExpression(pattern: "-----BEGIN[A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?-----END[A-Z0-9 ]*PRIVATE KEY-----")
    static let pemDetectRe = try! NSRegularExpression(pattern: "-----BEGIN[A-Z0-9 ]*PRIVATE KEY-----")

    // --- checksum primitives ---
    private static let ibanFullRe = try! NSRegularExpression(pattern: "^[A-Z]{2}\\d{2}[A-Z0-9]{11,30}$")

    /// ISO 7064 MOD-97-10 (the IBAN check) — a published standard, re-implemented here
    /// (never copied from a copyleft library). Move the first 4 chars to the end, map
    /// A–Z→10..35 (each letter is TWO digits) and 0–9→one digit, reduce mod 97; a valid
    /// IBAN yields 1. Returns -1 on a stray char.
    static func mod97(_ iban: String) -> Int {
        let chars = Array(iban.unicodeScalars)
        let reordered = chars.count >= 4 ? Array(chars[4...]) + Array(chars[0..<4]) : chars
        var rem = 0
        for c in reordered {
            let v = c.value
            if v >= 65 && v <= 90 { rem = (rem * 100 + Int(v) - 55) % 97 } // A–Z → two digits
            else if v >= 48 && v <= 57 { rem = (rem * 10 + Int(v) - 48) % 97 } // 0–9 → one digit
            else { return -1 }
        }
        return rem
    }

    /// An IBAN only if it matches the format AND passes mod-97 — the checksum is what
    /// lets us redact real IBANs without destroying lookalike business identifiers.
    static func isIbanValue(_ s: String) -> Bool {
        let ns = s as NSString
        guard ibanFullRe.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil else { return false }
        return mod97(s) == 1
    }

    /// Luhn (mod-10) check over a pure-digit string of length ≥13.
    static func luhn(_ digits: String) -> Bool {
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

    /// A pure-digit string that looks like a card number: a Luhn-valid 13–19 run, or a
    /// suspiciously long (>40) run. Shared by the string scrubber and the JSON walker so
    /// a numeric PAN is caught before it can break the body's JSON.
    static func looksLikePan(_ digits: String) -> Bool {
        if digits.count > 40 { return true }
        let chars = Array(digits)
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
}
