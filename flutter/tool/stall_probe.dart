// Repro probe for the streamed-body stall (2026-07-02). Pure dart:io — run:
//   dart run tool/stall_probe.dart
// Fetches a small webp + a JSON URL through the capturing overrides and reports
// whether each consumer completes within 8s. No Flutter needed.
import 'dart:async';
import 'dart:io';

import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart';

Future<String> fetch(String url) async {
  final client = HttpClient();
  final req = await client.getUrl(Uri.parse(url));
  final resp = await req.close();
  var bytes = 0;
  final done = Completer<String>();
  final sub = resp.listen(
    (chunk) => bytes += chunk.length,
    onDone: () => done.complete('OK $bytes bytes'),
    onError: (e) => done.complete('ERR $e'),
  );
  final result = await done.future
      .timeout(const Duration(seconds: 8), onTimeout: () => 'STALLED after $bytes bytes');
  await sub.cancel();
  client.close(force: true);
  return result;
}

Future<String> fetchPaused(String url) async {
  final client = HttpClient();
  final req = await client.getUrl(Uri.parse(url));
  final resp = await req.close();
  var bytes = 0;
  final done = Completer<String>();
  late StreamSubscription<List<int>> sub;
  sub = resp.listen(
    (chunk) {
      bytes += chunk.length;
      sub.pause();                       // consolidate-style backpressure
      Future<void>.delayed(Duration.zero, sub.resume);
    },
    onDone: () => done.complete('OK $bytes bytes (cl=${resp.contentLength}, cs=${resp.compressionState})'),
    onError: (e) => done.complete('ERR $e'),
  );
  final result = await done.future
      .timeout(const Duration(seconds: 8), onTimeout: () => 'STALLED after $bytes bytes');
  await sub.cancel();
  client.close(force: true);
  return result;
}

Future<void> main() async {
  const img = 'https://cdn.dummyjson.com/product-images/beauty/essence-mascara-lash-princess/thumbnail.webp';
  const json = 'https://dummyjson.com/products?limit=2';

  stdout.writeln('--- capture OFF ---');
  stdout.writeln('img : ${await fetch(img)}');
  stdout.writeln('json: ${await fetch(json)}');

  Drengr.start(onEvent: (e) {});
  stdout.writeln('--- capture ON ---');
  stdout.writeln('img : ${await fetch(img)}');
  stdout.writeln('json: ${await fetch(json)}');
  stdout.writeln('--- capture ON, paused consumer ---');
  stdout.writeln('img : ${await fetchPaused(img)}');
  stdout.writeln('--- capture ON, 6 concurrent paused ---');
  final six = await Future.wait(List.generate(6, (_) => fetchPaused(img)));
  for (final r in six) {
    stdout.writeln('     $r');
  }

  // The real app wiring: sink attached → persistence scheduler in the loop.
  Drengr.stop();
  final sink = IngestSink(
    url: 'https://ziryfxrwrvnunwjupgfg.supabase.co/functions/v1/ingest',
    publishableKey: 'drengr_pk_probe_invalid',
    context: {'app_package': 'probe', 'install_id': 'probe'},
  );
  Drengr.start(onEvent: sink.addNetwork);
  stdout.writeln('--- capture ON + IngestSink, 6 concurrent (burst) ---');
  final burst = await Future.wait(List.generate(6, (_) => fetch(img)));
  for (final r in burst) {
    stdout.writeln('     $r');
  }
  stdout.writeln('PROBE-COMPLETE');
  exit(0);
}
