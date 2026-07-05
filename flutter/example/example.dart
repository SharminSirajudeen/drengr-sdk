import 'package:drengr_flutter_sdk/drengr_flutter_sdk.dart';

void main() {
  Drengr.start(
    onEvent: (event) {
      print('${event.method} ${event.url} -> ${event.statusCode} '
          '(${event.durationMs}ms, ${event.responseBodyBytes}B)');
    },
  );
}
