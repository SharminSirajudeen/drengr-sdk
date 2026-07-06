/// Drengr — zero-code in-process network capture for Flutter and Dart.
///
/// A single [Drengr.start] installs an [HttpOverrides] beneath `dart:io`, so it
/// transparently records every `HttpClient`, `package:http`, and Dio
/// (default adapter) request and response — the app writes no per-request code.
/// Bodies are size-capped and secrets are redacted before anything is stored,
/// and the bytes the app sends and receives are never altered.
///
/// With `publishableKey` + `ingestUrl`, [Drengr.start] also constructs the
/// delivery sink and ships events to the Drengr ingest endpoint automatically
/// (install_id, session_id, and app context are handled for you), and turns on
/// behavior capture: screen views (via [Drengr.navigatorObserver]), taps with
/// semantic labels, rage/dead taps, and crashes — no per-widget code.
///
/// Capture is installed per **isolate** (like `HttpOverrides.global`). Call
/// [Drengr.installInIsolate] inside any background isolate that performs
/// networking (`compute()`, background plugins).
library;

import 'dart:io';

import 'src/behavior_state.dart';
import 'src/behavior_stub.dart' if (dart.library.ui) 'src/behavior.dart';
import 'src/capture.dart';
import 'src/capturing_http_client.dart';
import 'src/http_overrides.dart';
import 'src/ids.dart';
import 'src/ingest_sink.dart';
import 'src/lifecycle_stub.dart' if (dart.library.ui) 'src/lifecycle.dart';
import 'src/navigator_observer_stub.dart'
    if (dart.library.ui) 'src/navigator_observer.dart';
import 'src/network_event.dart';
import 'src/session.dart';
import 'src/store.dart';

export 'src/ingest_sink.dart' show IngestSink;
export 'src/navigator_observer_stub.dart'
    if (dart.library.ui) 'src/navigator_observer.dart'
    show DrengrNavigatorObserver;
export 'src/network_event.dart' show NetworkEvent;
export 'src/session.dart' show SessionManager, SESSION_IDLE_MS, SESSION_MAX_MS;
export 'src/store.dart' show DrengrStore, MemoryStore, FileStore, DefaultStore;

/// Entry point for the Drengr Flutter SDK.
class Drengr {
  Drengr._();

  static HttpOverrides? _previous;
  static IngestSink? _sink;
  static SessionManager? _session;
  static Map<String, dynamic>? _context;
  static Future<void>? _initDone;
  static void Function()? _removeLifecycle;
  static final List<NetworkEvent> _preSink = [];
  static final List<Map<String, dynamic>> _preBehavior = [];
  static String? _pendingExternalId;
  static Map<String, dynamic> _pendingTraits = const {};
  static final Map<String, String> _pendingExperiments = {};

  /// Test seams: storage + clock injection. Leave null in production.
  static DrengrStore? debugStore;
  static int Function()? debugNow;

  static const String _sdkVersion = '0.4.0';

  /// Add to `MaterialApp(navigatorObservers: [Drengr.navigatorObserver])` so
  /// screen_view events (and per-screen tap context) are captured.
  static final DrengrNavigatorObserver navigatorObserver =
      DrengrNavigatorObserver();

