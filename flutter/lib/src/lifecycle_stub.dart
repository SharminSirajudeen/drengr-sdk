/// Pure-Dart runtime: no widget lifecycle; rotation happens on start() only.
void Function() installLifecycleObserver(void Function(bool resumed) onChange) =>
    () {};
