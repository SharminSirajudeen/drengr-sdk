import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart';

/// Minimal example: install Drengr once; ordinary requests are then captured
/// with no per-request code. In a Flutter app this goes in `main()` before
/// `runApp`. Here we print each captured event instead of using the default
/// logging sink.
void main() {
  Drengr.start(
    onEvent: (event) {
      // event.requestBody / event.responseBody are redacted, size-capped copies.
      print('${event.method} ${event.url} -> ${event.statusCode} '
          '(${event.durationMs}ms, ${event.responseBodyBytes}B)');
    },
  );

  // Any dart:io / package:http / Dio request from here on is captured
  // automatically.
}
