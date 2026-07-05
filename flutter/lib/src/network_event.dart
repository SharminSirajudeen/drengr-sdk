class NetworkEvent {
  const NetworkEvent({
    required this.method,
    required this.url,
    required this.statusCode,
    required this.durationMs,
    required this.requestBodyBytes,
    required this.responseBodyBytes,
    required this.requestHeaders,
    required this.responseHeaders,
    required this.requestBody,
    required this.responseBody,
    required this.timestampMs,
    this.errorText,
  });

  final String method;
  final String url;
  final int? statusCode;
  final int durationMs;
  final int requestBodyBytes;
  final int responseBodyBytes;
  final Map<String, String> requestHeaders;
  final Map<String, String> responseHeaders;
  final String? requestBody;
  final String? responseBody;
  final int timestampMs;
  final String? errorText;

  Map<String, Object?> toJson() => {
        'method': method,
        'url': url,
        'status': statusCode,
        'durationMs': durationMs,
        'reqBytes': requestBodyBytes,
        'respBytes': responseBodyBytes,
        'reqHeaders': requestHeaders,
        'respHeaders': responseHeaders,
        'reqBody': requestBody,
        'respBody': responseBody,
        'ts': timestampMs,
        'error': errorText,
      };
}
