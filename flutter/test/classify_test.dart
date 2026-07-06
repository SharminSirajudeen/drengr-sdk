import 'dart:convert';

import 'package:drengr_flutter_sdk/src/classify.dart';
import 'package:drengr_flutter_sdk/src/redact.dart';
import 'package:test/test.dart';

void main() {
  group('classify (seal-by-default)', () {
    test('fail-closed: planted PII never reaches the projection', () {
      final body = jsonEncode({
        'email': 'alice@example.com',
        'phone': '+1 415-555-1212',
        'ssn': '123-45-6789',
        'ip': '192.168.1.42',
        'deviceId': 'AB12CD34-1234-5678-9ABC-DEF012345678',
        'fullName': 'Alice Robinson',
        'address': '221B Baker Street',
        'password': 'hunter2secret',
        'note': 'free text that could hide alice@example.com',
        'amount': 4200,
        'currency': 'USD',
        'success': true,
        'status': 'ok',
      });
      final c = classifyBody(body);
      final proj = c.projection!;
      for (final leak in <String>[
        'alice@example.com',
        '415-555-1212',
        '123-45-6789',
        '192.168.1.42',
        'AB12CD34-1234-5678-9ABC-DEF012345678',
        'Alice Robinson',
        '221B Baker Street',
        'hunter2secret',
        'free text',
      ]) {
        expect(proj, isNot(contains(leak)), reason: 'leaked $leak');
      }
      final m = jsonDecode(proj) as Map<String, dynamic>;
      // Business signal survives plaintext.
      expect(m['amount'], 4200);
      expect(m['currency'], 'USD');
      expect(m['success'], true);
      expect(m['status'], 'ok');
      // Typed placeholder keeps leaf type stable (string field -> string).
      expect(m['email'], isA<String>());
      // Credential is dropped, not sealed.
      expect(c.piiPaths, isNot(contains('password')));
      // PII paths are collected (for the encrypt layer) but not shipped here.
      expect(c.piiPaths, contains('email'));
    });

    test('typed placeholder preserves number/bool type under a PII name', () {
      final c = classifyBody(jsonEncode({'lat': 37.77, 'geo': true}));
      final m = jsonDecode(c.projection!) as Map<String, dynamic>;
      expect(m['lat'], 0); // number -> 0
      expect(m['geo'], false); // bool -> false
    });

    test('credential value under a benign name is dropped, never sealed', () {
      final c = classifyBody(
          jsonEncode({'data': 'sk_live_abcdef0123456789ABCDEF', 'orderId': 7}));
      final proj = c.projection!;
      expect(proj, contains('[REDACTED-SECRET]'));
      expect(proj, isNot(contains('sk_live_abcdef')));
      expect(c.piiPaths, isEmpty);
      final m = jsonDecode(proj) as Map<String, dynamic>;
      expect(m['orderId'], 7);
    });

    test('form-encoded seals PII by default, keeps allowlisted', () {
      final c = classifyBody('email=a%40b.com&status=ok&amount=25');
      final proj = c.projection!;
      expect(proj, isNot(contains('a@b.com')));
      expect(proj, isNot(contains('a%40b.com')));
      final m = jsonDecode(proj) as Map<String, dynamic>;
      expect(m['status'], 'ok');
    });

    test('empty / non-structured bodies yield an empty split', () {
      expect(classifyBody(null).projection, isNull);
      expect(classifyBody('').projection, isNull);
      expect(classifyBody('plain hello world').projection, isNull);
    });
  });

  group('redaction hardening (IPv4 + UUID + header names)', () {
    test('scrubValues masks IPv4 and UUID anywhere in text', () {
      expect(scrubValues('client 192.168.1.42 connected'),
          isNot(contains('192.168.1.42')));
      expect(scrubValues('id=AB12CD34-1234-5678-9ABC-DEF012345678'),
          isNot(contains('AB12CD34-1234-5678-9ABC-DEF012345678')));
    });

    test('redactHeaders masks PII-denoting names AND scrubs PII values', () {
      final r = redactHeaders({
        'X-User-Phone': 'bob', // PII by name -> full mask
        'X-Client-IP': '192.168.1.42', // PII by value under benign name
        'X-Device-Id': 'AB12CD34-1234-5678-9ABC-DEF012345678',
        'Accept': 'application/json',
      }, const {});
      expect(r['X-User-Phone'], redactMask);
      expect(r['X-Client-IP'], isNot(contains('192.168.1.42')));
      expect(
          r['X-Device-Id'], isNot(contains('AB12CD34-1234-5678-9ABC-DEF012345678')));
      expect(r['Accept'], 'application/json');
    });
  });
}
