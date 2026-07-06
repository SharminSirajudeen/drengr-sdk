import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart' show MemoryStore;
import 'package:drengr_flutter_native/drengr_flutter_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DrengrNativeContext.load', () {
    test('reuses the install_id the core SDK persisted', () async {
      final store = MemoryStore();
      await store.write('install_id', 'core-install');
      await store.write('session_id', 'core-session');
      final ctx = await DrengrNativeContext.load(
        publishableKey: 'pk',
        ingestUrl: 'https://ingest.example',
        appPackage: 'com.example.app',
        store: store,
      );
      expect(ctx.installId, 'core-install');
      expect(ctx.sessionId, 'core-session');
    });

    test('mints + persists install_id when absent (core format)', () async {
      final store = MemoryStore();
      final ctx = await DrengrNativeContext.load(
        publishableKey: 'pk',
        ingestUrl: 'https://ingest.example',
        appPackage: 'com.example.app',
        store: store,
      );
      expect(
        ctx.installId,
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
      expect(await store.read('install_id'), ctx.installId);
      expect(ctx.sessionId, isNull);
    });

    test('toMap carries the full channel payload', () {
      const ctx = DrengrNativeContext(
        publishableKey: 'pk',
        ingestUrl: 'https://ingest.example',
        appPackage: 'com.example.app',
        installId: 'i-1',
        sessionId: 's-1',
        maxBodyBytes: 1024,
        redactHeaders: {'x-token'},
      );
      expect(ctx.toMap(), {
        'publishable_key': 'pk',
        'ingest_url': 'https://ingest.example',
        'app_package': 'com.example.app',
        'install_id': 'i-1',
        'session_id': 's-1',
        'max_body_bytes': 1024,
        'redact_headers': ['x-token'],
      });
    });
  });
}
