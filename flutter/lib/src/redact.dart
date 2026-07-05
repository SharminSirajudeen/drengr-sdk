/// Secret and PII redaction for captured events. Common secrets in headers,
/// URLs, and bodies (tokens, keys, cookies, card numbers, …) are masked before
/// anything is stored or emitted.
///
/// Bodies are redacted structurally where possible (JSON is parsed and
/// sensitive keys masked; form-urlencoded is split on `&`) and then scrubbed at
/// the value level (card numbers, JWTs, bearer tokens, cookie lines) so secrets
/// are caught regardless of field name. All functions are best-effort and never
/// throw — on any failure the input is returned unchanged.
library;

import 'dart:convert';

const redactMask = '[REDACTED]';

/// Header names (lowercase) whose values are always masked.
const sensitiveHeaders = <String>{
  'authorization',
  'proxy-authorization',
  'cookie',
  'set-cookie',
  'x-auth-token',
  'x-api-key',
  'x-access-token',
  'x-session-token',
  'x-secret',
  'www-authenticate',
  'proxy-authenticate',
  'x-csrf-token',
  'x-xsrf-token',
};

/// Sensitive names matched as a WHOLE normalized name only. Short tokens live
/// here (not as substrings) so `shipping`/`spinner`/`opinion` aren't hit by
/// `pin`, etc.
const _sensitiveExact = <String>{
  'password',
  'passwd',
  'pwd',
  'pass',
  'passphrase',
  'secret',
  'token',
  'authorization',
  'pin',
  'cvv',
  'cvc',
  'csc',
  'cvv2',
  'ssn',
  'sin',
  'otp',
  'totp',
  'iban',
  // De-masked (3-tier policy): 'auth' (often a method/flag — real tokens are
  // caught by the bearer/JWT value scrubbers), 'pan' (Luhn value scrubber catches
  // real card numbers; the name collides with panel/panorama), 'sig' (a MAC, not
  // a replayable credential). 'authorization' stays masked.
};

/// Longer fragments safe to match as substrings of a normalized name.
const _sensitiveFragments = <String>[
  'token',
  'secret',
  'password',
  'passphrase',
  'apikey',
  'apisecret',
  'accesstoken',
  'refreshtoken',
  'idtoken',
  'oauthtoken',
  'privatekey',
  'secretkey',
  'sessiontoken',
  'cardnumber',
  'cardno',
  'ccnumber',
  'creditcard',
  'accountnumber',
  'routingnumber',
  'sortcode',
  // --- Personal data (PII), redacted by default. Mirrors the manual blocklist
  // real apps maintain for autocapture tools like Contentsquare (which don't
  // auto-redact) — Drengr ships it so 0-code means 0-code PII safety. A tenant
  // allowlists a field in the govern controls only when they deliberately want
  // it. Specific compounds only — bare 'name'/'message' would gut analytics.
  'email',
  'phone', // phone, phonenumber, recipientphonenumber, telephone
  'firstname',
  'lastname',
  'fullname',
  'username',
  'recipientname',
  'customername',
  'sendername',
  'passport',
  'nationality',
  'address', // address, addressline, recipientaddress, ipaddress, emailaddress
  'birthdate',
  'dateofbirth',
  'promocode',
  'promotioncode',
  'messagetext',
  'giftmessage',
  // De-masked: 'sessionid' (the funnel/correlation key — an identifier, not a
  // credential; 'sessiontoken' stays masked) and 'signature' (a MAC, not a secret).
];

/// Whether a header/query/field name denotes a secret.
bool isSensitiveName(String name) {
  final n = name.toLowerCase().replaceAll(RegExp(r'[_\-$@.\s]'), '');
  if (_sensitiveExact.contains(n)) return true;
  for (final f in _sensitiveFragments) {
    if (n.contains(f)) return true;
  }
  return false;
}

/// Mask the values of sensitive headers; preserve every key.
Map<String, String> redactHeaders(
    Map<String, String> headers, Set<String> extra) {
  final out = <String, String>{};
  headers.forEach((k, v) {
    final lk = k.toLowerCase();
    out[k] =
        (sensitiveHeaders.contains(lk) || extra.contains(lk)) ? redactMask : v;
  });
  return out;
}

// --- value-level scrubbers (run over any text or URL) ---

// 13+ digits with optional single space/dash separators between digits.
final _digitRun = RegExp(r'[0-9](?:[ -]?[0-9]){11,}');
final _jwt =
    RegExp(r'eyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]*');
final _bearer = RegExp(r'[Bb]earer\s+[A-Za-z0-9\-._~+/]+=*');
final _cookieLine = RegExp(r'^(set-cookie|cookie)\s*:\s*.*$',
    caseSensitive: false, multiLine: true);

bool _luhn(String digits) {
  if (digits.length < 13) return false;
  var sum = 0;
  var alt = false;
  for (var i = digits.length - 1; i >= 0; i--) {
    var n = digits.codeUnitAt(i) - 48;
    if (n < 0 || n > 9) return false;
    if (alt) {
      n *= 2;
      if (n > 9) n -= 9;
    }
    sum += n;
    alt = !alt;
  }
  return sum % 10 == 0;
}

/// Redact card numbers (Luhn-validated, separator-tolerant, embedded-aware),
/// JWTs, bearer tokens, and cookie lines anywhere in a string.
String scrubValues(String s) {
  var out = s.replaceAllMapped(_digitRun, (m) {
    final digits = m[0]!.replaceAll(RegExp(r'[ -]'), '');
    if (digits.length > 40) return '[REDACTED-PAN]'; // suspicious + bounds work
    for (var len = 13; len <= 19 && len <= digits.length; len++) {
      for (var i = 0; i + len <= digits.length; i++) {
        if (_luhn(digits.substring(i, i + len))) return '[REDACTED-PAN]';
      }
    }
    return m[0]!;
  });
  out = out.replaceAll(_jwt, '[REDACTED-JWT]');
  out = out.replaceAllMapped(_bearer, (_) => 'Bearer $redactMask');
  out = out.replaceAllMapped(_cookieLine, (m) => '${m[1]}: $redactMask');
  return out;
}

