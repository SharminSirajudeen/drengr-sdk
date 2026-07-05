library;

import 'dart:io';

import 'src/capture.dart';
import 'src/http_overrides.dart';
import 'src/network_event.dart';

export 'src/ingest_sink.dart' show IngestSink;
export 'src/network_event.dart' show NetworkEvent;

class Drengr {
  Drengr._();

  static HttpOverrides? _previous;

  static void start({
    int maxBodyBytes = 64 * 1024,
    void Function(NetworkEvent event)? onEvent,
    bool enabled = true,
    bool logBodies = false,
    bool Function(Uri url)? captureWhen,
    Set<String> redactHeaders = const {},
    Set<String> ignoreHosts = const {},
  }) {
    if (DrengrCapture.installed) return;
    if (_optedOut()) enabled = false;
    DrengrCapture.instance = DrengrCapture(
      maxBodyBytes: maxBodyBytes,
      onEvent: onEvent,
      enabled: enabled,
      logBodies: logBodies,
      captureWhen: captureWhen,
      redactHeaderNames: redactHeaders.map((e) => e.toLowerCase()).toSet(),
      ignoreHosts: ignoreHosts,
    );
    _previous = HttpOverrides.current;
    HttpOverrides.global = DrengrHttpOverrides(_previous);
  }

  static void stop() {
    if (!DrengrCapture.installed) return;
    HttpOverrides.global = _previous;
    _previous = null;
    DrengrCapture.instance?.ring.clear();
    DrengrCapture.instance = null;
  }

  static void setEnabled(bool enabled) {
    final c = DrengrCapture.instance;
    if (c != null) c.enabled = enabled;
  }

  static List<NetworkEvent> get events =>
      DrengrCapture.instance?.ring.toList() ?? const [];

  static void clear() => DrengrCapture.instance?.ring.clear();

  static void optOut() {
    _persistOptOut(true);
    setEnabled(false);
  }

  static void optIn() {
    _persistOptOut(false);
    setEnabled(true);
  }

  static File _optOutFile() => File('${Directory.systemTemp.path}/.drengr_optout');

  static bool _optedOut() {
    try {
      return _optOutFile().existsSync();
    } catch (_) {
      return false;
    }
  }

  static void _persistOptOut(bool out) {
    try {
      final f = _optOutFile();
      if (out) {
        f.writeAsStringSync('1');
      } else if (f.existsSync()) {
        f.deleteSync();
      }
    } catch (_) {}
  }
}
