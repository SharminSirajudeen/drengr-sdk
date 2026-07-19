import Foundation
import CryptoKit

/// Resolved, verified vault config the sink seals under.
struct VaultConfig {
    let orgPubKey: Data
    let kid: String
    let orgPepper: Data
    let tenantId: String
}

/// The org's Ed25519-signed config (port of vault-config.ts). Signed payload =
/// JSON of the sorted keys [alg,epoch,expires_at,kid,not_before,org_id,org_pub,pepper].
struct SignedVaultConfig {
    let org_id: String
    let kid: String
    let alg: String
    let org_pub: String
    let pepper: String
    let not_before: String
    let expires_at: String?
    let epoch: Int
    let sign_pub: String
    let signature: String
}

enum Vault {
    static func canonicalConfigPayload(_ c: SignedVaultConfig) -> String {
        let expires = c.expires_at.map { Canon.string($0) } ?? "null"
        return "{\"alg\":" + Canon.string(c.alg)
            + ",\"epoch\":" + String(c.epoch)
            + ",\"expires_at\":" + expires
            + ",\"kid\":" + Canon.string(c.kid)
            + ",\"not_before\":" + Canon.string(c.not_before)
            + ",\"org_id\":" + Canon.string(c.org_id)
            + ",\"org_pub\":" + Canon.string(c.org_pub)
            + ",\"pepper\":" + Canon.string(c.pepper) + "}"
    }

    static func verifyConfig(_ signed: SignedVaultConfig, pinnedSignPub: Data) -> Bool {
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pinnedSignPub),
              let sig = Data(base64Encoded: signed.signature) else { return false }
        return pub.isValidSignature(sig, for: Data(canonicalConfigPayload(signed).utf8))
    }

    /// Fail-closed resolver: returns a VaultConfig ONLY when the signed config
    /// verifies against the pinned org key, is bound to this tenant, is not an
    /// epoch downgrade, and is inside its validity window. Any failure → nil
    /// (the sink seals nothing — typed placeholders only, no PII leaked).
    static func resolveVaultConfig(_ signed: SignedVaultConfig, pinnedSignPub: Data,
                                   tenantId: String, now: Date, lastEpoch: Int = -1) -> VaultConfig? {
        guard verifyConfig(signed, pinnedSignPub: pinnedSignPub) else { return nil }
        guard signed.org_id == tenantId else { return nil }
        guard signed.epoch >= lastEpoch else { return nil }
        if let nb = parseISO(signed.not_before), now < nb { return nil }
        if let ex = signed.expires_at, let exd = parseISO(ex), now > exd { return nil }
        guard signed.alg == "hpke-x25519" else { return nil }
        guard let pub = Data(base64Encoded: signed.org_pub),
              let pep = Data(base64Encoded: signed.pepper) else { return nil }
        return VaultConfig(orgPubKey: pub, kid: signed.kid, orgPepper: pep, tenantId: tenantId)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func parseISO(_ s: String) -> Date? {
        iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
