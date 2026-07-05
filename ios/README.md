# Drengr iOS SDK

Zero-code network analytics for iOS — one call captures every URLSession exchange
(secret/PII redaction in-process), no `track()` calls.

```swift
import Drengr

Drengr.start(
    publishableKey: "drengr_pk_…",                                  // from drengr.dev/pro (embed-safe)
    ingestURL: "https://<ref>.supabase.co/functions/v1/ingest",
    appPackage: "com.example.app"
)
```

Passive capture across **all** sessions automatically — `URLSession.shared`, `.default`,
custom configs, Alamofire, async/await — no per-session registration. It only *observes*
(method-swizzled), never re-issues, so your certificate pinning / auth-challenge delegate
runs untouched. Metadata (method/url/status/timing/bytes) is exact for every request;
response bodies are captured for completion-handler tasks. Redaction is on by default;
delivery uses a separate session it never observes, so it can't self-capture. Consent gate:
`Drengr.start(..., startEnabled: false)` then `Drengr.setEnabled(true)`; persistent opt-out:
`Drengr.optOut()` / `Drengr.optIn()`.

Install: **SwiftPM** (add this package) or **CocoaPods** (`pod 'Drengr'`).
