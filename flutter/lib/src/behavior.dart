import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'behavior_state.dart';
import 'tap_label.dart';

/// Zero-integration behavior capture: global tap detection (pointer-router
/// global route — no wrapper widget, no per-widget code), rage/dead tap
/// heuristics, and chained crash handlers. Fail-open throughout.

const int _rageWindowMs = 600;
const double _rageRadiusPx = 24.0;
const int _rageMinTaps = 3;
const double _tapSlopPx = 20.0;

_Behavior? _behavior;

/// Install once per isolate; no-op if already installed or no binding possible.
void installBehaviorCapture({int Function()? now}) {
  if (_behavior != null) return;
  try {
    WidgetsFlutterBinding.ensureInitialized();
    _behavior =
        _Behavior(now ?? () => DateTime.now().millisecondsSinceEpoch)
          .._install();
  } catch (_) {}
}

void uninstallBehaviorCapture() {
  try {
    _behavior?._uninstall();
  } catch (_) {}
  _behavior = null;
}

class _Down {
  const _Down(this.position, this.viewId);
  final Offset position;
  final int viewId;
}

class _Behavior {
  _Behavior(this._now);
  final int Function() _now;

  final Map<int, _Down> _downs = {};
  FlutterExceptionHandler? _prevFlutterOnError;
  ui.ErrorCallback? _prevPlatformOnError;
  bool _routed = false;

  int _burstCount = 0;
  int _burstLastMs = 0;
  Offset _burstPos = Offset.zero;
  String _burstLabel = '';
  bool _burstReported = false;

  int _lastCrashMs = 0;
  int _crashCount = 0;
  static const int _maxCrashes = 50;

  void _install() {
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    _routed = true;
    _prevFlutterOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      _crash(details.exception, details.stack);
      final prev = _prevFlutterOnError;
      prev != null ? prev(details) : FlutterError.presentError(details);
    };
    _prevPlatformOnError = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (error, stack) {
      _crash(error, stack);
      final prev = _prevPlatformOnError;
      return prev != null ? prev(error, stack) : false;
    };
  }

  void _uninstall() {
    if (_routed) {
      try {
        GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      } catch (_) {}
      _routed = false;
    }
    FlutterError.onError = _prevFlutterOnError ?? FlutterError.presentError;
    try {
      ui.PlatformDispatcher.instance.onError = _prevPlatformOnError;
    } catch (_) {}
  }

  void _onPointer(PointerEvent e) {
    try {
      if (e is PointerDownEvent) {
        _downs[e.pointer] = _Down(e.position, e.viewId);
        while (_downs.length > 20) {
          _downs.remove(_downs.keys.first);
        }
      } else if (e is PointerUpEvent) {
        final d = _downs.remove(e.pointer);
        if (d == null) return;
        if ((e.position - d.position).distance > _tapSlopPx) return;
        _tap(d.position, d.viewId);
      } else if (e is PointerCancelEvent) {
        _downs.remove(e.pointer);
      }
    } catch (_) {}
  }

  void _tap(Offset pos, int viewId) {
    final t = describeTap(pos, viewId);
    final n = _normalize(pos, viewId);
    final ts = _now();
    final base = <String, dynamic>{
      'screen': DrengrBehaviorState.screen,
      'label': t.label,
      'x': n.dx,
      'y': n.dy,
    };
    _emit({'kind': 'tap', 'ts_ms': ts, ...base});
    if (!t.interactive) _emit({'kind': 'dead_tap', 'ts_ms': ts, ...base});
    _rage(pos, t.label, ts, base);
  }

  void _rage(Offset pos, String label, int ts, Map<String, dynamic> base) {
    final sameBurst = ts - _burstLastMs <= _rageWindowMs &&
        (pos - _burstPos).distance <= _rageRadiusPx &&
        label == _burstLabel;
    if (sameBurst) {
      _burstCount++;
    } else {
      _burstCount = 1;
      _burstReported = false;
      _burstLabel = label;
    }
    _burstPos = pos;
    _burstLastMs = ts;
    if (_burstCount >= _rageMinTaps && !_burstReported) {
      _burstReported = true; // once per burst
      _emit({'kind': 'rage_tap', 'ts_ms': ts, ...base, 'count': _burstCount});
    }
  }

  Offset _normalize(Offset pos, int viewId) {
    try {
      final dispatcher = WidgetsBinding.instance.platformDispatcher;
      ui.FlutterView? v;
      for (final view in dispatcher.views) {
        if (view.viewId == viewId) {
          v = view;
          break;
        }
      }
      v ??= dispatcher.implicitView;
      if (v == null) return Offset.zero;
      final size = v.physicalSize / v.devicePixelRatio;
      if (size.width <= 0 || size.height <= 0) return Offset.zero;
      return Offset((pos.dx / size.width).clamp(0.0, 1.0),
          (pos.dy / size.height).clamp(0.0, 1.0));
    } catch (_) {
      return Offset.zero;
    }
  }

  // Type + first frame only — exception messages can carry PII, never ship them.
  void _crash(Object exception, StackTrace? stack) {
    try {
      final ts = _now();
      if (ts - _lastCrashMs < 1000 || _crashCount >= _maxCrashes) return;
      _lastCrashMs = ts;
      _crashCount++;
      _emit({
        'kind': 'crash',
        'ts_ms': ts,
        'screen': DrengrBehaviorState.screen,
        'exception_type': exception.runtimeType.toString(),
        'message': _firstFrame(stack),
      });
    } catch (_) {}
  }

  static String _firstFrame(StackTrace? stack) {
    if (stack == null) return '';
    for (final line in stack.toString().split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      return t.length > 200 ? t.substring(0, 200) : t;
    }
    return '';
  }

  void _emit(Map<String, dynamic> ev) {
    try {
      DrengrBehaviorState.emit?.call(ev);
    } catch (_) {}
  }
}
