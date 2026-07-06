import 'package:drengr_flutter_native/drengr_flutter_native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const ctx = DrengrNativeContext(
    publishableKey: 'pk',
    ingestUrl: 'https://ingest.example',
    appPackage: 'com.example.app',
    installId: 'i-1',
    sessionId: 's-1',
  );

  tearDown(() {
    messenger.setMockMethodCallHandler(DrengrNative.channel, null);
  });

  test('start sends the identity payload and returns the platform bool',
      () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(DrengrNative.channel, (call) async {
      calls.add(call);
      return true;
    });
    expect(await DrengrNative.start(ctx), isTrue);
    expect(calls.single.method, 'start');
    final args = Map<String, Object?>.from(calls.single.arguments as Map);
    expect(args['install_id'], 'i-1');
    expect(args['session_id'], 's-1');
    expect(args['publishable_key'], 'pk');
    expect(args['ingest_url'], 'https://ingest.example');
    expect(args['app_package'], 'com.example.app');
    expect(args['max_body_bytes'], 64 * 1024);
  });

  test('start is fail-open when the platform throws', () async {
    messenger.setMockMethodCallHandler(DrengrNative.channel, (call) async {
      throw PlatformException(code: 'boom');
    });
    expect(await DrengrNative.start(ctx), isFalse);
  });

  test('updateSession reports false while native lacks the API', () async {
    messenger.setMockMethodCallHandler(
        DrengrNative.channel, (call) async => false);
    expect(await DrengrNative.updateSession('s-2'), isFalse);
    expect(await DrengrNative.updateSession(''), isFalse);
  });

  test('installUrlConnectionCapture passes through the platform bool',
      () async {
    messenger.setMockMethodCallHandler(
        DrengrNative.channel, (call) async => call.method ==
            'installUrlConnectionCapture');
    expect(await DrengrNative.installUrlConnectionCapture(), isTrue);
  });

  test('void mirrors never throw, even unimplemented', () async {
    messenger.setMockMethodCallHandler(DrengrNative.channel, (call) async {
      throw MissingPluginException();
    });
    await DrengrNative.setEnabled(false);
    await DrengrNative.optOut();
    await DrengrNative.optIn();
    await DrengrNative.identify('u-1', {'plan': 'pro'});
    await DrengrNative.setExperiment('exp', 'b');
    await DrengrNative.flush();
  });

  test('nativeEvent summaries from the platform feed the dedup window',
      () async {
    messenger.setMockMethodCallHandler(
        DrengrNative.channel, (call) async => true);
    await DrengrNative.start(ctx); // installs the native->Dart handler
    const codec = StandardMethodCodec();
    await messenger.handlePlatformMessage(
      'drengr_flutter_native',
      codec.encodeMethodCall(const MethodCall('nativeEvent', {
        'url': 'https://pay.example/charge',
        'method': 'POST',
        'ts_ms': 1000,
      })),
      (_) {},
    );
    expect(
        DrengrNative.dedup.admit('https://pay.example/charge', 'POST', 1200),
        isFalse);
    expect(
        DrengrNative.dedup.admit('https://pay.example/other', 'POST', 1200),
        isTrue);
  });

  test('malformed nativeEvent payloads are ignored', () async {
    messenger.setMockMethodCallHandler(
        DrengrNative.channel, (call) async => true);
    await DrengrNative.start(ctx);
    const codec = StandardMethodCodec();
    await messenger.handlePlatformMessage(
      'drengr_flutter_native',
      codec.encodeMethodCall(const MethodCall('nativeEvent', 'not-a-map')),
      (_) {},
    );
    expect(DrengrNative.dedup.admit('https://a.com/x', 'GET', 1000), isTrue);
  });
}
