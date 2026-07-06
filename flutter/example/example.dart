import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart';

/// The one-liner: capture + redact + ship to your Drengr dashboard. In a
/// Flutter app this goes in `main()` before `runApp`.
void main() {
  Drengr.start(
    publishableKey: 'drengr_pk_your_key',
    ingestUrl: 'https://your-ref.supabase.co/functions/v1/ingest',
    appPackage: 'com.example.app',
  );

  // Any dart:io / package:http / Dio request from here on is captured,
  // redacted on device, and delivered in batches. Taps, rage/dead taps, and
  // crashes are captured too (behavior: false to opt out). For screen names:
  //   MaterialApp(navigatorObservers: [Drengr.navigatorObserver])
  // Optional:
  //   Drengr.identify('user_123', {'plan': 'pro'});
  //   Drengr.setExperiment('checkout_flow', 'b');
  //   await Drengr.flush();

  // Advanced: handle redacted events yourself instead of shipping them.
  // Drengr.start(onEvent: (e) => print('${e.method} ${e.url}'));
}