  /// Installs the capturing [HttpOverrides], chaining any existing one so a
  /// tenant's own override (or another SDK's) is preserved. Call once at
  /// startup, before the first network request. Subsequent calls are ignored
  /// (use [stop] first to reconfigure).
  ///
  /// Delivery (the one-liner): pass [publishableKey] + [ingestUrl] (and
  /// [appPackage]) and events ship to Drengr automatically — an [IngestSink]
  /// is built internally with a persistent `install_id`, a rotating
  /// `session_id` (30 min idle / 24 h max), and app context. An explicit
  /// [onEvent] wins over the auto sink.
  ///
  /// - [maxBodyBytes] caps how much of each body is captured; larger bodies
  ///   stream through untouched and are recorded by size only.
  /// - [onEvent] receives each [NetworkEvent]; when omitted (and no key is
  ///   set), events are logged to the console.
  /// - [enabled] starts capture active; set `false` to install paused (e.g. a
  ///   consent gate) and call [setEnabled] later.
  /// - [logBodies] makes the default console sink also print the (redacted)
  ///   request/response bodies, not just metadata. Ignored when [onEvent] is set.
  /// - [captureWhen] is an optional per-request predicate (sampling /
  ///   allow-listing); return `false` to skip a request entirely.
  /// - [redactHeaders] adds header names (case-insensitive) to mask, on top of
  ///   the always-applied built-in defaults (`authorization`, `cookie`, …).
  /// - [ignoreHosts] skips capture for these hosts (exact or subdomain match).
  /// - [sampleRate] captures only this fraction of requests (1.0 = all).
  /// - [captureSensitivePathBodies] re-enables body capture on payment-ish
  ///   paths (`/payment`, `/checkout`, `/card`); off by default.
  /// - [behavior] (default on, auto-sink mode only) captures screen_view /
  ///   tap / rage_tap / dead_tap / crash with zero per-widget code; set
  ///   `false` to opt out. Screen names need [navigatorObserver] in your app.
  static void start({
    String? publishableKey,
    String? ingestUrl,
    String? appPackage,
    int maxBodyBytes = 64 * 1024,
    void Function(NetworkEvent event)? onEvent,
    bool enabled = true,
    bool logBodies = false,
    bool behavior = true,
    bool Function(Uri url)? captureWhen,
    Set<String> redactHeaders = const {},
    Set<String> ignoreHosts = const {},
    double sampleRate = 1.0,
    bool captureSensitivePathBodies = false,
  }) {
    if (DrengrCapture.installed) return;
    // Honour a persisted opt-out (default-on consent): start paused if set.
    if (_optedOut()) enabled = false;
    final auto =
        onEvent == null && publishableKey != null && ingestUrl != null;
    DrengrCapture.instance = DrengrCapture(
      maxBodyBytes: maxBodyBytes,
      onEvent: onEvent ?? (auto ? _forward : null),
      enabled: enabled,
      logBodies: logBodies,
      captureWhen: captureWhen,
      redactHeaderNames: redactHeaders.map((e) => e.toLowerCase()).toSet(),
      ignoreHosts: ignoreHosts,
      sampleRate: sampleRate,
      captureSensitivePathBodies: captureSensitivePathBodies,
    );
    _previous = HttpOverrides.current;
    HttpOverrides.global = DrengrHttpOverrides(_previous);
    if (auto) {
      if (behavior) {
        DrengrBehaviorState.emit = _forwardBehavior;
        installBehaviorCapture(now: debugNow);
      }
      _initDone = _autoInit(publishableKey, ingestUrl, appPackage ?? '');
    }
  }

  /// Alias of [start] for spawned isolates — `HttpOverrides.global` is NOT
  /// inherited by `Isolate.spawn`/`compute()`, so each networking isolate
  /// needs its own install (D-4).
  static void installInIsolate({
    String? publishableKey,
    String? ingestUrl,
    String? appPackage,
    int maxBodyBytes = 64 * 1024,
    void Function(NetworkEvent event)? onEvent,
    bool enabled = true,
    bool logBodies = false,
    bool Function(Uri url)? captureWhen,
    Set<String> redactHeaders = const {},
    Set<String> ignoreHosts = const {},
    double sampleRate = 1.0,
    bool captureSensitivePathBodies = false,
  }) =>
      start(
        publishableKey: publishableKey,
        ingestUrl: ingestUrl,
        appPackage: appPackage,
        maxBodyBytes: maxBodyBytes,
        onEvent: onEvent,
        enabled: enabled,
        logBodies: logBodies,
        behavior: false, // background isolates have no UI
        captureWhen: captureWhen,
        redactHeaders: redactHeaders,
        ignoreHosts: ignoreHosts,
        sampleRate: sampleRate,
        captureSensitivePathBodies: captureSensitivePathBodies,
      );

  /// Wrap an [HttpClient] you construct yourself (e.g. Dio's
  /// `onHttpClientCreate` with a custom client, D-8) so its traffic is
  /// captured even when it bypasses `HttpOverrides`.
  static HttpClient wrapClient(HttpClient inner) {
    try {
      return CapturingHttpClient(inner);
    } catch (_) {
      return inner;
    }
  }

  // Auto-sink forwarder: touch the session, deliver (or buffer pre-init).
  static void _forward(NetworkEvent e) {
    try {
      _session?.touch();
      final s = _sink;
      if (s != null) {
        s.addNetwork(e);
      } else {
        _preSink.add(e);
        while (_preSink.length > 200) {
          _preSink.removeAt(0);
        }
      }
    } catch (_) {}
  }

