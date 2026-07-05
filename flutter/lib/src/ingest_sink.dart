import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'network_event.dart';
import 'redact.dart';

class IngestSink {
  IngestSink({
    required this.url,
    required this.publishableKey,
    required this.context,
    this.maxBatch = 50,
    this.maxQueue = 500,
    this.flushInterval = const Duration(seconds: 10),
  }) {
    _restore();
  }

  final String url;
  final String publishableKey;
  final Map<String, dynamic> context;

  final int maxBatch;
  final int maxQueue;
  final Duration flushInterval;

  final Queue<Map<String, dynamic>> _queue = Queue();
  Timer? _timer;
  HttpClient? _client;
  bool _sending = false;

  int _retries = 0;
  static const Duration _baseBackoff = Duration(seconds: 2);
  static const Duration _maxBackoff = Duration(minutes: 5);

  File? _file;
  bool _persistScheduled = false;
  bool _persisting = false;

  void addNetwork(NetworkEvent e) => _enqueue(_toNet(e));

  Map<String, dynamic> _toNet(NetworkEvent e) {
    final status = e.statusCode ?? 0;
    final failed = e.errorText != null || status >= 400;
    final reqBody = projectBody(e.requestBody);
    final respBody = projectBody(e.responseBody);
    return {
      'kind': failed ? 'net_fail' : 'net',
      'event_id': _id(),
      'ts_ms': e.timestampMs,
      'method': e.method,
      'url': e.url,
      'status': status,
      'error_kind': failed
          ? (e.errorText != null
              ? 'transport'
              : (status >= 500 ? 'server' : 'client'))
          : '',
      'duration_ms': e.durationMs,
      'req_bytes': e.requestBodyBytes,
      'resp_bytes': e.responseBodyBytes,
      if (reqBody != null) 'req_body': reqBody,
      if (respBody != null) 'body': respBody,
    };
  }

  void _enqueue(Map<String, dynamic> ev) {
    _queue.addLast(ev);
    while (_queue.length > maxQueue) {
      _queue.removeFirst();
    }
    _schedulePersist();
    if (_retries > 0) return;
    if (_queue.length >= maxBatch) {
      _flush();
    } else {
      _timer ??= Timer(flushInterval, _flush);
    }
  }

  Future<void> _flush() async {
    _timer?.cancel();
    _timer = null;
    if (_sending || _queue.isEmpty) return;
    _sending = true;

    final batch = <Map<String, dynamic>>[];
    while (_queue.isNotEmpty && batch.length < 1000) {
      batch.add(_queue.removeFirst());
    }
    final envelope = <String, dynamic>{
      ...context,
      'sent_at_ms': DateTime.now().millisecondsSinceEpoch,
      'events': batch,
    };

    var acked = false;
    try {
      final client = _client ??= HttpOverrides.runWithHttpOverrides<HttpClient>(
        () => HttpClient()..connectionTimeout = const Duration(seconds: 10),
        _PlainOverrides(),
      );
      final req = await client.postUrl(Uri.parse(url));
      req.headers.set('authorization', 'Bearer $publishableKey');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(envelope));
      final resp = await req.close();
      acked = resp.statusCode >= 200 && resp.statusCode < 300;
      await resp.drain<void>();
    } catch (_) {
      acked = false;
    } finally {
      _sending = false;
      if (acked) {
        _retries = 0;
        _schedulePersist();
        if (_queue.isNotEmpty) _timer ??= Timer(flushInterval, _flush);
      } else {
        for (var i = batch.length - 1; i >= 0; i--) {
          _queue.addFirst(batch[i]);
        }
        while (_queue.length > maxQueue) {
          _queue.removeLast();
        }
        _schedulePersist();
        _armBackoff();
      }
    }
  }

  void _armBackoff() {
    _timer?.cancel();
    final exp = _baseBackoff.inMilliseconds * (1 << _retries.clamp(0, 20));
    final capped = min(exp, _maxBackoff.inMilliseconds);
    final delay = _baseBackoff.inMilliseconds + _rand.nextInt(capped);
    _retries++;
    _timer = Timer(Duration(milliseconds: delay), _flush);
  }

  File _queueFile() {
    return _file ??=
        File('${Directory.systemTemp.path}${Platform.pathSeparator}'
            '.drengr_queue.jsonl');
  }

  void _restore() {
    try {
      final f = _queueFile();
      if (!f.existsSync()) return;
      final lines = f.readAsLinesSync();
      for (final line in lines) {
        if (line.isEmpty) continue;
        try {
          final ev = jsonDecode(line);
          if (ev is Map<String, dynamic>) _queue.addLast(ev);
        } catch (_) {}
      }
      while (_queue.length > maxQueue) {
        _queue.removeFirst();
      }
      if (_queue.isNotEmpty) {
        _schedulePersist();
        _timer ??= Timer(flushInterval, _flush);
      }
    } catch (_) {}
  }

  void _schedulePersist() {
    if (_persistScheduled) return;
    _persistScheduled = true;
    scheduleMicrotask(_persist);
  }

  bool _persistDirty = false;

  Future<void> _persist() async {
    _persistScheduled = false;
    if (_persisting) {
      // don't reschedule while a write is in flight — it starves the event loop
      _persistDirty = true;
      return;
    }
    _persisting = true;
    try {
      do {
        _persistDirty = false;
        final snapshot = _queue.toList(growable: false);
        if (snapshot.isEmpty) {
          final f = _queueFile();
          if (await f.exists()) await f.delete();
        } else {
          final buf = StringBuffer();
          for (final ev in snapshot) {
            buf.writeln(jsonEncode(ev));
          }
          final f = _queueFile();
          final tmp = File('${f.path}.tmp');
          await tmp.writeAsString(buf.toString(), flush: true);
          await tmp.rename(f.path);
        }
      } while (_persistDirty);
    } catch (_) {
    } finally {
      _persisting = false;
    }
  }

  static final _rand = Random();
  static String _id() => List.generate(
      16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

class _PlainOverrides extends HttpOverrides {}
