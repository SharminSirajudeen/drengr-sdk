<img src="https://drengr.dev/mark.svg" alt="Drengr" width="72" height="72" />

# drengr_flutter_sdk

Zero-code mobile analytics for Flutter. One line captures every HTTP request
and response your app makes — `package:http`, Dio, raw `dart:io` — redacts
secrets/PII on device, and ships it to your Drengr dashboard:

```dart
import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart';

void main() {
  Drengr.start(
    publishableKey: 'drengr_pk_…',
    ingestUrl: 'https://<your-ref>.supabase.co/functions/v1/ingest',
    appPackage: 'com.example.app',
  );
  runApp(const MyApp());
}
```

That's the whole integration. No per-request code, no proxy, no certificate.
Events are batched, delivered off the request path, retried with backoff, and
survive app kills (disk-backed queue). The SDK also handles identity for you:

- **install_id** — minted once, persisted (shared_preferences).
- **session_id** — rotates after 30 min idle or 24 h max age; the old
  session's events are flushed before rotation.
- **app context** — package, OS, OS version, SDK version on every envelope.

Get your publishable key and ingest URL from your Drengr console → Settings →
Keys.

## Install

```yaml
dependencies:
  drengr_flutter_sdk: ^0.4.0
```

## Behavior capture

On by default in one-liner mode (`behavior: false` to opt out). Zero
per-widget code — a global pointer route captures every tap, chained error
handlers capture crashes:

- `tap` — semantic label (Semantics label > widget key > button/text content
  > widget runtimeType), normalized `x`/`y` (0–1), current screen.
- `rage_tap` — ≥3 taps within 600 ms / 24 px on the same label.
- `dead_tap` — tap whose hit-path has no interactive handler.
- `crash` — `FlutterError.onError` + `PlatformDispatcher.onError`, chained
  (your handlers still run). Ships exception type + first stack frame only —
  never the message, which can carry PII.
- `screen_view` — add the observer for screen names on all of the above:

```dart
MaterialApp(navigatorObservers: [Drengr.navigatorObserver])
```

Labels are redacted and capped on device before they leave the app.

## Identity and experiments

```dart
Drengr.identify('user_123', {'plan': 'pro'});   // your stable, non-PII id
Drengr.setExperiment('checkout_flow', 'b');     // tag events with a variant
await Drengr.flush();                            // force-drain now
```

All three are safe no-ops when no key is configured — they never throw.
`flush()` also runs automatically when the app is backgrounded.

## What it captures

| Networking | Captured |
|---|---|
| `dart:io` `HttpClient` (direct) | ✅ |
| `package:http` | ✅ |
| Dio — default `IOHttpClientAdapter` | ✅ |

For each exchange: method, URL, status, duration, sizes, redacted headers, and
size-capped redacted bodies — including failed and fire-and-forget requests.

## Privacy and redaction

Safe by default, on device, before anything leaves the app:

- **Headers** — `Authorization`, `Cookie`, `Set-Cookie`, `X-Api-Key`, … masked.
- **URLs** — secrets in query params, fragments, and paths masked.
- **Bodies** — sensitive fields masked structurally (JSON/form parsed;
  `*token*`, `*secret*`, `password`, emails, phones, …) and by value (Luhn
  card numbers, JWTs, bearer tokens, vendor key prefixes, PEM keys).
- **Payment paths** — bodies are NOT captured on `/payment`, `/checkout`,
  `/card` paths unless you opt in (`captureSensitivePathBodies: true`).
- **Size caps** — bodies 64 KB (configurable); shipped headers ≤48 entries
  and ≤8 KB per side.

The bytes your app sends and receives are **never altered** — redaction
applies only to the captured copy.

## Advanced: handle events yourself

Pass `onEvent` to receive each redacted `NetworkEvent` instead of the built-in
delivery (an explicit `onEvent` always wins over the auto sink):

```dart
Drengr.start(onEvent: (e) {
  print('${e.method} ${e.url} -> ${e.statusCode}');
});
```

Or construct the `IngestSink` yourself for full control over batching:

```dart
final sink = IngestSink(url: ..., publishableKey: ..., context: {...});
Drengr.start(onEvent: sink.addNetwork);
```

## Configuration

```dart
Drengr.start(
  publishableKey: 'drengr_pk_…',
  ingestUrl: 'https://…/functions/v1/ingest',
  appPackage: 'com.example.app',
  maxBodyBytes: 64 * 1024,             // body capture cap
  enabled: true,                       // start paused (consent) with `false`
  captureWhen: (uri) => true,          // per-request predicate
  sampleRate: 1.0,                     // capture this fraction of requests
  redactHeaders: {'x-tenant-secret'},  // extra header names to mask
  ignoreHosts: {'analytics.internal'}, // skip capture for these hosts
  captureSensitivePathBodies: false,   // keep payment-path bodies off
);
```

## Lifecycle and consent

```dart
Drengr.setEnabled(false);  // pause capture (consent gate)
Drengr.optOut();           // persistent opt-out across launches
Drengr.optIn();
await Drengr.flush();      // force-drain the delivery queue
Drengr.stop();             // uninstall; restores the previous HttpOverrides
```

## Isolates

`HttpOverrides.global` is per-isolate and **not inherited** by
`Isolate.spawn`/`compute()`. Call `Drengr.installInIsolate(...)` (same
parameters as `start`) at the top of any spawned isolate that performs
networking, or its traffic is invisible.

For a Dio config that supplies its own `HttpClient` (custom
`onHttpClientCreate`), wrap it: `Drengr.wrapClient(myClient)`.

## Limitations

- Non-`dart:io` adapters (`cronet_http`, `cupertino_http`,
  `native_dio_adapter`) and native SDKs' own OkHttp/URLSession traffic are
  invisible to any Dart hook — that's what the native Drengr SDKs are for.
- gRPC uses its own channel; capture requires a gRPC interceptor (not
  included).

## How it works

`Drengr.start()` sets `HttpOverrides.global` to a capturing override that
wraps the real `HttpClient`, chaining any existing override. Bodies are tee'd
inside the stream pipeline — your app's read is forwarded untouched while a
bounded, redacted copy is captured. Event emission is queued off the request
path, and delivery runs on its own client, invisible to capture. Every error
on the capture path is swallowed: your request proceeds as if Drengr weren't
there.

## License

Apache-2.0. See [LICENSE](LICENSE).
