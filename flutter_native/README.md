# drengr_flutter_native

Native-layer network capture for Flutter — the optional add-on to
[`drengr_flutter_sdk`](../flutter).

## Why this exists

The core Drengr Flutter SDK hooks `dart:io`, so it sees everything your Dart
code sends. It **cannot** see traffic issued by native SDKs bundled in your app
— a payment SDK's OkHttp/URLSession calls, an ads SDK, a maps SDK. That is often
the highest-value wire traffic in the app. This plugin wraps the real native
Drengr SDKs (Android: `dev.drengr:analytics-android`, iOS: pod `Drengr`) beneath
the Dart engine to capture it, sharing one identity with the Dart SDK.

The core SDK stays pure-Dart; add this package only if you need the native plane.

## Usage

```dart
import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart';
import 'package:drengr_flutter_native/drengr_flutter_native.dart';

// 1. Dart plane (core SDK, unchanged)
Drengr.start(
  publishableKey: 'drengr_pk_…',
  ingestUrl: 'https://<ref>.supabase.co/functions/v1/ingest',
  appPackage: 'com.example.app',
);

// 2. Native plane — loads the SAME install_id the core SDK persisted
final ctx = await DrengrNativeContext.load(
  publishableKey: 'drengr_pk_…',
  ingestUrl: 'https://<ref>.supabase.co/functions/v1/ingest',
  appPackage: 'com.example.app',
);
await DrengrNative.start(ctx);

// Android only, opt-in: process-global HttpURLConnection capture
await DrengrNative.installUrlConnectionCapture();
```

Mirror consent and identity calls so both planes agree:
`DrengrNative.setEnabled / optOut / optIn / identify / setExperiment / flush`.

## What each platform actually captures

| Platform | Transport | Coverage |
|---|---|---|
| iOS | `URLSession` (all sessions) | **Automatic.** The native SDK's passive global capture sees every URLSession exchange, including native SDKs (Alamofire, StoreKit-adjacent payment SDKs, ads). |
| Android | `HttpURLConnection` | Opt-in via `DrengrNative.installUrlConnectionCapture()` (process-global, set-once `URLStreamHandlerFactory`; returns `false` if another factory owns the process). |
| Android | Cronet | Host-side passthrough: `DrengrFlutterNativePlugin.cronetListener(executor)` returns a `RequestFinishedInfo.Listener` for your `CronetEngine.Builder`. |
| Android | OkHttp | **No global hook exists in OkHttp — this is a hard platform boundary, not a Drengr gap.** Capture requires the native SDK's interceptor to be added to each `OkHttpClient`. See below. |

### The OkHttp boundary, honestly

OkHttp clients constructed inside a third-party native SDK are unreachable
unless that SDK lets you pass a client or interceptor in. What you *can* wire:
any `OkHttpClient` your own native (Kotlin/Java) code builds. After
`DrengrNative.start(...)` completes, the shared interceptor is available to
host-app native code:

```kotlin
// e.g. MainActivity / your Application class, or wherever you build clients
val client = OkHttpClient.Builder()
    .apply { DrengrFlutterNativePlugin.interceptor?.let { addInterceptor(it) } }
    .build()
// Cronet:
val listener = DrengrFlutterNativePlugin.cronetListener(executor)
if (listener != null) {
    cronetEngineBuilder.addRequestFinishedListener(listener as RequestFinishedInfo.Listener)
}
```

Dart cannot hand a native `OkHttpClient` across the boundary; this Kotlin-side
seam is the supported path.

## Unified identity

- **install_id** — unified now. `DrengrNativeContext.load()` reads (or mints,
  same key + format) the core SDK's persisted `install_id` and the native SDKs
  accept it via `extraContext`, so both planes report one install.
- **session_id** — partially unified. iOS adopts the Dart session at start and
  keeps it until the native tracker's own idle/max-age rotation; Android's
  native SDK always stamps its own session id on the envelope. Sessions from
  the two planes are stitched server-side by `install_id` + time.
- `DrengrNative.updateSession(id)` exists in the channel protocol and currently
  returns `false`: the native SDKs have no set-session API yet (see
  "Native SDK additions" below).

## Dedup

When one exchange crosses both planes (e.g. a `cupertino_http`-style bridge),
both layers could report it. `DrengrNative.dedup` keeps a rolling window of
native `(url, method, ts)` summaries; `DrengrNative.shouldEnqueue(event)`
returns `false` for a Dart event matching a native one within 500 ms — consult
it before enqueueing Dart-captured events. The Dart-side plumbing (channel
handler + filter) is live and tested; the native SDKs do not yet emit per-event
summaries, so the window stays empty until the API below lands.

## Native SDK additions that would complete unification

This plugin only consumes the native SDKs' public APIs. Two small additions
(owned by the native SDK teams) would finish the job:

1. **`Drengr.setSessionId(String)`** (Android + iOS): override the internal
   session tracker's id and suppress its own rotation while externally driven.
   Then `DrengrNative.updateSession` unifies sessions fully.
2. **`Drengr.onEventSummary((url, method, tsMs) -> Unit)`** (Android + iOS): a
   metadata-only per-event tap (no headers/bodies — nothing redaction-sensitive)
   the plugin forwards to Dart as `nativeEvent` for cross-plane dedup.

## Verification

```bash
cd sdk/flutter_native
flutter pub get
dart analyze          # must be clean
flutter test          # Dart-side unit tests
```

Native compile checks build a host app against the native artifacts:

```bash
flutter create --template=app --platforms=android,ios example
cd example && flutter build apk --debug && flutter build ios --debug --no-codesign
```

Note: the currently *published* 0.1.0 artifacts (Maven Central AAR, CocoaPods
pod) predate the HttpURLConnection/Cronet/`flush` APIs this plugin uses — both
registries are immutable, so the current native source must ship under a bumped
version. Until then, compile against the working tree: `publishToMavenLocal`
for Android (pin `dev.drengr` to `mavenLocal()` via `exclusiveContent`) and a
`pod 'Drengr', :path =>` override for iOS.
