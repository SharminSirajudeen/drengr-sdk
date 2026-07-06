import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'capture.dart';
import 'network_event.dart';
import 'redact.dart';

/// Wraps a real [HttpClient], routing every request-creating call through the
/// inner client and wrapping the result so request/response bodies can be tee'd
/// WITHOUT altering the bytes the app sends or receives.
class CapturingHttpClient implements HttpClient {
  CapturingHttpClient(this._inner);
  final HttpClient _inner;

  static final Random _sampler = Random();

  Future<HttpClientRequest> _wrap(Future<HttpClientRequest> fut) async {
    final inner = await fut;
    final cap = DrengrCapture.instance;
    if (cap == null || !cap.enabled || cap.ignored(inner.uri)) return inner;
    if (cap.sampleRate < 1.0 && _sampler.nextDouble() >= cap.sampleRate) {
      return inner;
    }
    final when = cap.captureWhen;
    if (when != null) {
      try {
        if (!when(inner.uri)) return inner;
      } catch (_) {
        return inner;
      }
    }
    try {
      return _CapturingRequest(inner, cap);
    } catch (_) {
      return inner; // never break the app's networking
    }
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _wrap(_inner.openUrl(method, url));
  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      _wrap(_inner.open(method, host, port, path));

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _wrap(_inner.getUrl(url));
  @override
  Future<HttpClientRequest> postUrl(Uri url) => _wrap(_inner.postUrl(url));
  @override
  Future<HttpClientRequest> putUrl(Uri url) => _wrap(_inner.putUrl(url));
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => _wrap(_inner.deleteUrl(url));
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => _wrap(_inner.patchUrl(url));
  @override
  Future<HttpClientRequest> headUrl(Uri url) => _wrap(_inner.headUrl(url));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _wrap(_inner.get(host, port, path));
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _wrap(_inner.post(host, port, path));
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _wrap(_inner.put(host, port, path));
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _wrap(_inner.delete(host, port, path));
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _wrap(_inner.patch(host, port, path));
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _wrap(_inner.head(host, port, path));

  // ---- pure delegation ----
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool v) => _inner.autoUncompress = v;
  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration v) => _inner.idleTimeout = v;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? v) => _inner.connectionTimeout = v;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? v) => _inner.maxConnectionsPerHost = v;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? v) => _inner.userAgent = v;

  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _inner.authenticate = f;
  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _inner.authenticateProxy = f;
  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)? cb) =>
      _inner.badCertificateCallback = cb;
  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _inner.connectionFactory = f;
  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;
  @override
  set keyLog(void Function(String line)? cb) => _inner.keyLog = cb;

  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);
  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

/// Flatten multi-valued headers to a single string per name.
Map<String, String> _flattenHeaders(HttpHeaders headers) {
  final out = <String, String>{};
  headers.forEach((k, v) => out[k] = v.join(', '));
  return out;
}

/// Wraps an [HttpClientRequest]: tees a bounded copy of the request body and,
/// on close, wraps the response to capture status/headers/body/timing.
class _CapturingRequest implements HttpClientRequest {
  _CapturingRequest(this._inner, this._cap)
      : _reqBuf = CappedBuffer(_cap.maxBodyBytes),
        _startMs = DateTime.now().millisecondsSinceEpoch;

  final HttpClientRequest _inner;
  final DrengrCapture _cap;
  final CappedBuffer _reqBuf;
  final int _startMs;
  Future<HttpClientResponse>? _innerClose;
  Future<HttpClientResponse>? _wrapped;

  void _tee(List<int> data) {
    try {
      _reqBuf.add(data);
    } catch (_) {}
  }

  @override
  void add(List<int> data) {
    _tee(data);
    _inner.add(data);
  }

  @override
  Future addStream(Stream<List<int>> stream) {
    return _inner.addStream(stream.map((chunk) {
      _tee(chunk);
      return chunk;
    }));
  }

  @override
  void write(Object? object) {
    _tee(encoding.encode(object?.toString() ?? 'null'));
    _inner.write(object);
  }

  @override
  void writeln([Object? object = '']) {
    _tee(encoding.encode('${object ?? ''}\n'));
    _inner.writeln(object);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    _tee(encoding.encode(objects.join(separator)));
    _inner.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) {
    _tee(encoding.encode(String.fromCharCode(charCode)));
    _inner.writeCharCode(charCode);
  }

