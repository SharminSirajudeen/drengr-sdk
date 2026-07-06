<div align="center">

# Drengr Analytics — SDKs

**0-code mobile & web analytics.** One line in — Drengr captures your app's real network
traffic and behavior, redacts PII **on-device**, and discovers and names your business
events by itself. No tracking plan, no `track()` calls, no data team.

[Website](https://drengr.dev) · [Analytics](https://analytics.drengr.dev) · [Docs](https://drengr.dev/getting-started) · [Security](https://drengr.dev/security)

</div>

---

This repository holds the open-source Drengr Analytics SDKs for **Flutter, Web, iOS, and
Android**, all under the [Apache-2.0](LICENSE) license. The hosted analytics service and
the Drengr CLI are separate products and are not part of this repo.

## Install

| Platform | Registry | Coordinate |
|---|---|---|
| **Flutter** | [pub.dev](https://pub.dev/packages/drengr_flutter_sdk) | `drengr_flutter_sdk: ^0.4.0` |
| **Web** | [npm](https://www.npmjs.com/package/drengr-js) | `drengr-js@0.2.0` |
| **iOS** | Swift Package Manager / CocoaPods | `from: "0.2.0"` · `pod 'Drengr', '~> 0.2.0'` |
| **Android** | [Maven Central](https://central.sonatype.com/artifact/dev.drengr/analytics-android) | `dev.drengr:analytics-android:0.2.0` |

These are the versions in this repo (tag `v0.2.0`). Registry publishes may lag the tag —
pub.dev currently has `0.2.1`, npm `0.1.0`. `flutter_native/` is an optional add-on
(native-layer capture beneath the Dart engine) at `0.1.0`, not yet published.

## Quick start

Each SDK needs two things: your **ingest URL** and your **publishable key** (`drengr_pk_…`,
from the [console](https://analytics.drengr.dev)). PII is scrubbed on-device before anything leaves.

### Flutter
```bash
flutter pub add drengr_flutter_sdk
```
```dart
import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart';

final sink = IngestSink(
  url: 'https://ziryfxrwrvnunwjupgfg.supabase.co/functions/v1/ingest',
  publishableKey: 'drengr_pk_…',
  context: {'app_package': 'com.example.myapp'},
);
Drengr.start(onEvent: sink.addNetwork);
```

### Web
```bash
npm install drengr-js
```
```js
import { Drengr } from 'drengr-js';

Drengr.start({
  ingestUrl: 'https://ziryfxrwrvnunwjupgfg.supabase.co/functions/v1/ingest',
  publishableKey: 'drengr_pk_…',
  appPackage: 'com.example.myapp',
});
```

### iOS
Add the package in Xcode (**File → Add Package Dependencies…**):
```
https://github.com/SharminSirajudeen/drengr-sdk.git   → from 0.2.0
```
or in `Package.swift`:
```swift
.package(url: "https://github.com/SharminSirajudeen/drengr-sdk.git", from: "0.2.0")
```
or CocoaPods: `pod 'Drengr', '~> 0.2.0'`
```swift
import Drengr

Drengr.start(
    publishableKey: "drengr_pk_…",
    ingestURL: "https://ziryfxrwrvnunwjupgfg.supabase.co/functions/v1/ingest",
    appPackage: "com.example.app"
)
```

### Android
```kotlin
// build.gradle.kts
implementation("dev.drengr:analytics-android:0.2.0")
```
```kotlin
val client = OkHttpClient.Builder()
    .addInterceptor(
        Drengr.start(
            context = applicationContext,
            publishableKey = "drengr_pk_…",
            ingestUrl = "https://ziryfxrwrvnunwjupgfg.supabase.co/functions/v1/ingest",
            appPackage = "com.example.app",
        )
    )
    .build()
```

## How it works

Drengr captures the request/response shapes your app already produces, redacts secrets and
PII **before they leave the device** (field-name + value scrubbing, Luhn/JWT/bearer
detection), and ships only redacted analytics scalars. On the server, the AI **proposes a
name once** per new request shape; a human approves it; a deterministic rule handles every
event after — no model in the hot path. The reviewed annotation library is the asset, not
the model.

## What leaves the device

Redacted, projected analytics scalars only. Raw PII is never readable server-side. The full
redaction pipeline is in this repo (`*/redact.*`) and documented at
[drengr.dev/security](https://drengr.dev/security).

## License

Apache-2.0 — see [LICENSE](LICENSE). Each SDK directory also carries its own `LICENSE`.
