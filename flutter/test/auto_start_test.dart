import 'dart:convert';
import 'dart:io';

import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart';
import 'package:test/test.dart';

final _uuidRe = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

void main() {
  group('auto-context start', () {
    late HttpServer ingest;
    late HttpServer echo;
    final envelopes = <Map<String, dynamic>>[];

    setUp(() async {
      // Kill any queue persisted by earlier tests/runs.
      final q = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}.drengr_queue.jsonl');
      if (q.existsSync()) q.deleteSync();
      envelopes.clear();
      Drengr.debugStore = MemoryStore();
      Drengr.debugNow = null;
      ingest = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      ingest.listen((req) async {
        final raw = await utf8.decoder.bind(req).join();
        envelopes.add(jsonDecode(raw) as Map<String, dynamic>);
        req.response.statusCode = 202;
        await req.response.close();
      });
      echo = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      echo.listen((req) async {
        req.response.statusCode = 200;
        req.response.headers.set('x-echo', 'yes');
        req.response.write('{"ok":true}');
        await req.response.close();
      });
    });

    tearDown(() async {
      Drengr.stop();
      Drengr.debugStore = null;
      Drengr.debugNow = null;
      await ingest.close(force: true);
      await echo.close(force: true);
    });

    Future<void> hitEcho() async {
      final client = HttpClient();
      final req =
          await client.getUrl(Uri.parse('http://127.0.0.1:${echo.port}/data'));
      req.headers.set('authorization', 'Bearer real-secret');
      req.headers.set('x-custom', 'v1');
      final resp = await req.close();
      await resp.drain<void>();
      client.close(force: true);
      // Let the microtask drain + onComplete run.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    test('start(publishableKey:, ingestUrl:, appPackage:) ships an envelope',
        () async {
      Drengr.start(
        publishableKey: 'drengr_pk_test',
        ingestUrl: 'http://127.0.0.1:${ingest.port}/ingest',
        appPackage: 'com.example.app',
      );
      await hitEcho();
      await Drengr.flush();

      expect(envelopes, isNotEmpty);
      final env = envelopes.last;
      expect(env['app_package'], 'com.example.app');
      expect(env['install_id'], matches(_uuidRe));
      expect(env['session_id'], matches(_uuidRe));
      expect(env['os'], isNotEmpty);
      expect(env['sdk_version'], isNotEmpty);
      expect(env['sent_at_ms'], isA<int>());

      final events = (env['events'] as List).cast<Map<String, dynamic>>();
      final net = events.firstWhere((e) => e['kind'] == 'net');
      expect(net['method'], 'GET');
      expect(net['status'], 200);

      // Headers envelope: snake_case maps, already redacted.
      final reqH = (net['req_headers'] as Map).cast<String, dynamic>();
      final respH = (net['resp_headers'] as Map).cast<String, dynamic>();
      expect(reqH['authorization'], '[REDACTED]');
      expect(reqH['x-custom'], 'v1');
      expect(respH['x-echo'], 'yes');
      expect(jsonEncode(env), isNot(contains('real-secret')));
    });

    test('install_id persists; session reuses within idle window', () async {
      final store = MemoryStore();
      Drengr.debugStore = store;
      Drengr.start(
        publishableKey: 'drengr_pk_test',
        ingestUrl: 'http://127.0.0.1:${ingest.port}/ingest',
        appPackage: 'com.example.app',
      );
      await hitEcho();
      await Drengr.flush();
      final first = envelopes.last;
      Drengr.stop();

      // Same store = same device: second start reuses install_id AND session.
      Drengr.debugStore = store;
      Drengr.start(
        publishableKey: 'drengr_pk_test',
        ingestUrl: 'http://127.0.0.1:${ingest.port}/ingest',
        appPackage: 'com.example.app',
      );
      await hitEcho();
      await Drengr.flush();
      final second = envelopes.last;
      expect(second['install_id'], first['install_id']);
      expect(second['session_id'], first['session_id']);
    });

    test('facade identify + setExperiment reach the envelope', () async {
      Drengr.start(
        publishableKey: 'drengr_pk_test',
        ingestUrl: 'http://127.0.0.1:${ingest.port}/ingest',
        appPackage: 'com.example.app',
      );
      Drengr.identify('user_1', {'plan': 'pro'});
      Drengr.setExperiment('checkout_flow', 'b');
      await hitEcho();
      await Drengr.flush();

      final env = envelopes.last;
      expect(env['external_id'], 'user_1');
      expect(env['experiments'], {'checkout_flow': 'b'});
      final events = (env['events'] as List).cast<Map<String, dynamic>>();
      expect(events.any((e) => e['kind'] == 'identify'), isTrue);
    });

    test('identify/setExperiment/flush are no-ops without a sink', () async {
      expect(() => Drengr.identify('u', {'a': 1}), returnsNormally);
      expect(() => Drengr.setExperiment('k', 'v'), returnsNormally);
      await expectLater(Drengr.flush(), completes);
    });

    test('explicit onEvent wins over auto sink', () async {
      final seen = <NetworkEvent>[];
      Drengr.start(
        publishableKey: 'drengr_pk_test',
        ingestUrl: 'http://127.0.0.1:${ingest.port}/ingest',
        onEvent: seen.add,
      );
      await hitEcho();
      await Drengr.flush();
      expect(seen, hasLength(1));
      expect(envelopes, isEmpty);
    });

    test('payment-ish paths ship metadata but no bodies (D-9)', () async {
      Drengr.start(
        publishableKey: 'drengr_pk_test',
        ingestUrl: 'http://127.0.0.1:${ingest.port}/ingest',
        appPackage: 'com.example.app',
      );
      final client = HttpClient();
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:${echo.port}/api/checkout'));
      final resp = await req.close();
      await resp.drain<void>();
      client.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await Drengr.flush();

      final events =
          (envelopes.last['events'] as List).cast<Map<String, dynamic>>();
      final net = events.firstWhere((e) => e['kind'] == 'net');
      expect(net.containsKey('body'), isFalse);
      expect(net['resp_bytes'], greaterThan(0)); // metadata still captured
    });

    test('resume past idle window flushes old session then rotates', () async {
      var now = DateTime.now().millisecondsSinceEpoch;
      Drengr.debugNow = () => now;
      Drengr.start(
        publishableKey: 'drengr_pk_test',
        ingestUrl: 'http://127.0.0.1:${ingest.port}/ingest',
        appPackage: 'com.example.app',
      );
      await hitEcho();
      // Background: auto-flush ships the pending event under session A.
      await Drengr.debugLifecycle(false);
      final sessionA = envelopes.last['session_id'];

      now += SESSION_IDLE_MS + 1;
      await Drengr.debugLifecycle(true); // resume → rotate
      await hitEcho();
      await Drengr.flush();
      final sessionB = envelopes.last['session_id'];
      expect(sessionB, matches(_uuidRe));
      expect(sessionB, isNot(sessionA));
    });
  });

  group('session manager spec', () {
    test('start reuses session within SESSION_IDLE_MS, mints past it',
        () async {
      var now = 1000000000000;
      final store = MemoryStore();
      final a = SessionManager(store, now: () => now);
      final id1 = await a.start();

      now += SESSION_IDLE_MS - 1;
      final b = SessionManager(store, now: () => now);
      expect(await b.start(), id1);

      now += SESSION_IDLE_MS + 1;
      final c = SessionManager(store, now: () => now);
      expect(await c.start(), isNot(id1));
    });

    test('stale after SESSION_MAX_MS even with constant activity', () async {
      var now = 1000000000000;
      final s = SessionManager(MemoryStore(), now: () => now);
      final id1 = await s.start();
      for (var i = 0; i < 75; i++) {
        now += 1200000; // 20-min cadence: never idle, but age passes 24 h
        s.touch();
      }
      expect(s.stale, isTrue);
      expect(await s.rotate(), isNot(id1));
    });

    test('touch keeps the session fresh under the idle limit', () async {
      var now = 1000000000000;
      final s = SessionManager(MemoryStore(), now: () => now);
      await s.start();
      now += SESSION_IDLE_MS - 1;
      s.touch();
      now += SESSION_IDLE_MS - 1;
      expect(s.stale, isFalse);
    });
  });

  group('headers envelope caps', () {
    late HttpServer ingest;
    final envelopes = <Map<String, dynamic>>[];

    setUp(() async {
      final q = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}.drengr_queue.jsonl');
      if (q.existsSync()) q.deleteSync();
      envelopes.clear();
      ingest = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      ingest.listen((req) async {
        final raw = await utf8.decoder.bind(req).join();
        envelopes.add(jsonDecode(raw) as Map<String, dynamic>);
        req.response.statusCode = 202;
        await req.response.close();
      });
    });

    tearDown(() async => ingest.close(force: true));

    NetworkEvent evWithHeaders(Map<String, String> h) => NetworkEvent(
          method: 'GET',
          url: 'https://api.example.com/x',
          statusCode: 200,
          durationMs: 1,
          requestBodyBytes: 0,
          responseBodyBytes: 0,
          requestHeaders: h,
          responseHeaders: const {},
          requestBody: null,
          responseBody: null,
          timestampMs: 0,
        );

    Future<Map<String, dynamic>> ship(Map<String, String> h) async {
      final sink = IngestSink(
        url: 'http://127.0.0.1:${ingest.port}/ingest',
        publishableKey: 'drengr_pk_test',
        context: const {'app_package': 't'},
        maxBatch: 1,
        queuePath: '${Directory.systemTemp.path}${Platform.pathSeparator}'
            '.drengr_q_headers_${ingest.port}.jsonl', // isolate from parallel suites
      );
      sink.addNetwork(evWithHeaders(h));
      await sink.flush();
      final events =
          (envelopes.last['events'] as List).cast<Map<String, dynamic>>();
      return events.first;
    }

    test('caps at 48 entries', () async {
      final h = {for (var i = 0; i < 60; i++) 'h$i': 'v$i'};
      final net = await ship(h);
      expect((net['req_headers'] as Map).length, 48);
      expect(net['resp_headers'], isEmpty);
    });

    test('oversized serialized map becomes {}', () async {
      final h = {for (var i = 0; i < 10; i++) 'h$i': 'x' * 2000};
      final net = await ship(h);
      expect(net['req_headers'], isEmpty);
    });
  });
}
