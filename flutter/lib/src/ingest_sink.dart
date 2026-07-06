import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'classify.dart';
import 'network_event.dart';
import 'redact.dart';

/// Batches captured signals and ships them to the Drengr ingest endpoint,
/// authenticated by a publishable key.
///
/// Best-effort and non-blocking by design: it never throws into the app, drops
/// the oldest events on overflow, and its own POSTs are structurally invisible
/// to capture (the delivery client is built under plain HttpOverrides), so it
/// can never recurse — no ignoreHosts wiring needed.
///
/// Durability: the queue is mirrored to a JSONL file under [Directory.systemTemp]
/// and reloaded on construction, so an app kill/crash doesn't lose buffered
/// events. A failed flush is retried with exponential backoff + jitter and the
/// batch is kept (in memory + on disk) until a 2xx ack. All disk I/O is async
/// and failure-tolerant — it never blocks the UI isolate and never throws.
class IngestSink {
  IngestSink({
    required this.url,
    required this.publishableKey,
    required this.context,
    this.maxBatch = 50,
    this.maxQueue = 500,
    this.flushInterval = const Duration(seconds: 10),
    String? queuePath,
  }) : _queuePath = queuePath {
    _restore(); // best-effort reload of any queue persisted before an app kill
  }

  /// Full ingest URL, e.g. `https://<ref>.supabase.co/functions/v1/ingest`.
  final String url;

  /// Publishable key (`drengr_pk_…`) sent as `Authorization: Bearer`.
  final String publishableKey;

  /// Shared envelope context (app_package, os, install_id, session_id, …).
  final Map<String, dynamic> context;

  final int maxBatch;
  final int maxQueue;
  final Duration flushInterval;

  final Queue<Map<String, dynamic>> _queue = Queue();
  Timer? _timer;
  HttpClient? _client;

  // Session-scoped identity/experiment state, merged into every envelope (see _flush()).
  String? _externalId;
  final Map<String, String> _experiments = {};
  bool _sending = false;

  // --- Retry state (exponential backoff + jitter on a failed flush) ---
  int _retries = 0;
  static const Duration _baseBackoff = Duration(seconds: 2);
  static const Duration _maxBackoff = Duration(minutes: 5);

  // --- Disk persistence ---
  // Single JSONL file (one event per line) under systemTemp. Bounded to the
  // same maxQueue as memory; oldest lines are dropped on rewrite.
  final String? _queuePath; // override for isolation (tests / multiple sinks)
  File? _file;
  bool _persistScheduled = false;
  bool _persisting = false;

  /// Map a captured exchange to an ingest event and enqueue it. Every completed
  /// exchange is emitted (`net_fail` on failure, else `net`) carrying method,
  /// url, status, duration, byte counts, and the projected request + response
  /// bodies — so the dashboard can answer endpoint volume / latency / outcome.
  void addNetwork(NetworkEvent e) => _enqueue(_toNet(e));

  /// Enqueue a pre-built behavior event (screen_view/tap/rage_tap/dead_tap/
  /// crash). Fills event_id/ts_ms when absent. Fail-open.
  void addBehavior(Map<String, dynamic> ev) {
    try {
      _enqueue({
        'event_id': _id(),
        'ts_ms': DateTime.now().millisecondsSinceEpoch,
        ...ev,
      });
    } catch (_) {/* never throw into the app */}
  }

  /// Sets external_id — your own stable, non-PII user id (not an email) — on the
  /// session and all events hereafter; emits one identify event. [traits] go
  /// through the same redact+project pipeline as bodies. Fail-open: no-op on an
  /// empty externalId.
  void identify(String externalId, [Map<String, dynamic> traits = const {}]) {
    if (externalId.isEmpty) return;
    String? redactedTraits;
    try {
      if (traits.isNotEmpty) redactedTraits = classifyBody(redactBody(jsonEncode(traits))).projection;
    } catch (_) {/* bad traits: ship identify without them */}
    try {
      _externalId = externalId;
      _enqueue({
        'kind': 'identify',
        'event_id': _id(),
        'ts_ms': DateTime.now().millisecondsSinceEpoch,
        'external_id': externalId,
        if (redactedTraits != null) 'traits': redactedTraits,
      });
    } catch (_) {/* never throw into the app */}
  }

