/// Shared behavior-capture state, pure Dart so both the Flutter capture layer
/// and the facade can reach it without a dart:ui dependency.
class DrengrBehaviorState {
  DrengrBehaviorState._();

  /// Current screen name (maintained by [DrengrNavigatorObserver]).
  static String screen = '';

  /// Delivery hook for behavior events; null = behavior capture off.
  static void Function(Map<String, dynamic> event)? emit;

  static void reset() {
    screen = '';
    emit = null;
  }
}
