import Foundation
import CryptoKit

/// The E2EE PII-vault envelope (port of seal.ts) over CryptoKit's RFC 9180 HPKE:
/// DHKEM(X25519,HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM, base mode. The sealed
/// plaintext binds {subject_hash, seal_ulid, body_hash} so a transplanted/forged
/// envelope fails to open; the map is length-padded to a fixed bucket.
struct VaultEnvelope {
    let pii_alg: String   // "hpke-x25519"
    let kid: String
    let enc: String       // base64 encapsulated key
    let ct: String        // base64 ciphertext‖tag
}

struct SealContext {
    let subjectHash: String
    let sealUlid: String
    let bodyHash: String
    let tenantId: String
}

/// Minimal JSON string escaper matching JS JSON.stringify (canonical payload bytes).
enum Canon {
    static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{09}": out += "\\t"
            case "\u{0A}": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\u{0D}": out += "\\r"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}

enum Seal {
    static let vaultInfo = Data("drengr-vault-v1".utf8)
    private static let buckets = [128, 256, 512, 1024, 2048, 4096]

    // DHKEM(X25519,HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM — CryptoKit ships no
    // X25519+AES-GCM preset, so build it from primitives (RFC 9180 §7).
    @available(iOS 17, macOS 14, tvOS 17, *)
    static let suite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)

    // --- fixed-bucket length padding (4-byte big-endian length prefix) ---
    private static func bucketSize(_ n: Int) -> Int {
        for b in buckets where n <= b { return b }
        return ((n + 4095) / 4096) * 4096
    }

    static func pad(_ data: Data) -> Data {
        var out = Data(count: bucketSize(4 + data.count))
        let n = UInt32(data.count)
        out[0] = UInt8((n >> 24) & 0xff)
        out[1] = UInt8((n >> 16) & 0xff)
        out[2] = UInt8((n >> 8) & 0xff)
        out[3] = UInt8(n & 0xff)
        out.replaceSubrange(4..<(4 + data.count), with: data)
        return out
    }

    static func unpad(_ padded: Data) -> Data? {
        let b = [UInt8](padded)
        guard b.count >= 4 else { return nil }
        let len = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        guard len >= 0, len <= b.count - 4 else { return nil }
        return Data(b[4..<(4 + len)])
    }

    // --- canonical sealed plaintext ---
    private static func canonicalMap(_ m: [String: String]) -> String {
        // values are already raw JSON fragments (classifier's jsonRaw output).
        "{" + m.keys.sorted().map { Canon.string($0) + ":" + m[$0]! }.joined(separator: ",") + "}"
    }

    static func plaintext(_ piiMap: [String: String], _ ctx: SealContext) -> String {
        "{\"v\":1,\"sh\":" + Canon.string(ctx.subjectHash)
            + ",\"su\":" + Canon.string(ctx.sealUlid)
            + ",\"bh\":" + Canon.string(ctx.bodyHash)
            + ",\"m\":" + canonicalMap(piiMap) + "}"
    }

    @available(iOS 17, macOS 14, tvOS 17, *)
    static func sealPii(_ piiMap: [String: String], ctx: SealContext, orgPubKey: Data, kid: String) -> VaultEnvelope? {
        if piiMap.isEmpty { return nil }
        guard let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: orgPubKey),
              var sender = try? HPKE.Sender(recipientKey: pub, ciphersuite: suite, info: vaultInfo)
        else { return nil }
        let aad = Data((ctx.tenantId + "|" + kid).utf8)
        guard let ct = try? sender.seal(pad(Data(plaintext(piiMap, ctx).utf8)), authenticating: aad) else { return nil }
        return VaultEnvelope(pii_alg: "hpke-x25519", kid: kid,
                             enc: sender.encapsulatedKey.base64EncodedString(),
                             ct: ct.base64EncodedString())
    }

    @available(iOS 17, macOS 14, tvOS 17, *)
    static func openPii(_ env: VaultEnvelope, orgPrivKey: Data, orgPubKey: Data, ctx: SealContext) -> [String: Any]? {
        guard let enc = Data(base64Encoded: env.enc), let ct = Data(base64Encoded: env.ct),
              let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: orgPrivKey),
              var recip = try? HPKE.Recipient(privateKey: priv, ciphersuite: suite,
                                              info: vaultInfo, encapsulatedKey: enc)
        else { return nil }
        let aad = Data((ctx.tenantId + "|" + env.kid).utf8)
        guard let padded = try? recip.open(ct, authenticating: aad), let raw = unpad(padded),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let sh = obj["sh"] as? String, let su = obj["su"] as? String,
              let bh = obj["bh"] as? String, let m = obj["m"] as? [String: Any]
        else { return nil }
        guard sh == ctx.subjectHash, su == ctx.sealUlid, bh == ctx.bodyHash else { return nil }
        return m
    }
}
