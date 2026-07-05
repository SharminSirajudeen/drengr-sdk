import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart';
import 'package:test/test.dart';

/// Reproduces capture against Dio's DEFAULT adapter (what real apps use) — the
/// device showed `resp 0B`, so this pins down whether Dio's response read path
/// is tee-d. Runs in its own file => fresh `HttpOverrides.global`.
void main() {
  test('Dio default adapter: response body is captured (not 0 bytes)',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"orderId":11831440,"token":"secret123"}');
      await req.response.close();
    });

    final events = <NetworkEvent>[];
    Drengr.start(onEvent: events.add);

    final dio = Dio();
    final resp = await dio.get('http://127.0.0.1:${server.port}/session');
    expect(resp.statusCode, 200);
    // App still receives the exact body — capture must never corrupt it.
    expect(resp.data.toString(), contains('secret123'));

    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(events, isNotEmpty, reason: 'HttpOverrides caught the Dio call');
    final e = events.last;
    expect(e.responseBodyBytes, greaterThan(0),
        reason: 'response body tee-d on Dio default-adapter read path');
    expect(e.responseBody, contains('orderId'));
    expect(e.responseBody, isNot(contains('secret123')),
        reason: 'sensitive token value redacted in the stored copy');

    await server.close(force: true);
  });
}
