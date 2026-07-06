import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart' show NetworkEvent;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'dedup.dart';
import 'native_context.dart';

/// Starts and controls the native Drengr SDKs beneath the Dart engine.
/// Every call is fail-open: errors surface as false/void, never a throw.
class DrengrNative {
  DrengrNative._();

  @visibleForTesting
  static const MethodChannel channel = MethodChannel('drengr_flutter_native');

  /// Dart-side duplicate filter fed by native (url, method, ts) summaries.
  static final NetworkDedup dedup = NetworkDedup();

  static bool _handlerInstalled = false;

  /// Starts the native SDK with the Dart SDK's identity (see
  /// [DrengrNativeContext.load]). iOS installs global URLSession capture;
  /// Android arms delivery + exposes the OkHttp/Cronet hooks (see README).
  static Future<bool> start(DrengrNativeContext context) async {
    _installHandler();
    try {
      return await channel.invokeMethod<bool>('start', context.toMap()) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Pushes a rotated Dart session_id to the native layer. Returns false
  /// while the native SDKs lack a set-session API (README "Unified
  /// identity") — install_id still unifies the two planes.
  static Future<bool> updateSession(String sessionId) async {
    if (sessionId.isEmpty) return false;
    try {
      return await channel.invokeMethod<bool>(
              'updateSession', <String, Object?>{'session_id': sessionId}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Android only: opt-in process-global HttpURLConnection capture (set-once
  /// URLStreamHandlerFactory). False on iOS or when another factory already
  /// owns the process.
  static Future<bool> installUrlConnectionCapture() async {
    try {
      return await channel.invokeMethod<bool>('installUrlConnectionCapture') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Pause/resume native capture (consent gate mirror).
  static Future<void> setEnabled(bool value) =>
      _voidCall('setEnabled', <String, Object?>{'value': value});

  /// Persistent opt-out in the native layer (mirror of the Dart SDK's).
  static Future<void> optOut() => _voidCall('optOut');

  /// Clears a native opt-out and resumes capture.
  static Future<void> optIn() => _voidCall('optIn');

  /// Mirrors identify() into the native sink so both planes carry external_id.
  static Future<void> identify(String externalId,
          [Map<String, Object?> traits = const {}]) =>
      _voidCall('identify',
          <String, Object?>{'external_id': externalId, 'traits': traits});

  /// Mirrors an experiment variant into the native sink.
  static Future<void> setExperiment(String key, String? variant) =>
      _voidCall(
          'setExperiment', <String, Object?>{'key': key, 'variant': variant});

  /// Force-sends the native layer's buffered events.
  static Future<void> flush() => _voidCall('flush');

  /// Dedup gate for the Dart capture plane: false when the native layer
  /// already reported the same (url, method) within the window.
  static bool shouldEnqueue(NetworkEvent e) =>
      dedup.admit(e.url, e.method, e.timestampMs);

  static Future<void> _voidCall(String method,
      [Map<String, Object?>? args]) async {
    try {
      await channel.invokeMethod<void>(method, args);
    } catch (_) {}
  }

  // Native → Dart event summaries feed the dedup window.
  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    channel.setMethodCallHandler((call) async {
      try {
        if (call.method == 'nativeEvent') {
          final m = call.arguments;
          if (m is Map) {
            dedup.recordNative(
              (m['url'] as String?) ?? '',
              (m['method'] as String?) ?? '',
              (m['ts_ms'] as num?)?.toInt() ?? 0,
            );
          }
        }
      } catch (_) {}
      return null;
    });
  }
}
