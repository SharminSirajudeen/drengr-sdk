import 'package:flutter/widgets.dart';

/// Registers a lifecycle observer; returns its remover. Fail-open: without an
/// initialized WidgetsBinding this is a no-op.
void Function() installLifecycleObserver(
    void Function(bool resumed) onChange) {
  try {
    final obs = _Observer(onChange);
    WidgetsBinding.instance.addObserver(obs);
    return () {
      try {
        WidgetsBinding.instance.removeObserver(obs);
      } catch (_) {}
    };
  } catch (_) {
    return () {};
  }
}

class _Observer with WidgetsBindingObserver {
  _Observer(this.onChange);
  final void Function(bool resumed) onChange;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    try {
      if (state == AppLifecycleState.resumed) onChange(true);
      if (state == AppLifecycleState.paused) onChange(false);
    } catch (_) {}
  }
}
