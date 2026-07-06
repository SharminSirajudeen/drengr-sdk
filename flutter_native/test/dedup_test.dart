import 'package:drengr_flutter_native/drengr_flutter_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NetworkDedup', () {
    test('admits everything when nothing native was seen', () {
      final d = NetworkDedup();
      expect(d.admit('https://a.com/x', 'GET', 1000), isTrue);
    });

    test('drops a Dart event matching a native summary within 500ms', () {
      final d = NetworkDedup();
      d.recordNative('https://a.com/x', 'GET', 1000);
      expect(d.admit('https://a.com/x', 'GET', 1000), isFalse);
      expect(d.admit('https://a.com/x', 'GET', 1500), isFalse);
      expect(d.admit('https://a.com/x', 'get', 1400), isFalse);
    });

    test('admits outside the 500ms window', () {
      final d = NetworkDedup();
      d.recordNative('https://a.com/x', 'GET', 1000);
      expect(d.admit('https://a.com/x', 'GET', 1501), isTrue);
    });

    test('matches within the window even when the Dart event is earlier', () {
      final d = NetworkDedup();
      d.recordNative('https://a.com/x', 'GET', 1000);
      expect(d.admit('https://a.com/x', 'GET', 600), isFalse);
    });

    test('different method or url is not a duplicate', () {
      final d = NetworkDedup();
      d.recordNative('https://a.com/x', 'GET', 1000);
      expect(d.admit('https://a.com/x', 'POST', 1000), isTrue);
      expect(d.admit('https://a.com/y', 'GET', 1000), isTrue);
    });

    test('evicts stale entries as time advances', () {
      final d = NetworkDedup();
      d.recordNative('https://a.com/x', 'GET', 1000);
      d.recordNative('https://a.com/y', 'GET', 5000);
      expect(d.size, 1);
    });

    test('caps remembered entries', () {
      final d = NetworkDedup(maxEntries: 4);
      for (var i = 0; i < 10; i++) {
        d.recordNative('https://a.com/$i', 'GET', 1000);
      }
      expect(d.size, 4);
      expect(d.admit('https://a.com/9', 'GET', 1000), isFalse);
      expect(d.admit('https://a.com/0', 'GET', 1000), isTrue);
    });

    test('empty url summaries are ignored', () {
      final d = NetworkDedup();
      d.recordNative('', 'GET', 1000);
      expect(d.size, 0);
    });
  });
}
