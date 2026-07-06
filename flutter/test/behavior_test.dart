import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart' show Drengr, MemoryStore;
import 'package:drengr_flutter_sdk/src/behavior.dart';
import 'package:drengr_flutter_sdk/src/behavior_state.dart';
import 'package:drengr_flutter_sdk/src/navigator_observer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final events = <Map<String, dynamic>>[];

  List<Map<String, dynamic>> ofKind(String k) =>
      events.where((e) => e['kind'] == k).toList();

  setUp(() {
    events.clear();
    DrengrBehaviorState.reset();
    DrengrBehaviorState.emit = events.add;
  });

  tearDown(() {
    uninstallBehaviorCapture();
    DrengrBehaviorState.reset();
  });

  group('screen_view', () {
    testWidgets('push and pop-reveal emit with prev_screen', (tester) async {
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [DrengrNavigatorObserver()],
        routes: {
          '/': (_) => const Scaffold(body: Text('home')),
          '/detail': (_) => const Scaffold(body: Text('detail')),
        },
      ));
      expect(ofKind('screen_view').last['screen'], '/');

      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.pushNamed('/detail');
      await tester.pumpAndSettle();
      var v = ofKind('screen_view').last;
      expect(v['screen'], '/detail');
      expect(v['prev_screen'], '/');

      nav.pop();
      await tester.pumpAndSettle();
      v = ofKind('screen_view').last;
      expect(v['screen'], '/');
      expect(v['prev_screen'], '/detail');
    });

    testWidgets('unnamed page route falls back to route runtimeType',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [DrengrNavigatorObserver()],
        home: const Scaffold(body: Text('home')),
      ));
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('two'))));
      await tester.pumpAndSettle();
      expect(ofKind('screen_view').last['screen'], 'MaterialPageRoute');
    });
  });

  group('tap', () {
    testWidgets('button text label, normalized coords, screen context',
        (tester) async {
      installBehaviorCapture();
      DrengrBehaviorState.screen = 'checkout';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: ElevatedButton(onPressed: () {}, child: const Text('Buy now')),
          ),
        ),
      ));
      await tester.tap(find.text('Buy now'));
      await tester.pump();

      final tap = ofKind('tap').single;
      expect(tap['label'], 'Buy now');
      expect(tap['screen'], 'checkout');
      expect(tap['x'], closeTo(0.5, 0.05));
      expect(tap['y'], closeTo(0.5, 0.05));
      expect(ofKind('dead_tap'), isEmpty); // button is interactive
    });

    testWidgets('Semantics label wins over text content', (tester) async {
      installBehaviorCapture();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: Semantics(
              label: 'buy-button',
              child: ElevatedButton(
                  onPressed: () {}, child: const Text('Buy now')),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Buy now'));
      expect(ofKind('tap').single['label'], 'buy-button');
    });

    testWidgets('widget key wins over text content', (tester) async {
      installBehaviorCapture();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: GestureDetector(
              key: const ValueKey('cta'),
              onTap: () {},
              child: const Text('anything'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('anything'));
      final tap = ofKind('tap').single;
      expect(tap['label'], 'cta');
      expect(ofKind('dead_tap'), isEmpty); // GestureDetector.onTap handles it
    });

    testWidgets('non-interactive hit-path emits dead_tap', (tester) async {
      installBehaviorCapture();
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: Text('static text'))),
      ));
      await tester.tap(find.text('static text'));
      expect(ofKind('tap').single['label'], 'static text');
      expect(ofKind('dead_tap').single['label'], 'static text');
    });
  });

  group('rage_tap', () {
    testWidgets('burst of >=3 fast taps emits once; a gap breaks the burst',
        (tester) async {
      var now = 1000000;
      installBehaviorCapture(now: () => now);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(child: GestureDetector(onTap: () {}, child: const Text('mash'))),
        ),
      ));
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('mash'));
        now += 100;
      }
      expect(ofKind('tap'), hasLength(4));
      expect(ofKind('rage_tap'), hasLength(1)); // reported once per burst
      expect(ofKind('rage_tap').single['count'], 3);

      now += 5000; // gap: new burst
      await tester.tap(find.text('mash'));
      now += 100;
      await tester.tap(find.text('mash'));
      expect(ofKind('rage_tap'), hasLength(1)); // only 2 taps — no new rage
    });
  });

  group('crash', () {
    test('FlutterError.onError chains, ships type + first frame only', () {
      final prevCalls = <FlutterErrorDetails>[];
      final original = FlutterError.onError;
      FlutterError.onError = prevCalls.add;
      installBehaviorCapture();
      FlutterError.reportError(FlutterErrorDetails(
        exception: StateError('user email leak@example.com'),
        stack: StackTrace.current,
      ));
      FlutterError.reportError(FlutterErrorDetails(
        exception: ArgumentError('again'),
        stack: StackTrace.current,
      ));
      uninstallBehaviorCapture();
      FlutterError.onError = original;

      expect(prevCalls, hasLength(2)); // previous handler always chained
      final crash = ofKind('crash').single; // second throttled (<1s apart)
      expect(crash['exception_type'], 'StateError');
      expect(crash['message'], contains('behavior_test')); // first frame
      expect(crash['message'], isNot(contains('leak@example.com')));
    });

    test('PlatformDispatcher.onError chains and preserves the verdict', () {
      var prevCalled = 0;
      final original = PlatformDispatcher.instance.onError;
      PlatformDispatcher.instance.onError = (e, s) {
        prevCalled++;
        return true;
      };
      installBehaviorCapture();
      final handled = PlatformDispatcher.instance.onError!(
          Exception('boom'), StackTrace.current);
      uninstallBehaviorCapture();
      PlatformDispatcher.instance.onError = original;

      expect(handled, isTrue);
      expect(prevCalled, 1);
      expect(ofKind('crash').single['exception_type'], contains('Exception'));
    });
  });

  group('sink integration', () {
    test('behavior events flow through the ingest envelope', () async {
      final q = File('${Directory.systemTemp.path}'
          '${Platform.pathSeparator}.drengr_queue.jsonl');
      if (q.existsSync()) q.deleteSync();
      final envelopes = <Map<String, dynamic>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        envelopes.add(jsonDecode(await utf8.decoder.bind(req).join())
            as Map<String, dynamic>);
        req.response.statusCode = 202;
        await req.response.close();
      });
      Drengr.debugStore = MemoryStore();
      Drengr.start(
        publishableKey: 'drengr_pk_test',
        ingestUrl: 'http://127.0.0.1:${server.port}/ingest',
        appPackage: 'com.example.app',
      );
      DrengrBehaviorState.emit!({
        'kind': 'tap',
        'ts_ms': 42,
        'screen': 'checkout',
        'label': 'Buy now',
        'x': 0.5,
        'y': 0.25,
      });
      await Drengr.flush();
      Drengr.stop();
      Drengr.debugStore = null;
      await server.close(force: true);

      // Parallel test isolates share the default queue file — filter to ours.
      final shipped = envelopes
          .expand((env) => (env['events'] as List).cast<Map<String, dynamic>>())
          .singleWhere((e) => e['kind'] == 'tap' && e['label'] == 'Buy now');
      expect(shipped['kind'], 'tap');
      expect(shipped['event_id'], hasLength(32));
      expect(shipped['ts_ms'], 42);
      expect(shipped['screen'], 'checkout');
      expect(shipped['label'], 'Buy now');
      expect(shipped['x'], 0.5);
      expect(shipped['y'], 0.25);
    });
  });
}
