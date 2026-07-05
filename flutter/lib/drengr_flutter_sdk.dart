/// Drengr — zero-code in-process network capture for Flutter and Dart.
///
/// A single [Drengr.start] installs an [HttpOverrides] beneath `dart:io`, so it
/// transparently records every `HttpClient`, `package:http`, and Dio
/// (default adapter) request and response — the app writes no per-request code.
/// Bodies are size-capped and secrets are redacted before anything is stored,
/// and the bytes the app sends and receives are never altered.
///
/// Capture is installed per **isolate** (like `HttpOverrides.global`). Call
/// [Drengr.start] again inside any background isolate that performs networking.
library;

import 'dart:io';

import 'src/capture.dart';
import 'src/http_overrides.dart';
import 'src/network_event.dart';

export 'src/ingest_sink.dart' show IngestSink;
export 'src/network_event.dart' show NetworkEvent;

/// Entry point for the Drengr Flutter SDK.
class Drengr {
  Drengr._();

  static HttpOverrides? _previous;

  /// Installs the capturing [HttpOverrides], chaining any existing one so a
  /// tenant's own override (or another SDK's) is preserved. Call once at
  /// startup, before the first network request. Subsequent calls are ignored
  /// (use [stop] first to reconfigure).
  ///
  /// - [maxBodyBytes] caps how much of each body is captured; larger bodies
  ///   stream through untouched and are recorded by size only.
  /// - [onEvent] receives each [NetworkEvent]; when omitted, events are logged
  ///   to the console (metadata only unless [logBodies] is set).
  /// - [enabled] starts capture active; set `false` to install paused (e.g. a
  ///   consent gate) and call [setEnabled] later.
  /// - [logBodies] makes the default console sink also print the (redacted)
  ///   request/response bodies, not just metadata. Ignored when [onEvent] is set.
  /// - [captureWhen] is an optional per-request predicate (sampling /
  ///   allow-listing); return `false` to skip a request entirely.
  /// - [redactHeaders] adds header names (case-insensitive) to mask, on top of
  ///   the always-applied built-in defaults (`authorization`, `cookie`, …).
  /// - [ignoreHosts] skips capture for these hosts (exact or subdomain match).
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
    // Honour a persisted opt-out (default-on consent): start paused if set.
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

  /// Uninstalls capture in this isolate, restoring the previous
  /// [HttpOverrides.global] and clearing buffered events. Safe to call if not
  /// installed.
  static void stop() {
    if (!DrengrCapture.installed) return;
    HttpOverrides.global = _previous;
    _previous = null;
    DrengrCapture.instance?.ring.clear();
    DrengrCapture.instance = null;
  }

  /// Pauses or resumes capture without uninstalling the override (consent gate).
  static void setEnabled(bool enabled) {
    final c = DrengrCapture.instance;
    if (c != null) c.enabled = enabled;
  }

  /// Recent captured events (bounded ring, newest last).
  static List<NetworkEvent> get events =>
      DrengrCapture.instance?.ring.toList() ?? const [];

  /// Clears buffered events (e.g. after flushing to a backend, or on logout).
  static void clear() => DrengrCapture.instance?.ring.clear();

  /// Opt out of capture (default-on consent). Stops all capture/emit now and
  /// persists across launches, so [start] resumes paused on the next run.
  static void optOut() {
    _persistOptOut(true);
    setEnabled(false);
  }

  /// Resume capture after a prior [optOut]. Clears the persisted flag and
  /// re-enables the runtime gate.
  static void optIn() {
    _persistOptOut(false);
    setEnabled(true);
  }

  /// Opt-out flag file (pure-Dart, app-scoped temp; same approach as install_id).
  static File _optOutFile() => File('${Directory.systemTemp.path}/.drengr_optout');

  /// Read the persisted opt-out flag. Never throws.
  static bool _optedOut() {
    try {
      return _optOutFile().existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Persist (or clear) the opt-out flag. Never throws.
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
