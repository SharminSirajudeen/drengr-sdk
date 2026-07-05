import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'network_event.dart';
import 'redact.dart';

/// Per-isolate capture config, bounded event ring, and sink.
class DrengrCapture {
  DrengrCapture({
    required this.maxBodyBytes,
    required this.redactHeaderNames,
    required this.ignoreHosts,
    required this.logBodies,
    required this.enabled,
    this.captureWhen,
    void Function(NetworkEvent)? onEvent,
  }) : _onEvent = onEvent;

  /// The active config for this isolate, or null when not installed.
  static DrengrCapture? instance;

  /// Whether capture is installed in this isolate.
  static bool get installed => instance != null;

  final int maxBodyBytes;
  final Set<String> redactHeaderNames;
  final Set<String> ignoreHosts;

  /// Whether the default sink also logs (redacted) bodies, not just metadata.
  final bool logBodies;

  /// Capture/emit gate (consent). Mutable so it can be toggled at runtime.
  bool enabled;

  /// Optional per-request predicate (sampling / allow-listing).
  final bool Function(Uri url)? captureWhen;

  final void Function(NetworkEvent)? _onEvent;

  static const _ringMax = 200;

  /// Recent events (bounded), newest last.
  final Queue<NetworkEvent> ring = Queue<NetworkEvent>();

  /// Whether [url]'s host is on the ignore list (exact or subdomain).
  bool ignored(Uri url) {
    final h = url.host.toLowerCase();
    for (final s in ignoreHosts) {
      final t = s.toLowerCase();
      if (h == t || h.endsWith('.$t')) return true;
    }
    return false;
  }

  /// Record an event: ring + sink. No-op when disabled.
  void emit(NetworkEvent e) {
    if (!enabled) return;
    ring.addLast(e);
    while (ring.length > _ringMax) {
      ring.removeFirst();
    }
    final onEvent = _onEvent;
    if (onEvent != null) {
      try {
        onEvent(e);
      } catch (_) {}
    } else {
      _log(e);
    }
  }

  void _log(NetworkEvent e) {
    // Default sink: metadata only. Bodies (even redacted) are not written to the
    // system log unless logBodies is explicitly enabled.
    // ignore: avoid_print
    print('DRENGR ${e.method} ${e.url} '
        '-> ${e.statusCode ?? e.errorText ?? '-'} '
        '(${e.durationMs}ms, req ${e.requestBodyBytes}B, resp ${e.responseBodyBytes}B)');
    if (logBodies) {
      final rb = e.requestBody;
      // ignore: avoid_print
      if (rb != null && rb.isNotEmpty) print('DRENGR   req body: $rb');
      final sb = e.responseBody;
      // ignore: avoid_print
      if (sb != null && sb.isNotEmpty) print('DRENGR   resp body: $sb');
    }
  }

  /// Mask sensitive header values (built-ins + configured extras).
  Map<String, String> redact(Map<String, String> headers) =>
      redactHeaders(headers, redactHeaderNames);
}

/// Treat a body as text when the content-type is textual or absent (forms /
/// JSON sent without an explicit header).
bool isTextual(ContentType? ct) {
  if (ct == null) return true;
  final mime = ct.mimeType.toLowerCase();
  return mime.startsWith('text/') ||
      mime.contains('json') ||
      mime.contains('xml') ||
      mime.contains('x-www-form-urlencoded') ||
      mime.contains('javascript');
}

/// Tee buffer that keeps at most [cap] bytes but counts the true total. Copies
/// chunks so the captured copy is immutable to later mutation by the app.
class CappedBuffer {
  CappedBuffer(this.cap);
  final int cap;
  final BytesBuilder _b = BytesBuilder(copy: true);
  int total = 0;
  bool _truncated = false;

  void add(List<int> data) {
    total += data.length;
    final room = cap - _b.length;
    if (room <= 0) {
      _truncated = true;
      return;
    }
    if (data.length <= room) {
      _b.add(data);
    } else {
      _b.add(data.sublist(0, room));
      _truncated = true;
    }
  }

  /// Decoded text, or null when nothing was captured. One-shot (consumes bytes).
  String? text() {
    final bytes = _b.takeBytes();
    if (bytes.isEmpty) return null;
    final s = utf8.decode(bytes, allowMalformed: true);
    return _truncated ? '$s…[truncated]' : s;
  }
}
