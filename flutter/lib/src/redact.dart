library;

import 'dart:convert';

const redactMask = '[REDACTED]';

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

// whole-name matches only; short tokens live here so substrings aren't hit
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
};

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
  'email',
  'phone',
  'firstname',
  'lastname',
  'fullname',
  'username',
  'recipientname',
  'customername',
  'sendername',
  'passport',
  'nationality',
  'address',
  'birthdate',
  'dateofbirth',
  'promocode',
  'promotioncode',
  'messagetext',
  'giftmessage',
];

bool isSensitiveName(String name) {
  final n = name.toLowerCase().replaceAll(RegExp(r'[_\-$@.\s]'), '');
  if (_sensitiveExact.contains(n)) return true;
  for (final f in _sensitiveFragments) {
    if (n.contains(f)) return true;
  }
  return false;
}

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

String scrubValues(String s) {
  var out = s.replaceAllMapped(_digitRun, (m) {
    final digits = m[0]!.replaceAll(RegExp(r'[ -]'), '');
    if (digits.length > 40) return '[REDACTED-PAN]';
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

const _projMaxKeys = 512;
const _projMaxDepth = 12;
const _projMaxStrLen = 1024;

String? projectBody(String? body) {
  if (body == null || body.isEmpty) return null;
  final decoded = _tryJson(body) ?? _tryForm(body);
  if (decoded == null) return null;
  final out = <String, Object?>{};
  try {
    _flatten('', decoded, out, 0);
    if (out.isEmpty) return null;
    return jsonEncode(out);
  } catch (_) {
    return null;
  }
}

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
    if (v.startsWith('[REDACTED')) return;
    out[prefix] = v;
  } else if (v is num || v is bool) {
    out[prefix] = v;
  }
}
