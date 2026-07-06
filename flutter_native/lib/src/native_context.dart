import 'dart:math';

import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart'
    show DefaultStore, DrengrStore;

/// Identity + delivery config handed to the native Drengr SDKs so native and
/// Dart events share one install (and, on iOS, the same initial session).
class DrengrNativeContext {
  const DrengrNativeContext({
    required this.publishableKey,
    required this.ingestUrl,
    required this.appPackage,
    required this.installId,
    this.sessionId,
    this.maxBodyBytes = 64 * 1024,
    this.redactHeaders = const {},
  });

  final String publishableKey;
  final String ingestUrl;
  final String appPackage;

  /// The Dart SDK's persistent install_id — the unification key.
  final String installId;

  /// Current Dart session_id; adopted by the iOS native layer at start
  /// (until the native tracker rotates). Android stamps its own (see README).
  final String? sessionId;

  final int maxBodyBytes;
  final Set<String> redactHeaders;

  /// Loads install_id / session_id from the same store the core SDK persists
  /// to, so both capture layers report one identity. Mints install_id if
  /// absent (same key + format as the core SDK). Never throws.
  static Future<DrengrNativeContext> load({
    required String publishableKey,
    required String ingestUrl,
    required String appPackage,
    DrengrStore? store,
    int maxBodyBytes = 64 * 1024,
    Set<String> redactHeaders = const {},
  }) async {
    var installId = '';
    String? sessionId;
    try {
      final s = store ?? DefaultStore();
      installId = await s.read('install_id') ?? '';
      if (installId.isEmpty) {
        installId = _uuidV4();
        await s.write('install_id', installId);
      }
      sessionId = await s.read('session_id');
    } catch (_) {}
    if (installId.isEmpty) installId = _uuidV4();
    return DrengrNativeContext(
      publishableKey: publishableKey,
      ingestUrl: ingestUrl,
      appPackage: appPackage,
      installId: installId,
      sessionId: sessionId,
      maxBodyBytes: maxBodyBytes,
      redactHeaders: redactHeaders,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'publishable_key': publishableKey,
        'ingest_url': ingestUrl,
        'app_package': appPackage,
        'install_id': installId,
        'session_id': sessionId,
        'max_body_bytes': maxBodyBytes,
        'redact_headers': redactHeaders.toList(),
      };
}

final Random _rand = _secureRandom();
Random _secureRandom() {
  try {
    return Random.secure();
  } catch (_) {
    return Random();
  }
}

// RFC-4122 v4, same format the core SDK mints.
String _uuidV4() {
  final b = List<int>.generate(16, (_) => _rand.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i, int j) =>
      b.sublist(i, j).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
}
