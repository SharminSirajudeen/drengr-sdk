# Changelog

## 0.1.0

- Initial release: Flutter plugin wrapping the native Drengr SDKs
  (Android `dev.drengr:analytics-android`, iOS pod `Drengr`) for
  native-layer capture beneath the Dart engine.
- Unified install_id with `drengr_flutter_sdk` via `DrengrNativeContext.load()`.
- iOS: global passive URLSession capture (native-SDK traffic included).
- Android: opt-in HttpURLConnection capture, OkHttp interceptor + Cronet
  listener exposed to host-app native code.
- Cross-plane `NetworkDedup` (url, method, ±500 ms) with native→Dart
  summary channel.
