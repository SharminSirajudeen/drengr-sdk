import 'store.dart';

/// Pure-Dart runtime: no shared_preferences; caller falls back to files.
Future<DrengrStore?> prefsStore() async => null;
