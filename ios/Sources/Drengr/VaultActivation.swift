import Foundation

/// Turn on the E2EE PII vault. Until the org's signed config is fetched AND
/// verifies against the PINNED signer, sealing stays off (placeholders only).
public struct VaultOptions {
    /// base64 Ed25519 public key from `drengr-vault keygen` — the pin.
    public let signPubKey: String
    /// The org id (tenant) this SDK reports under; the config is bound to it.
    public let tenantId: String
    /// Override the config endpoint (defaults to the ingest host's /vault-pubkey).
    public let pubkeyUrl: String?

    public init(signPubKey: String, tenantId: String, pubkeyUrl: String? = nil) {
        self.signPubKey = signPubKey
        self.tenantId = tenantId
        self.pubkeyUrl = pubkeyUrl
    }
}

/// Fetch the org's signed vault config, verify it against the PINNED signer, and
/// activate sealing (port of JS configureVault). Every failure path leaves the
/// sink fail-closed — no sealing, placeholders only, never a throw into the app.
enum VaultActivation {
    static let epochKey = "drengr_vault_epoch"

    static func configure(sink: IngestSink, options: VaultOptions, ingestURL: String,
                          publishableKey: String, session: URLSession,
                          defaults: UserDefaults = .standard) {
        guard let url = pubkeyURL(options.pubkeyUrl, ingestURL: ingestURL) else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code), let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cfg = obj["config"] as? [String: Any],
                  let signed = parseSigned(cfg) else { return }
            apply(signed, options: options, sink: sink, defaults: defaults)
        }
        URLSessionCapture.markInternal(task)
        task.resume()
    }

    /// Resolve + activate, separated from the fetch so tests drive it directly.
    /// nil = fail-closed (bad signature / downgrade / expired / wrong tenant).
    @discardableResult
    static func apply(_ signed: SignedVaultConfig, options: VaultOptions, sink: IngestSink,
                      now: Date = Date(), defaults: UserDefaults = .standard) -> VaultConfig? {
        guard let pin = Data(base64Encoded: options.signPubKey) else { return nil }
        let lastEpoch = defaults.object(forKey: epochKey) as? Int ?? -1
        guard let cfg = Vault.resolveVaultConfig(signed, pinnedSignPub: pin,
                                                 tenantId: options.tenantId,
                                                 now: now, lastEpoch: lastEpoch) else { return nil }
        sink.setVault(cfg)
        defaults.set(signed.epoch, forKey: epochKey)
        return cfg
    }

    static func pubkeyURL(_ override: String?, ingestURL: String) -> URL? {
        if let o = override { return URL(string: o) }
        return URL(string: ingestURL.replacingOccurrences(
            of: "/ingest/?$", with: "/vault-pubkey", options: .regularExpression))
    }

    static func parseSigned(_ o: [String: Any]) -> SignedVaultConfig? {
        guard let orgId = o["org_id"] as? String,
              let kid = o["kid"] as? String,
              let alg = o["alg"] as? String,
              let orgPub = o["org_pub"] as? String,
              let pepper = o["pepper"] as? String,
              let notBefore = o["not_before"] as? String,
              let epoch = o["epoch"] as? Int,
              let signPub = o["sign_pub"] as? String,
              let signature = o["signature"] as? String else { return nil }
        return SignedVaultConfig(org_id: orgId, kid: kid, alg: alg, org_pub: orgPub,
                                 pepper: pepper, not_before: notBefore,
                                 expires_at: o["expires_at"] as? String,
                                 epoch: epoch, sign_pub: signPub, signature: signature)
    }
}