  /// Sets/clears a session-scoped experiment variant (all events hereafter, as
  /// `experiments`). A null/empty [variant] clears [key]. Fail-open.
  void setExperiment(String key, String? variant) {
    if (key.isEmpty) return;
    try {
      if (variant == null || variant.isEmpty) {
        _experiments.remove(key);
      } else {
        _experiments[key] = variant;
      }
    } catch (_) {/* never throw into the app */}
  }

  /// Force-drain the queue now, waiting out any in-flight send. Best-effort:
  /// stops when the queue is empty or a send fails (backoff takes over).
  Future<void> flush() async {
    try {
      for (var i = 0; i < 200 && _sending; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      var lastLen = -1;
      while (_queue.isNotEmpty && _queue.length != lastLen) {
        lastLen = _queue.length;
        await _flush();
      }
    } catch (_) {/* never throw into the app */}
  }

  static const int _maxHeaderEntries = 48;
  static const int _maxHeadersBytes = 8192;

  /// Already-redacted headers → capped map: ≤48 entries, {} if JSON > 8 KB.
  static Map<String, String> _headersEnvelope(Map<String, String> h) {
    try {
      final out = <String, String>{};
      for (final entry in h.entries) {
        if (out.length >= _maxHeaderEntries) break;
        out[entry.key] = entry.value;
      }
      if (utf8.encode(jsonEncode(out)).length > _maxHeadersBytes) {
        return const {};
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  Map<String, dynamic> _toNet(NetworkEvent e) {
    final status = e.statusCode ?? 0;
    final failed = e.errorText != null || status >= 400;
    // Every completed exchange is signal (endpoint volume / latency / outcome),
    // so always emit — and carry the REQUEST side (method + projected request
    // body), not just the response. Seal-by-default: free-text PII that value-
    // scrubbing can't pattern-match is sealed to a typed placeholder, not shipped.
    final reqBody = classifyBody(e.requestBody).projection;
    final respBody = classifyBody(e.responseBody).projection;
    return {
      'kind': failed ? 'net_fail' : 'net',
      'event_id': _id(),
      'ts_ms': e.timestampMs,
      'method': e.method,
      'url': e.url, // already redacted by the capture layer
      'status': status,
      'error_kind': failed
          ? (e.errorText != null
              ? 'transport'
              : (status >= 500 ? 'server' : 'client'))
          : '',
      'duration_ms': e.durationMs,
      'req_bytes': e.requestBodyBytes,
      'resp_bytes': e.responseBodyBytes,
      'req_headers': _headersEnvelope(e.requestHeaders),
      'resp_headers': _headersEnvelope(e.responseHeaders),
      if (reqBody != null) 'req_body': reqBody,
      if (respBody != null) 'body': respBody,
    };
  }

  void _enqueue(Map<String, dynamic> ev) {
    _queue.addLast(ev);
    while (_queue.length > maxQueue) {
      _queue.removeFirst(); // drop oldest on overflow — never block
    }
    _schedulePersist();
    // While retrying after a failure, let the backoff timer drive the flush.
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
    // sent_at_ms = device clock AT SEND: the server derives the device's clock
    // error from it (receipt − sent_at) and corrects timeline placement exactly.
    // Set per attempt, so a retried batch stays accurate.
    final envelope = <String, dynamic>{
      ...context,
      'sent_at_ms': DateTime.now().millisecondsSinceEpoch,
      'events': batch,
      if (_externalId != null) 'external_id': _externalId,
      if (_experiments.isNotEmpty) 'experiments': Map.of(_experiments),
    };

    var acked = false;
    var permanent = false;
    try {
      // Built under plain overrides: the sink's own delivery must be invisible
      // to capture, or every flush re-captures itself — an unbounded event loop.
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
      // Non-retriable 4xx (revoked key 401, bad batch 400/413) never succeeds —
      // retrying forever head-of-line-blocks the queue. Drop it. 429/408 retry.
      final c = resp.statusCode;
      permanent = c >= 400 && c < 500 && c != 429 && c != 408;
      await resp.drain<void>();
    } catch (_) {
      acked = false; // best-effort: never throw into the app
    } finally {
      _sending = false;
      if (acked || permanent) {
        // Delivered — clear retry state and persist the shrunken queue.
        _retries = 0;
        _schedulePersist();
        if (_queue.isNotEmpty) _timer ??= Timer(flushInterval, _flush);
      } else {
        // Keep the batch: re-queue at the front (in memory + on disk) and
        // re-arm a backoff timer. Don't drop, don't throw.
        for (var i = batch.length - 1; i >= 0; i--) {
          _queue.addFirst(batch[i]);
        }
        while (_queue.length > maxQueue) {
          _queue.removeLast(); // overflow: shed newest, keep the retry batch
        }
        _schedulePersist();
        _armBackoff();
      }
    }
  }

  void _armBackoff() {
    _timer?.cancel();
    // Exponential backoff capped at _maxBackoff, with full jitter.
    final exp = _baseBackoff.inMilliseconds * (1 << _retries.clamp(0, 20));
    final capped = min(exp, _maxBackoff.inMilliseconds);
    final delay = _baseBackoff.inMilliseconds + _rand.nextInt(capped);
    _retries++;
    _timer = Timer(Duration(milliseconds: delay), _flush);
  }

  // --- Disk persistence helpers (all best-effort, never throw) ---

  File _queueFile() {
    return _file ??= File(_queuePath ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
            '.drengr_queue.jsonl');
  }

  /// Reload events persisted before an app kill. Tolerates a missing or corrupt
  /// file; skips unparseable lines. Synchronous read on construction is bounded
  /// by maxQueue and only runs once, off the hot path.
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
        } catch (_) {
          // skip corrupt line
        }
      }
      while (_queue.length > maxQueue) {
        _queue.removeFirst();
      }
      if (_queue.isNotEmpty) {
        _schedulePersist(); // normalize file (drop corrupt/overflow lines)
        _timer ??= Timer(flushInterval, _flush);
      }
    } catch (_) {
      // fail safe: start with an empty queue
    }
  }

