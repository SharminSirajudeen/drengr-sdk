# Changelog

## 0.4.0

Behavior capture (screens, taps, crashes) — the SDK is no longer network-only.

- `screen_view` via `Drengr.navigatorObserver` (a `RouteObserver`): push /
  replace / pop-reveal, named routes or route runtimeType fallback.
- `tap` via a global pointer route (zero per-widget integration): semantic
  label (Semantics label > widget key > button/text content > runtimeType),
  normalized 0–1 coordinates, current screen. Labels are redacted + capped
  on device.
- `rage_tap` (≥3 taps / 600 ms / 24 px / same label, once per burst) and
  `dead_tap` (no interactive handler on the hit-path).
- `crash` via chained `FlutterError.onError` + `PlatformDispatcher.onError`
  (existing handlers preserved, errors never swallowed); ships exception type
  + first stack frame only — never the message.
- All behavior events flow through the existing sink/envelope (batching,
  durability, session rotation, consent gate). `Drengr.start(behavior: false)`
  opts out. Requires Flutter ≥3.16.

## 0.3.0

The one-liner ships data.

- `Drengr.start(publishableKey:, ingestUrl:, appPackage:)` now builds the
  delivery sink internally: persistent `install_id` (shared_preferences, with
  a file fallback), rotating `session_id` (30 min idle / 24 h max age — the
  old session's queue is flushed before rotation), and full app context on
  every envelope. The advanced `onEvent`/`IngestSink` API is unchanged and an
  explicit `onEvent` wins over the auto sink.
- New facade: `Drengr.identify()`, `Drengr.setExperiment()`, `Drengr.flush()`
  — all safe no-ops when no sink is configured. Auto-flush on app background.
- Net events now carry `req_headers`/`resp_headers` (already-redacted, ≤48
  entries, ≤8 KB per side).
- Hardening: event emission moved off the request path (microtask-drained
  queue); `Drengr.installInIsolate()` for spawned isolates;
  `Drengr.wrapClient()` for Dio custom-client configs; payment-ish paths
  (`/payment`, `/checkout`, `/card`) no longer capture bodies unless opted in;
  `sampleRate` for high-volume apps.
- The package now depends on Flutter (shared_preferences + lifecycle
  observer). Pure `dart:io` capture still works in plain Dart VMs.

## 0.2.2

Security and stability fixes.

- Redaction: mask values that are sensitive by field NAME even when a body can't
  be parsed structurally — JSON truncated past the size cap, XML/SOAP, or GraphQL
  inline literals. Previously a plaintext `password`/`otp`/PII under its own name
  could slip value-only scrubbing in those bodies.
- Redaction: scrub free-text PII (email/SSN/phone) and form-encoded values by
  pattern in any field or URL path; scrub opaque vendor secrets (Stripe/AWS/GCP/
  GitHub/Slack) sitting under a benign key. Publishable keys (`pk_…`) are kept.
- Delivery: bound streaming reads so a large/infinite response body can't OOM;
  stop retrying on 4xx (client errors are permanent); fix a consent-check leak on
  the synchronous path.
- Fix a persist-scheduler microtask starvation where a burst of captured events
  (e.g. a screen firing several concurrent requests) could freeze the isolate.

## 0.2.1

- Envelopes carry `sent_at_ms` (device clock at send): the ingest server derives
  the device clock error per batch and corrects event timeline placement exactly
  — a device with a wrong clock can no longer shift where events appear.

## 0.2.0

- Export `IngestSink`: batched, retrying, disk-persisted delivery of captured
  network events to the Drengr ingest endpoint (publishable-key auth). This is
  the documented one-liner: `Drengr.start(onEvent: sink.addNetwork)`.

## 0.1.1

- Applied `dart format` and trimmed the pubspec description to pub.dev's length
  limit; published source is now in a verified repository. No functional changes.

## 0.1.0

Initial release.

- Zero-code in-process HTTP capture via a single `Drengr.start()`: installs an
  `HttpOverrides` beneath `dart:io`, capturing `HttpClient`, `package:http`, and
  Dio's default adapter with no per-request code.
- Captures method, URL, status, timing, sizes, headers, and size-capped
  request/response bodies — including failed (errored) and fire-and-forget
  requests.
- Secret/PII redaction by default: sensitive headers, URL secrets, and body
  fields (tokens, keys, cookies, card numbers) are masked before storage.
- Lifecycle and controls: `stop()`, `setEnabled()` (consent gate), `captureWhen`
  sampling, a custom `onEvent` sink, and `events` / `clear`.
- Chains any existing `HttpOverrides`; never alters, blocks, or fails the app's
  own requests or responses.
