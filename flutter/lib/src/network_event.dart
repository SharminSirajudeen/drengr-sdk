/// A single captured request/response exchange — plaintext, in-process.
///
/// Every string field that can carry user data (URL, headers, bodies) is
/// redacted and bodies are size-capped before the event is constructed.
class NetworkEvent {
  /// Creates a captured event. All fields are already redacted/capped.
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

  /// HTTP method, e.g. `GET`.
  final String method;

  /// Request URL with query/fragment/path secrets redacted.
  final String url;

  /// HTTP status code, or null if the response never arrived (transport error).
  final int? statusCode;

  /// Wall-clock duration from request start to completion, in milliseconds.
  final int durationMs;

  /// True request body size in bytes (even when the captured copy was capped).
  final int requestBodyBytes;

  /// True response body size in bytes (even when the captured copy was capped).
  /// Post-decompression when the client's `autoUncompress` is on (D-14).
  final int responseBodyBytes;

  /// Request headers with sensitive values redacted.
  final Map<String, String> requestHeaders;

  /// Response headers with sensitive values redacted.
  final Map<String, String> responseHeaders;

  /// Captured request body (redacted, size-capped, text only), or null.
  final String? requestBody;

  /// Captured response body (redacted, size-capped, text only), or null.
  final String? responseBody;

  /// Epoch milliseconds when the request started.
  final int timestampMs;

  /// Transport error description if the exchange failed mid-flight, else null.
  final String? errorText;

  /// This event as a JSON-encodable map (redacted fields only).
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
