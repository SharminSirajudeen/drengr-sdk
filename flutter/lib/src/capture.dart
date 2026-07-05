import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'network_event.dart';
import 'redact.dart';

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

  static DrengrCapture? instance;

  static bool get installed => instance != null;

  final int maxBodyBytes;
  final Set<String> redactHeaderNames;
  final Set<String> ignoreHosts;
  final bool logBodies;
  bool enabled;
  final bool Function(Uri url)? captureWhen;

  final void Function(NetworkEvent)? _onEvent;

  static const _ringMax = 200;

  final Queue<NetworkEvent> ring = Queue<NetworkEvent>();

  bool ignored(Uri url) {
    final h = url.host.toLowerCase();
    for (final s in ignoreHosts) {
      final t = s.toLowerCase();
      if (h == t || h.endsWith('.$t')) return true;
    }
    return false;
  }

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

  Map<String, String> redact(Map<String, String> headers) =>
      redactHeaders(headers, redactHeaderNames);
}

bool isTextual(ContentType? ct) {
  if (ct == null) return true;
  final mime = ct.mimeType.toLowerCase();
  return mime.startsWith('text/') ||
      mime.contains('json') ||
      mime.contains('xml') ||
      mime.contains('x-www-form-urlencoded') ||
      mime.contains('javascript');
}

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

  String? text() {
    final bytes = _b.takeBytes();
    if (bytes.isEmpty) return null;
    final s = utf8.decode(bytes, allowMalformed: true);
    return _truncated ? '$s…[truncated]' : s;
  }
}
