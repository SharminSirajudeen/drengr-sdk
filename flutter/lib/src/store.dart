import 'dart:io';

import 'store_prefs_stub.dart' if (dart.library.ui) 'store_prefs.dart'
    as prefs;

/// Minimal key-value persistence used for install_id / session state.
abstract class DrengrStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// In-memory store (tests / last-resort fallback).
class MemoryStore implements DrengrStore {
  final Map<String, String> _m = {};

  @override
  Future<String?> read(String key) async => _m[key];

  @override
  Future<void> write(String key, String value) async => _m[key] = value;
}

/// Temp-file store — same idiom as the opt-out flag and the queue file.
class FileStore implements DrengrStore {
  File _f(String key) =>
      File('${Directory.systemTemp.path}${Platform.pathSeparator}.drengr_kv_$key');

  @override
  Future<String?> read(String key) async {
    try {
      final f = _f(key);
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _f(key).writeAsString(value, flush: true);
    } catch (_) {}
  }
}

/// shared_preferences when the Flutter runtime provides it, else temp files.
class DefaultStore implements DrengrStore {
  DrengrStore? _delegate;

  Future<DrengrStore> _resolve() async {
    final d = _delegate;
    if (d != null) return d;
    DrengrStore? p;
    try {
      p = await prefs.prefsStore();
    } catch (_) {}
    return _delegate = p ?? FileStore();
  }

  @override
  Future<String?> read(String key) async {
    try {
      return await (await _resolve()).read(key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await (await _resolve()).write(key, value);
    } catch (_) {}
  }
}