  /// Coalesce rapid mutations into one async rewrite so the UI isolate is never
  /// blocked by repeated disk writes.
  void _schedulePersist() {
    if (_persistScheduled) return;
    _persistScheduled = true;
    scheduleMicrotask(_persist);
  }

  bool _persistDirty = false;

  Future<void> _persist() async {
    _persistScheduled = false;
    if (_persisting) {
      // A write is in flight. Mark dirty and RETURN — the writer re-snapshots
      // in its own loop. (Rescheduling a microtask here starves the event loop:
      // the in-flight write's completion can then never be delivered, spinning
      // the isolate at 100% forever. Found via the demo-app burst freeze.)
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
          // Atomic-ish replace: write a temp file then rename over the target.
          final f = _queueFile();
          final tmp = File('${f.path}.tmp');
          await tmp.writeAsString(buf.toString(), flush: true);
          await tmp.rename(f.path);
        }
      } while (_persistDirty);
    } catch (_) {
      // best-effort: a failed persist must never throw or block
    } finally {
      _persisting = false;
    }
  }

  static final _rand = Random();
  static String _id() => List.generate(
      16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Default platform HTTP behavior — used so the sink escapes any capturing
/// [HttpOverrides.global] installed by [Drengr.start].
class _PlainOverrides extends HttpOverrides {}
