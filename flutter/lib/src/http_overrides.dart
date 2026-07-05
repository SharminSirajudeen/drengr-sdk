import 'dart:io';

import 'capturing_http_client.dart';

/// Installs a capturing [HttpClient] while preserving any pre-existing override
/// (so we never clobber the tenant's own `HttpOverrides.global`).
class DrengrHttpOverrides extends HttpOverrides {
  DrengrHttpOverrides(this._previous);
  final HttpOverrides? _previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner =
        _previous?.createHttpClient(context) ?? super.createHttpClient(context);
    try {
      return CapturingHttpClient(inner);
    } catch (_) {
      return inner; // never break the app's networking
    }
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    return _previous?.findProxyFromEnvironment(url, environment) ??
        super.findProxyFromEnvironment(url, environment);
  }
}
