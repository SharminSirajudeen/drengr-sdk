import Foundation
import CryptoKit

/// subject_hash join key (port of identity.ts):
/// 'sh_' + base64url(HMAC-SHA256(orgPepper, normalize(external_id))), no padding.
enum Identity {
    /// Deterministic normalization: trim + lowercase. Deliberately minimal —
    /// over-normalizing would collapse distinct subjects into one.
    static func normalizeExternalId(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func subjectHash(pepper: Data, externalId: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(normalizeExternalId(externalId).utf8),
            using: SymmetricKey(data: pepper)
        )
        return "sh_" + base64url(Data(mac))
    }

    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
