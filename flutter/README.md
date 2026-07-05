# drengr_flutter_sdk

The network-capture module of the **Drengr** in-app SDK. One line records every
HTTP request and response your app makes — `package:http`, Dio, and raw
`dart:io` `HttpClient` — with built-in secret/PII redaction, and without
touching your networking code. Works in any Flutter or Dart app.

It installs a single `HttpOverrides` beneath `dart:io` — in-process and above
TLS, so there's no proxy, no certificate, and no platform channel. Capture is
zero-dependency and best-effort: it never alters, blocks, or breaks your app's
own traffic.

## Install

```yaml
dependencies:
  drengr_flutter_sdk: ^0.1.0
```

Or straight from Git:

```yaml
dependencies:
  drengr_flutter_sdk:
    git:
      url: https://github.com/SharminSirajudeen/drengr-sdk.git
      path: flutter
```

## Usage

One line in `main()`, before `runApp`:

```dart
import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart';

void main() {
  Drengr.start();
  runApp(const MyApp());
}
```

That's it. Every request through `http`, Dio (default adapter), or `HttpClient`
is now captured. To handle events yourself instead of logging them:

```dart
Drengr.start(onEvent: (event) {
  print('${event.method} ${event.url} -> ${event.statusCode} '
      '(${event.durationMs}ms, ${event.responseBodyBytes}B)');
});
```

## What it captures

| Networking | Captured |
|---|---|
| `dart:io` `HttpClient` (direct) | ✅ |
| `package:http` | ✅ |
| Dio — default `IOHttpClientAdapter` | ✅ |

For each exchange: method, URL, status, duration, request/response sizes,
headers, and size-capped request/response bodies — including failed (errored)
and fire-and-forget requests.

## Privacy and redaction

Capture is designed to be safe by default:

- **Headers** — `Authorization`, `Cookie`, `Set-Cookie`, `X-Api-Key`, and more
  are masked to `[REDACTED]`.
- **URLs** — secrets in query params, fragments, and paths are masked.
- **Bodies** — secrets and PII are masked structurally (JSON is parsed and
  sensitive fields like `*token*`, `*secret*`, `password`, `apiKey` masked) and
  by value (card numbers via Luhn check, JWTs, bearer tokens, cookie lines).
- **Bodies are size-capped** (64 KB default); larger or binary bodies stream
  through untouched and are recorded by size only.
- **Default logging is metadata-only** — bodies are not written to the console
  unless you opt in with `logBodies: true` or your own `onEvent` sink.

The bytes your app sends and receives are **never altered** — redaction applies
only to the captured copy.

## Configuration

```dart
Drengr.start(
  maxBodyBytes: 64 * 1024,             // body capture cap
  enabled: true,                       // start paused (consent) with `false`
  logBodies: false,                    // also log redacted bodies to console
  captureWhen: (uri) => true,          // sampling / allow-listing predicate
  redactHeaders: {'x-tenant-secret'},  // extra header names to mask
  ignoreHosts: {'analytics.internal'}, // skip capture for these hosts
  onEvent: (event) { /* ship it */ },  // custom sink (defaults to logging)
);
```

## Lifecycle

```dart
Drengr.setEnabled(true);   // resume after a paused/consent start
final recent = Drengr.events; // bounded ring of recent events
Drengr.clear();            // drop buffered events (e.g. on logout)
Drengr.stop();             // uninstall; restores the previous HttpOverrides
```

## How it works

`Drengr.start()` sets `HttpOverrides.global` to a capturing override that wraps
the real `HttpClient`. It **chains** any existing override, so it never clobbers
your own (or another SDK's) `HttpOverrides`. Request and response bodies are
tee'd inside the stream pipeline — the app's read is forwarded untouched while a
bounded, redacted copy is captured alongside it. Any error on the capture path
is swallowed; your request proceeds as if Drengr weren't there.

## Limitations

- Traffic from **non-`dart:io` adapters** (`cronet_http`, `cupertino_http`,
  `native_dio_adapter`) and **native SDKs** (a third-party library's own
  OkHttp/URLSession stack) is not visible to a Dart hook — that needs the native
  Drengr SDKs.
- `HttpOverrides.global` is installed **per isolate**; call `Drengr.start()`
  again inside a background isolate's entry point if it performs networking.

## License

Apache-2.0. See [LICENSE](LICENSE).
