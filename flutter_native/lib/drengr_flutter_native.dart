/// Native-layer capture beneath the Dart engine — the optional add-on that
/// sees native-SDK traffic (payments, ads, maps) no Dart hook can.
///
/// The core `drengr_flutter_sdk` stays pure-Dart; this plugin wraps the real
/// native Drengr SDKs (Android: `dev.drengr:analytics-android`, iOS: pod
/// `Drengr`) and hands them the Dart SDK's install_id so both capture planes
/// report one identity.
library;

export 'src/dedup.dart' show NetworkDedup;
export 'src/drengr_native.dart' show DrengrNative;
export 'src/native_context.dart' show DrengrNativeContext;
