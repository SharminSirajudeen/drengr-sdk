/// Secret + PII redaction for captured events: structural key-masking +
/// value-level scrubbing; best-effort, never throws (input returned unchanged).
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

/// Whole-name matches only — short tokens here so `pin` doesn't hit `shipping`.
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
  // De-masked (3-tier policy): 'auth'/'pan'/'sig' — real tokens/cards caught by the
  // bearer/JWT/Luhn value scrubbers; names collide with panel/panorama. 'authorization' stays masked.
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
  // Rare-substring tokens as fragments to catch compounds (card_cvv, user_ssn); pin/pass/sin stay whole-name-only.
  'cvv',
  'cvc',
  'cvv2',
  'ssn',
  'otp',
  'totp',
  // Personal data (PII), redacted by default — 0-code means 0-code PII safety.
  // Specific compounds only — bare 'name'/'message' would gut analytics.
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
  // De-masked: 'sessionid' (correlation key, not a credential; 'sessiontoken' stays masked) and 'signature' (a MAC).
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

/// Mask the values of sensitive headers; preserve every key. Name-sensitive
/// (fixed set, caller extras, or a PII-denoting name like X-User-Phone) → full
/// mask; otherwise scrub PII values (a value can be PII under a benign header
/// name, e.g. X-Client-IP / X-Device-Id).
Map<String, String> redactHeaders(
    Map<String, String> headers, Set<String> extra) {
  final out = <String, String>{};
  headers.forEach((k, v) {
    final lk = k.toLowerCase();
    out[k] = (sensitiveHeaders.contains(lk) ||
            extra.contains(lk) ||
            isSensitiveName(k))
        ? redactMask
        : scrubValues(v);
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
// Free-text PII by VALUE PATTERN (audit blocker #1). Phone needs separators so bare id/timestamp runs aren't hit.
final _email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');
final _ssn = RegExp(r'\b\d{3}-\d{2}-\d{4}\b');
final _phone = RegExp(r'(?:\+\d{1,3}[ .-]?)?\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}\b');
// IPv4 and UUID (IDFA/GAID/device-id) — name-based masking leaks these when they
// ride in query params, custom headers, or free-text bodies.
final _ipv4 =
    RegExp(r'\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b');
final _uuid = RegExp(
    r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b');
// Well-known opaque SECRETS by unambiguous vendor prefix — catches a key under a
// benign field name (name-masking misses). Zero-FP by anchoring on the prefix.
final _secretToken = RegExp(
    r'\b(?:(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[opusr]_[A-Za-z0-9]{36,}|xox[baprs]-[A-Za-z0-9-]{10,})\b');
final _pem = RegExp(
    r'-----BEGIN[A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END[A-Z0-9 ]*PRIVATE KEY-----');

bool luhn(String digits) {
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
        if (luhn(digits.substring(i, i + len))) return '[REDACTED-PAN]';
      }
    }
    return m[0]!;
  });
  out = out.replaceAll(_jwt, '[REDACTED-JWT]');
  out = out.replaceAllMapped(_bearer, (_) => 'Bearer $redactMask');
  out = out.replaceAllMapped(_cookieLine, (m) => '${m[1]}: $redactMask');
  out = out.replaceAll(_email, '[REDACTED-EMAIL]');
  out = out.replaceAll(_ssn, '[REDACTED-SSN]');
  out = out.replaceAll(_phone, '[REDACTED-PHONE]');
  out = out.replaceAll(_secretToken, '[REDACTED-SECRET]');
  out = out.replaceAll(_pem, '[REDACTED-KEY]');
  out = out.replaceAll(_uuid, '[REDACTED-ID]');
  out = out.replaceAll(_ipv4, '[REDACTED-IP]');
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

// Mask a value whenever its adjacent NAME is sensitive — for bodies key-masking
// can't reach (JSON truncated past the cap, XML/SOAP) and inline literals in a
// parsed JSON string (GraphQL `query`). Value stops at any backslash/quote so a
// JSON-wrapped literal matches the INNERMOST name:"value" pair. Bounded → no ReDoS.
// _escNamed runs FIRST (anchored on the escaped quote) so a plain-quote wrapper
// can't shadow the first inner literal.
final _escNamed =
    RegExp(r'([A-Za-z][A-Za-z0-9_.\-]{0,63})(\s*[:=]\s*)\\"[^"\\]{0,8192}\\"');
final _dqNamed = RegExp(
    r'''(["']?)([A-Za-z][A-Za-z0-9_.\-]{0,63})\1(\s*[:=]\s*\\?")[^"\\]{0,8192}(\\?")''');
final _sqNamed = RegExp(
    r'''(["']?)([A-Za-z][A-Za-z0-9_.\-]{0,63})\1(\s*[:=]\s*\\?')[^'\\]{0,8192}(\\?')''');
final _xmlElem = RegExp(r'<([A-Za-z][A-Za-z0-9_.\-:]{0,63})>[^<]{0,8192}</\1\s*>');
final _jsonNum = RegExp(
    r'''("[A-Za-z][A-Za-z0-9_.\-]{0,63}"\s*:\s*)(-?\d[\d.eE+\-]{0,40}|true|false)''');

/// Mask a value whenever its adjacent name is sensitive, for bodies structural
/// masking can't reach (see note above). Best-effort.
String scrubNamedValues(String s) {
  String named(Match m) {
    final name = m[2]!;
    return isSensitiveName(name)
        ? '${m[1]}$name${m[1]}${m[3]}$redactMask${m[4]}'
        : m[0]!;
  }

  var out = s.replaceAllMapped(_escNamed, (m) {
    final name = m[1]!;
    return isSensitiveName(name) ? '$name${m[2]}\\"$redactMask\\"' : m[0]!;
  });
  out = out.replaceAllMapped(_dqNamed, named);
  out = out.replaceAllMapped(_sqNamed, named);
  out = out.replaceAllMapped(_xmlElem,
      (m) => isSensitiveName(m[1]!) ? '<${m[1]}>$redactMask</${m[1]}>' : m[0]!);
  out = out.replaceAllMapped(_jsonNum, (m) {
    final head = m[1]!;
    final name = head.substring(1, head.indexOf('"', 1));
    return isSensitiveName(name) ? '$head$redactMask' : m[0]!;
  });
  return out;
}

/// Redact a body string: structurally (JSON keys / form fields) then by value.
String redactBody(String body) {
  try {
    final decoded = _tryJson(body);
    final String out;
    if (decoded != null) {
      out = scrubValues(jsonEncode(_redactJson(decoded)));
    } else if (_looksFormEncoded(body)) {
      out = scrubValues(_redactFormEncoded(body));
    } else {
      out = scrubValues(body);
    }
    // Net values sensitive by NAME that structural + value passes missed. See scrubNamedValues.
    return scrubNamedValues(out);
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
    if (isSensitiveName(name)) return '$key=$redactMask';
    // Scrub the DECODED value — an encoded value slips past the outer scrub, then
    // projectBody decodes and ships the real secret.
    var val = pair.substring(i + 1);
    try {
      val = Uri.decodeQueryComponent(val);
    } catch (_) {/* keep raw */}
    return '$key=${scrubValues(val)}';
  }).join('&');
}

// --- safe projection (the annotatable DTO shipped to the server) ---

const _projMaxKeys = 512;
const _projMaxDepth = 12;
const _projMaxStrLen = 1024;

/// Project an already-redacted body into `dotted.path → scalar`, keeping only
/// analytics scalars (num/bool/short non-mask strings). Null when nothing safe
/// remains. The device never decides what a field *means* — server maps shape → event.
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
