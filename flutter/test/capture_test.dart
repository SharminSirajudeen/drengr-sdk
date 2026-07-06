import 'dart:convert';
import 'dart:io';

import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart';
import 'package:drengr_flutter_sdk/src/redact.dart';
import 'package:test/test.dart';

void main() {
  group('redaction', () {
    test('masks sensitive headers, preserves the rest', () {
      final r = redactHeaders(
          {'Authorization': 'Bearer x', 'Accept': 'json'}, const {});
      expect(r['Authorization'], redactMask);
      expect(r['Accept'], 'json');
    });

    test('PAN: contiguous, spaced, dashed, and embedded are all redacted', () {
      expect(redactBody('{"card":"4111111111111111"}'),
          isNot(contains('4111111111111111')));
      expect(redactBody('{"card":"4111 1111 1111 1111"}'),
          contains('[REDACTED-PAN]'));
      expect(redactBody('{"card":"4111-1111-1111-1111"}'),
          contains('[REDACTED-PAN]'));
      // Embedded in a longer digit run (the \b-boundary gap).
      expect(redactBody('{"x":"99941111111111111199"}'),
          contains('[REDACTED-PAN]'));
      // A non-card number is NOT over-redacted.
      expect(redactBody('{"orderId":11831440}'), contains('11831440'));
    });

    test('JSON sensitive fields masked wholesale (commas/spaces safe)', () {
      expect(redactBody('{"password":"a,b,c"}'), isNot(contains('a,b,c')));
      expect(redactBody('{"secret":"  hidden  "}'), isNot(contains('hidden')));
      expect(redactBody('{"payment_session_token":"abc","orderId":1}'),
          allOf(contains(redactMask), contains('orderId')));
    });

    test('short tokens do not over-redact (shipping/spinner/opinion)', () {
      expect(redactBody('{"shipping":"123 Main St"}'), contains('123 Main St'));
      expect(redactBody('{"opinion":"yes"}'), contains('yes'));
    });

    test('form-urlencoded: sensitive keys masked, others preserved', () {
      final out = redactBody('user=bob&password=hunter2&token=xyz&keep=ok');
      expect(out, isNot(contains('hunter2')));
      expect(out, isNot(contains('xyz')));
      expect(out, contains('user=bob'));
      expect(out, contains('keep=ok'));
    });

    test('cookie lines and JWTs in a plain body are scrubbed', () {
      expect(redactBody('Set-Cookie: session=abc123; HttpOnly'),
          isNot(contains('abc123')));
      const jwt =
          'eyJ0eXAiOiJKV1QiLCJhbGc.eyJzdWIiOiIxMjM0NTY3.SflKxwRJSMeKKF2QT4';
      expect(redactBody('tok=$jwt'), isNot(contains(jwt)));
    });

    test('opaque vendor secrets under a benign key are scrubbed; publishable kept',
        () {
      final b = redactBody('{"data":"sk_live_abcdef0123456789ABCDEF",'
          '"note":"AKIAIOSFODNN7EXAMPLE","orderId":"order_12345","amount":25}');
      expect(b, isNot(contains('sk_live_abcdef')));
      expect(b, isNot(contains('AKIAIOSFODNN7EXAMPLE')));
      expect(b, contains('REDACTED-SECRET'));
      expect(b, contains('order_12345')); // benign id survives
      expect(b, contains('25'));
      // publishable keys are public by design — must NOT be nuked
      expect(scrubValues('pk_live_51H8xYzPublishableKey'),
          'pk_live_51H8xYzPublishableKey');
    });

    test('URL: query, fragment, and path secrets redacted; benign preserved',
        () {
      final q = redactUrl('https://x.com/p?token=supersecret&ok=1');
      expect(q, isNot(contains('supersecret')));
      expect(q, contains('ok=1'));
      expect(redactUrl('https://x.com/cb#access_token=leaked123&state=ok'),
          isNot(contains('leaked123')));
      expect(redactUrl('https://api.example.com/cards/4111111111111111/charge'),
          contains('[REDACTED-PAN]'));
    });

    test('name-sensitive values survive when structural parse fails', () {
      // Truncated JSON (sliced past the cap → parse fails): field-name pass skipped.
      final trunc = '{"user":"joe","password":"hunter2secret",'
          '"address":"221B Baker St","note":"${'x' * 40}';
      final rt = redactBody(trunc);
      expect(rt, isNot(contains('hunter2secret')));
      expect(rt, isNot(contains('221B Baker St')));
      // XML / SOAP element + attribute forms.
      final xml = redactBody('<Login><password>hunter2secret</password>'
          '<address>221B Baker St</address></Login>');
      expect(xml, isNot(contains('hunter2secret')));
      expect(xml, isNot(contains('221B Baker St')));
      expect(redactBody('<login user="joe" password="hunter2secret" />'),
          isNot(contains('hunter2secret')));
      // GraphQL inline literal inside a valid-JSON body (leaks via the happy path).
      final gql = redactBody('{"query":"mutation { login(email:\\"a@b.com\\", '
          'password:\\"hunter2secret\\") }"}');
      expect(gql, isNot(contains('hunter2secret')));
      expect(gql, isNot(contains('a@b.com')));
      // GraphQL where the sensitive arg is FIRST (wrapper would orphan it).
      expect(
          redactBody('{"query":"mutation { login(password:\\"hunter2secret\\", '
              'note:\\"x\\") }"}'),
          isNot(contains('hunter2secret')));
      // Truncated JSON with a numeric secret.
      expect(redactBody('{"ok":true,"cvv":4321,"amount":25'),
          isNot(contains('4321')));
    });

    test('scrubNamedValues idempotent + preserves non-sensitive', () {
      final once =
          scrubNamedValues('{"password":"x","amount":25,"city":"Paris"}');
      expect(scrubNamedValues(once), once);
      expect(once, contains('"amount":25'));
      expect(once, contains('"city":"Paris"'));
    });
  });

  group('capture', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async {
      Drengr.stop();
      await server.close(force: true);
    });

    String url(String path) => 'http://127.0.0.1:${server.port}$path';

    test('captures a request with NO app code; bytes unaltered; secret masked',
        () async {
      server.listen((req) async {
        final body = await utf8.decoder.bind(req).join();
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"echo":$body}');
        await req.response.close();
      });
      final events = <NetworkEvent>[];
      Drengr.start(onEvent: events.add);

      final client = HttpClient();
      final req = await client.postUrl(Uri.parse(url('/pay')));
      req.headers.contentType = ContentType.json;
      req.headers.set('authorization', 'Bearer tok_secret');
      req.write('{"amount":4200}');
      final resp = await req.close();
      final received = await utf8.decoder.bind(resp).join();

      expect(received, '{"echo":{"amount":4200}}'); // app gets exact bytes
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final e = events.last;
      expect(e.method, 'POST');
      expect(e.statusCode, 200);
      expect(e.requestBody, contains('4200'));
      expect(e.responseBody, contains('echo'));
      expect(e.requestHeaders['authorization'], redactMask);
    });

    test('drain() (fire-and-forget) still emits an event', () async {
      server.listen((req) async {
        req.response.statusCode = 204;
        await req.response.close();
      });
      final events = <NetworkEvent>[];
      Drengr.start(onEvent: events.add);
      final client = HttpClient();
      final resp = await (await client.getUrl(Uri.parse(url('/x')))).close();
      await resp.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events, isNotEmpty);
      expect(events.last.statusCode, 204);
    });

    test('a response-stream error still emits an event with errorText',
        () async {
      // Declares gzip but sends invalid bytes -> the body errors on read,
      // after headers (and close()) succeed.
      server.listen((req) async {
        req.response.headers.set('content-encoding', 'gzip');
        req.response.add([0, 1, 2, 3, 4]);
        await req.response.close();
      });
      final events = <NetworkEvent>[];
      Drengr.start(onEvent: events.add);
      final client = HttpClient(); // autoUncompress defaults to true
      final resp = await (await client.getUrl(Uri.parse(url('/err')))).close();
      try {
        await resp.drain<void>();
      } catch (_) {/* app sees the error */}
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events, isNotEmpty);
      expect(events.last.errorText, isNotNull);
    });

    test('ignoreHosts passes through unwrapped (no event)', () async {
      server.listen((req) async {
        req.response
          ..statusCode = 200
          ..write('ok');
        await req.response.close();
      });
      final events = <NetworkEvent>[];
      Drengr.start(onEvent: events.add, ignoreHosts: {'127.0.0.1'});
      final resp =
          await (await HttpClient().getUrl(Uri.parse(url('/y')))).close();
      await resp.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events, isEmpty);
    });

    test('enabled:false captures nothing until setEnabled(true)', () async {
      server.listen((req) async {
        req.response
          ..statusCode = 200
          ..write('ok');
        await req.response.close();
      });
      final events = <NetworkEvent>[];
      Drengr.start(onEvent: events.add, enabled: false);
      var resp =
          await (await HttpClient().getUrl(Uri.parse(url('/a')))).close();
      await resp.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(events, isEmpty);

      Drengr.setEnabled(true);
      resp = await (await HttpClient().getUrl(Uri.parse(url('/b')))).close();
      await resp.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events, isNotEmpty);
    });

    test('body over cap is truncated; true size still reported', () async {
      final big = 'x' * 5000;
      server.listen((req) async {
        req.response
          ..statusCode = 200
          ..write(big);
        await req.response.close();
      });
      final events = <NetworkEvent>[];
      Drengr.start(onEvent: events.add, maxBodyBytes: 1000);
      final resp =
          await (await HttpClient().getUrl(Uri.parse(url('/big')))).close();
      await utf8.decoder.bind(resp).join();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events.last.responseBodyBytes, 5000);
      expect(events.last.responseBody, contains('truncated'));
    });

    test('second start() is a no-op (first sink wins)', () async {
      server.listen((req) async {
        req.response
          ..statusCode = 200
          ..write('ok');
        await req.response.close();
      });
      final first = <NetworkEvent>[];
      final second = <NetworkEvent>[];
      Drengr.start(onEvent: first.add);
      Drengr.start(onEvent: second.add);
      final resp =
          await (await HttpClient().getUrl(Uri.parse(url('/c')))).close();
      await resp.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(first, isNotEmpty);
      expect(second, isEmpty);
    });
  });
}