  // Behavior forwarder: consent-gated, touch the session, deliver (or buffer).
  static void _forwardBehavior(Map<String, dynamic> ev) {
    try {
      if (!(DrengrCapture.instance?.enabled ?? false)) return;
      _session?.touch();
      final s = _sink;
      if (s != null) {
        s.addBehavior(ev);
      } else {
        _preBehavior.add(ev);
        while (_preBehavior.length > 200) {
          _preBehavior.removeAt(0);
        }
      }
    } catch (_) {}
  }

  static Future<void> _autoInit(
      String key, String url, String appPackage) async {
    try {
      final store = debugStore ?? DefaultStore();
      final installId = await loadInstallId(store);
      final session = SessionManager(store, now: debugNow);
      final sessionId = await session.start();
      _session = session;
      _context = <String, dynamic>{
        'app_package': appPackage,
        'os': Platform.operatingSystem,
        'os_version': Platform.operatingSystemVersion,
        'install_id': installId,
        'session_id': sessionId,
        'sdk_version': _sdkVersion,
      };
      final sink =
          IngestSink(url: url, publishableKey: key, context: _context!);
      final ext = _pendingExternalId;
      if (ext != null) sink.identify(ext, _pendingTraits);
      _pendingExternalId = null;
      _pendingTraits = const {};
      _pendingExperiments.forEach(sink.setExperiment);
      _pendingExperiments.clear();
      _sink = sink;
      for (final e in List<NetworkEvent>.of(_preSink)) {
        sink.addNetwork(e);
      }
      _preSink.clear();
      for (final e in List<Map<String, dynamic>>.of(_preBehavior)) {
        sink.addBehavior(e);
      }
      _preBehavior.clear();
      _removeLifecycle = installLifecycleObserver(_onLifecycle);
    } catch (_) {/* never break the host app */}
  }

  static void _onLifecycle(bool resumed) {
    resumed ? _rotateIfStale() : _onPaused();
  }

  /// Idle/max-age rotation: flush the queue under the OLD session first, then
  /// mint the new session_id.
  static Future<void> _rotateIfStale() async {
    try {
      final s = _session;
      if (s == null) return;
      if (s.stale) {
        await _sink?.flush();
        final id = await s.rotate();
        _context?['session_id'] = id;
      } else {
        s.touch();
      }
    } catch (_) {}
  }

  static Future<void> _onPaused() async {
    try {
      await _session?.persistNow();
      await _sink?.flush();
    } catch (_) {}
  }

  /// Test seam: drive the lifecycle handler directly.
  static Future<void> debugLifecycle(bool resumed) =>
      resumed ? _rotateIfStale() : _onPaused();

  /// Sets your own stable, non-PII user id on the session and all events
  /// hereafter. No-op (never throws) when no sink is configured.
  static void identify(String externalId,
      [Map<String, dynamic> traits = const {}]) {
    try {
      final s = _sink;
      if (s != null) {
        s.identify(externalId, traits);
      } else if (_initDone != null && externalId.isNotEmpty) {
        _pendingExternalId = externalId;
        _pendingTraits = traits;
      }
    } catch (_) {}
  }

  /// Sets/clears a session-scoped experiment variant. A null/empty [variant]
  /// clears [key]. No-op (never throws) when no sink is configured.
  static void setExperiment(String key, String? variant) {
    try {
      final s = _sink;
      if (s != null) {
        s.setExperiment(key, variant);
      } else if (_initDone != null && key.isNotEmpty) {
        if (variant == null || variant.isEmpty) {
          _pendingExperiments.remove(key);
        } else {
          _pendingExperiments[key] = variant;
        }
      }
    } catch (_) {}
  }

  /// Force-drains buffered events to the ingest endpoint. Also runs
  /// automatically when the app is backgrounded. Never throws.
  static Future<void> flush() async {
    try {
      await _initDone;
      await _sink?.flush();
    } catch (_) {}
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
    try {
      _removeLifecycle?.call();
    } catch (_) {}
    _removeLifecycle = null;
    uninstallBehaviorCapture();
    DrengrBehaviorState.reset();
    _sink = null;
    _session = null;
    _context = null;
    _initDone = null;
    _preSink.clear();
    _preBehavior.clear();
    _pendingExternalId = null;
    _pendingTraits = const {};
    _pendingExperiments.clear();
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
