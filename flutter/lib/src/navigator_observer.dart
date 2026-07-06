import 'package:flutter/widgets.dart';

import 'behavior_state.dart';

/// Emits `screen_view` on push / replace / pop-reveal. Add to your app:
/// `MaterialApp(navigatorObservers: [Drengr.navigatorObserver])`.
///
/// It is a [RouteObserver], so it can double as your route-aware observer.
/// Fail-open: never throws into navigation.
class DrengrNavigatorObserver extends RouteObserver<ModalRoute<void>> {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _view(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null) _view(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (previousRoute != null) _view(previousRoute);
  }

  void _view(Route<dynamic> route) {
    try {
      final name = screenNameOf(route);
      if (name.isEmpty || name == DrengrBehaviorState.screen) return;
      final prev = DrengrBehaviorState.screen;
      DrengrBehaviorState.screen = name;
      DrengrBehaviorState.emit?.call({
        'kind': 'screen_view',
        'ts_ms': DateTime.now().millisecondsSinceEpoch,
        'screen': name,
        'prev_screen': prev,
      });
    } catch (_) {}
  }
}

/// RouteSettings.name, else the route runtimeType (generics stripped).
/// Unnamed non-page routes (dialogs, sheets) don't count as screens.
String screenNameOf(Route<dynamic> route) {
  final n = route.settings.name;
  if (n != null && n.isNotEmpty) return n;
  if (route is! PageRoute) return '';
  return route.runtimeType.toString().split('<').first;
}
