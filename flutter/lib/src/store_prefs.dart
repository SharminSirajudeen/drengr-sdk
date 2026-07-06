import 'package:shared_preferences/shared_preferences.dart';

import 'store.dart';

/// shared_preferences-backed store, or null when the plugin is unavailable.
Future<DrengrStore?> prefsStore() async {
  try {
    return _PrefsStore(await SharedPreferences.getInstance());
  } catch (_) {
    return null;
  }
}

class _PrefsStore implements DrengrStore {
  _PrefsStore(this._p);
  final SharedPreferences _p;

  @override
  Future<String?> read(String key) async {
    try {
      return _p.getString('drengr.$key');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _p.setString('drengr.$key', value);
    } catch (_) {}
  }
}