  // close() drives the inner send; close() and done resolve to the SAME wrapped
  // response so neither path bypasses capture.
  @override
  Future<HttpClientResponse> close() {
    _innerClose ??= _inner.close();
    return _wrapped ??= _innerClose!.then(_safeWrap);
  }

  @override
  Future<HttpClientResponse> get done =>
      _wrapped ??= _inner.done.then(_safeWrap);

  HttpClientResponse _safeWrap(HttpClientResponse resp) {
    try {
      return _buildResponse(resp);
    } catch (_) {
      return resp; // capture must never break the response path
    }
  }

  HttpClientResponse _buildResponse(HttpClientResponse resp) {
    final reqHeaders = _flattenHeaders(_inner.headers);
    final respHeaders = _flattenHeaders(resp.headers);
    final bodiesOk = _cap.bodiesAllowed(uri);
    final reqTextual = bodiesOk && isTextual(_inner.headers.contentType);
    final respTextual = bodiesOk && isTextual(resp.headers.contentType);
    final respBuf = CappedBuffer(_cap.maxBodyBytes);

    return _CapturingResponse(
      resp,
      onChunk: (chunk) {
        try {
          respBuf.add(chunk);
        } catch (_) {}
      },
      onComplete: (error) {
        try {
          final reqBody = reqTextual ? _reqBuf.text() : null;
          final respBody = respTextual ? respBuf.text() : null;
          _cap.emit(NetworkEvent(
            method: method,
            url: redactUrl(uri.toString()),
            statusCode: resp.statusCode,
            durationMs: DateTime.now().millisecondsSinceEpoch - _startMs,
            requestBodyBytes: _reqBuf.total,
            responseBodyBytes: respBuf.total,
            requestHeaders: _cap.redact(reqHeaders),
            responseHeaders: _cap.redact(respHeaders),
            requestBody: reqBody == null ? null : redactBody(reqBody),
            responseBody: respBody == null ? null : redactBody(respBody),
            timestampMs: _startMs,
            errorText: error?.toString(),
          ));
        } catch (_) {}
      },
    );
  }

  // ---- delegation ----
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  String get method => _inner.method;
  @override
  Uri get uri => _inner.uri;
  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding v) => _inner.encoding = v;
  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool v) => _inner.bufferOutput = v;
  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int v) => _inner.contentLength = v;
  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool v) => _inner.followRedirects = v;
  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int v) => _inner.maxRedirects = v;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool v) => _inner.persistentConnection = v;
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future flush() => _inner.flush();
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);
}

/// Wraps an [HttpClientResponse] stream. Tee-ing and completion both live in the
/// stream PIPELINE (`map` + a transformer), not in the subscription's handlers,
/// so a consumer that rebinds `onData`/`onDone` (Dio's `CastStream`, `drain()`,
/// `asFuture()`) cannot drop the capture. Errors complete the event too.
class _CapturingResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _CapturingResponse(this._inner,
      {required this.onChunk, required this.onComplete});
  final HttpClientResponse _inner;
  final void Function(List<int> chunk) onChunk;
  final void Function(Object? error) onComplete;
  bool _completed = false;

  void _complete(Object? error) {
    if (_completed) return;
    _completed = true;
    onComplete(error);
  }

  late final Stream<List<int>> _teed = _inner.map((chunk) {
    onChunk(chunk);
    return chunk;
  }).transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
    handleError: (e, st, sink) {
      _complete(e);
      sink.addError(e, st);
    },
    handleDone: (sink) {
      _complete(null);
      sink.close();
    },
  ));

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _teed.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  // ---- delegation ----
  @override
  int get statusCode => _inner.statusCode;
  @override
  String get reasonPhrase => _inner.reasonPhrase;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  int get contentLength => _inner.contentLength;
  @override
  bool get isRedirect => _inner.isRedirect;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  List<RedirectInfo> get redirects => _inner.redirects;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  X509Certificate? get certificate => _inner.certificate;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;
  @override
  Future<Socket> detachSocket() => _inner.detachSocket();
  @override
  Future<HttpClientResponse> redirect(
          [String? method, Uri? url, bool? followLoops]) =>
      _inner.redirect(method, url, followLoops);
}
