// Session rotation spec — identical constants in every Drengr SDK.
// ignore_for_file: constant_identifier_names
import 'ids.dart';
import 'store.dart';

const int SESSION_IDLE_MS = 1800000; // 30 min
const int SESSION_MAX_MS = 86400000; // 24 h

/// Tracks {session_id, last_activity_at} with idle/max-age rotation.
/// All persistence is best-effort; nothing here ever throws into the app.
class SessionManager {
  SessionManager(this._store, {int Function()? now}) : _now = now ?? _wall;
  static int _wall() => DateTime.now().millisecondsSinceEpoch;

  final DrengrStore _store;
  final int Function() _now;

  String _sessionId = '';
  int _startedAt = 0;
  int _lastActivityAt = 0;
  int _lastPersistedAt = 0;

  static const int _persistEveryMs = 5000;

  String get sessionId => _sessionId;

  /// Reuse the persisted session when the idle gap is under SESSION_IDLE_MS
  /// (and age under SESSION_MAX_MS); otherwise mint a new one.
  Future<String> start() async {
    try {
      final now = _now();
      final id = await _store.read('session_id');
      final last =
          int.tryParse(await _store.read('session_last_activity_at') ?? '') ??
              0;
      final started =
          int.tryParse(await _store.read('session_started_at') ?? '') ?? 0;
      if (id != null &&
          id.isNotEmpty &&
          now - last < SESSION_IDLE_MS &&
          now - started < SESSION_MAX_MS) {
        _sessionId = id;
        _startedAt = started == 0 ? now : started;
        _lastActivityAt = now;
      } else {
        _mint(now);
      }
      await _persist(now);
    } catch (_) {
      if (_sessionId.isEmpty) {
        _sessionId = uuidV4();
        _startedAt = _lastActivityAt = _now();
      }
    }
    return _sessionId;
  }

  /// True when the idle gap or session age says a new session is due.
  bool get stale {
    final now = _now();
    return now - _lastActivityAt > SESSION_IDLE_MS ||
        now - _startedAt > SESSION_MAX_MS;
  }

  /// Mint a new session id (call AFTER flushing the old session's queue).
  Future<String> rotate() async {
    final now = _now();
    _mint(now);
    await _persist(now);
    return _sessionId;
  }

  void _mint(int now) {
    _sessionId = uuidV4();
    _startedAt = now;
    _lastActivityAt = now;
  }

  /// Bump last_activity_at (every captured event); persisted at most every 5s.
  void touch() {
    try {
      _lastActivityAt = _now();
      if (_lastActivityAt - _lastPersistedAt >= _persistEveryMs) {
        _persist(_lastActivityAt);
      }
    } catch (_) {}
  }

  /// Bump + persist immediately (background transition).
  Future<void> persistNow() async {
    try {
      _lastActivityAt = _now();
      await _persist(_lastActivityAt);
    } catch (_) {}
  }

  Future<void> _persist(int now) async {
    try {
      _lastPersistedAt = now;
      await _store.write('session_id', _sessionId);
      await _store.write('session_last_activity_at', '$_lastActivityAt');
      await _store.write('session_started_at', '$_startedAt');
    } catch (_) {}
  }
}
