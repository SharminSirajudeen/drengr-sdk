/// Drops Dart-captured events the native layer already saw: a native summary
/// with the same (url, method) within [windowMs] marks the Dart copy a duplicate.
class NetworkDedup {
  NetworkDedup({this.windowMs = 500, this.maxEntries = 512});

  /// Match window: same (url, method) within this many ms is one exchange.
  final int windowMs;

  /// Hard cap on remembered native summaries (oldest shed first).
  final int maxEntries;

  final List<_Seen> _seen = <_Seen>[];

  /// Records a (url, method, ts) summary reported by the native capture layer.
  void recordNative(String url, String method, int tsMs) {
    if (url.isEmpty) return;
    _evict(tsMs);
    _seen.add(_Seen(url, method.toUpperCase(), tsMs));
    if (_seen.length > maxEntries) {
      _seen.removeRange(0, _seen.length - maxEntries);
    }
  }

  /// True when no native capture matched — the Dart event is safe to enqueue.
  bool admit(String url, String method, int tsMs) {
    _evict(tsMs);
    final m = method.toUpperCase();
    for (var i = _seen.length - 1; i >= 0; i--) {
      final s = _seen[i];
      if (s.url == url && s.method == m && (tsMs - s.tsMs).abs() <= windowMs) {
        return false;
      }
    }
    return true;
  }

  /// Remembered native summaries still inside the window.
  int get size => _seen.length;

  void _evict(int nowMs) => _seen.removeWhere((s) => nowMs - s.tsMs > windowMs);
}

class _Seen {
  const _Seen(this.url, this.method, this.tsMs);
  final String url;
  final String method;
  final int tsMs;
}
