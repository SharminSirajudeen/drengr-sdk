import 'dart:math';

import 'store.dart';

final Random _rand = _secureRandom();
Random _secureRandom() {
  try {
    return Random.secure();
  } catch (_) {
    return Random();
  }
}

/// RFC-4122 v4 UUID.
String uuidV4() {
  final b = List<int>.generate(16, (_) => _rand.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i, int j) => b
      .sublist(i, j)
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
}

/// Persistent install id: minted once, reused forever. Never throws.
Future<String> loadInstallId(DrengrStore store) async {
  try {
    final existing = await store.read('install_id');
    if (existing != null && existing.isNotEmpty) return existing;
    final id = uuidV4();
    await store.write('install_id', id);
    return id;
  } catch (_) {
    return uuidV4();
  }
}
