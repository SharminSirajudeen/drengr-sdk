import 'dart:convert';
import 'dart:io';

import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart';
import 'package:test/test.dart';

/// identify()/setExperiment() live on [IngestSink] (not [Drengr]) — this SDK's
/// capture engine and delivery sink are wired up by the app, not coupled here
/// (see tool/stall_probe.dart for the real wiring pattern).
void main() {
  group('identify + experiments', () {
    late HttpServer server;
    final bodies = <Map<String, dynamic>>[];

    setUp(() async {
      // Kill any queue persisted by earlier tests/runs (parallel isolates share it).
      final q = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}.drengr_queue.jsonl');
      if (q.existsSync()) q.deleteSync();
      bodies.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final raw = await utf8.decoder.bind(req).join();
        bodies.add(jsonDecode(raw) as Map<String, dynamic>);
        req.response.statusCode = 200;
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    IngestSink newSink() => IngestSink(
          url: 'http://127.0.0.1:${server.port}/ingest',
          publishableKey: 'drengr_pk_test',
          context: {'app_package': 'test', 'install_id': 'test'},
          maxBatch: 1, // flush on the first enqueued event
          queuePath: '${Directory.systemTemp.path}${Platform.pathSeparator}'
              '.drengr_q_identify_${server.port}.jsonl', // isolate from parallel suites
        );

    NetworkEvent sampleEvent() => const NetworkEvent(
          method: 'GET',
          url: 'https://api.example.com/x',
          statusCode: 200,
          durationMs: 5,
          requestBodyBytes: 0,
          responseBodyBytes: 2,
          requestHeaders: {},
          responseHeaders: {},
          requestBody: null,
          responseBody: null,
          timestampMs: 0,
        );

    test('identify() emits an identify event and attaches external_id', () async {
      final sink = newSink();
      sink.identify('user_123', {'email': 'a@b.com', 'plan': 'pro'});
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bodies, isNotEmpty);
      final envelope = bodies.last;
      expect(envelope['external_id'], 'user_123');

      final events = (envelope['events'] as List).cast<Map<String, dynamic>>();
      final identifyEv = events.firstWhere((e) => e['kind'] == 'identify');
      expect(identifyEv['external_id'], 'user_123');
      expect(jsonEncode(identifyEv), isNot(contains('a@b.com')));
      expect(jsonEncode(identifyEv), contains('pro'));
    });

    test('empty externalId is a no-op (never throws)', () async {
      final sink = newSink();
      expect(() => sink.identify('', {'email': 'a@b.com'}), returnsNormally);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bodies, isEmpty);
    });

    test('external_id attaches to a subsequent normal event', () async {
      final sink = newSink();
      sink.identify('user_456');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      bodies.clear();

      sink.addNetwork(sampleEvent());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bodies, isNotEmpty);
      expect(bodies.last['external_id'], 'user_456');
    });

    test('setExperiment attaches experiments; null clears; bad input is a no-op', () async {
      final sink = newSink();
      sink.setExperiment('checkout_flow', 'variant_b');
      sink.addNetwork(sampleEvent());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bodies.last['experiments'], {'checkout_flow': 'variant_b'});

      expect(() => sink.setExperiment('', 'x'), returnsNormally); // bad input: no-op
      sink.setExperiment('checkout_flow', null);
      sink.addNetwork(sampleEvent());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bodies.last.containsKey('experiments'), isFalse);
    });
  });
}