/// Mask sensitive query/fragment params and scrub secrets in the path.
String redactUrl(String url) {
  try {
    var result = url;
    final uri = Uri.tryParse(url);
    if (uri != null) {
      if (uri.hasQuery) {
        final masked = <String, List<String>>{};
        uri.queryParametersAll.forEach((k, vs) {
          masked[k] = isSensitiveName(k) ? const [redactMask] : vs;
        });
        result = uri.replace(queryParameters: masked).toString();
      }
      final frag = uri.fragment;
      if (frag.contains('=')) {
        final newFrag = frag.split('&').map((pair) {
          final i = pair.indexOf('=');
          if (i > 0 && isSensitiveName(pair.substring(0, i))) {
            return '${pair.substring(0, i)}=$redactMask';
          }
          return pair;
        }).join('&');
        result = result.replaceFirst('#$frag', '#$newFrag');
      }
    }
    return scrubValues(result);
  } catch (_) {
    return url;
  }
}

/// Redact a body string: structurally (JSON keys / form fields) then by value.
String redactBody(String body) {
  try {
    final decoded = _tryJson(body);
    if (decoded != null) return scrubValues(jsonEncode(_redactJson(decoded)));
    if (_looksFormEncoded(body)) return scrubValues(_redactFormEncoded(body));
    return scrubValues(body);
  } catch (_) {
    return body;
  }
}

Object? _tryJson(String body) {
  final t = body.trimLeft();
  if (t.isEmpty || (t[0] != '{' && t[0] != '[')) return null;
  try {
    return jsonDecode(body);
  } catch (_) {
    return null;
  }
}

dynamic _redactJson(dynamic v) {
  if (v is Map) {
    final out = <String, dynamic>{};
    v.forEach((k, val) {
      out['$k'] = isSensitiveName('$k') ? redactMask : _redactJson(val);
    });
    return out;
  }
  if (v is List) return v.map(_redactJson).toList();
  return v;
}

bool _looksFormEncoded(String body) {
  if (!body.contains('=') || body.contains('\n') || body.contains(' ')) {
    return false;
  }
  return RegExp(r'^[^=&]+=[^&]*(?:&[^=&]+=[^&]*)*$').hasMatch(body);
}

String _redactFormEncoded(String body) {
  return body.split('&').map((pair) {
    final i = pair.indexOf('=');
    if (i <= 0) return pair;
    final key = pair.substring(0, i);
    String name;
    try {
      name = Uri.decodeQueryComponent(key);
    } catch (_) {
      name = key;
    }
    return isSensitiveName(name) ? '$key=$redactMask' : pair;
  }).join('&');
}

// --- safe projection (the annotatable DTO shipped to the server) ---

const _projMaxKeys = 512;
const _projMaxDepth = 12;
const _projMaxStrLen = 1024;

/// Project an already-redacted body into a compact, safe map of
/// `dotted.path → scalar` for server-side annotation. Keeps only
/// analytics-bearing leaves (numbers, bools, short non-redacted strings) and
/// drops free-text, redaction masks, and structure. Returns a JSON object
/// string, or null when there is nothing structured/safe to project. The
/// device never decides what a field *means* — it only ships safe shapes; the
/// server maps shape → business event. Best-effort; never throws.
String? projectBody(String? body) {
  if (body == null || body.isEmpty) return null;
  final decoded = _tryJson(body) ?? _tryForm(body);
  if (decoded == null) return null; // only structured (JSON / form) bodies
  final out = <String, Object?>{};
  try {
    _flatten('', decoded, out, 0);
    if (out.isEmpty) return null;
    return jsonEncode(out);
  } catch (_) {
    return null;
  }
}

/// Parse an (already-redacted) form-urlencoded body into a flat map so it can be
/// projected like JSON. Returns null when the body isn't form-encoded.
Map<String, dynamic>? _tryForm(String body) {
  if (!_looksFormEncoded(body)) return null;
  final map = <String, dynamic>{};
  for (final pair in body.split('&')) {
    final i = pair.indexOf('=');
    if (i <= 0) continue;
    var k = pair.substring(0, i);
    var v = pair.substring(i + 1);
    try {
      k = Uri.decodeQueryComponent(k);
    } catch (_) {}
    try {
      v = Uri.decodeQueryComponent(v);
    } catch (_) {}
    map[k] = v;
  }
  return map.isEmpty ? null : map;
}

void _flatten(String prefix, dynamic v, Map<String, Object?> out, int depth) {
  if (out.length >= _projMaxKeys || depth > _projMaxDepth) return;
  if (v is Map) {
    v.forEach((k, val) {
      if (out.length < _projMaxKeys) {
        _flatten(prefix.isEmpty ? '$k' : '$prefix.$k', val, out, depth + 1);
      }
    });
  } else if (v is List) {
    for (var i = 0; i < v.length && out.length < _projMaxKeys; i++) {
      _flatten(prefix.isEmpty ? '$i' : '$prefix.$i', v[i], out, depth + 1);
    }
  } else if (v is String) {
    if (v.isEmpty || v.length > _projMaxStrLen) return;
    if (v.startsWith('[REDACTED')) return; // redactor dropped it — no signal
    out[prefix] = v;
  } else if (v is num || v is bool) {
    out[prefix] = v;
  }
  // null / other types: skip
}
