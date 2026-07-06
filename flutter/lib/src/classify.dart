/// PII-vault classifier (seal-by-default splitter). One pass over a captured
/// body splits every leaf into DROP (credentials/PCI), SEAL (PII/unknown
/// free-text), or KEEP (business signal). Typed placeholders keep each leaf's
/// type stable. Fail-closed: a value reaches the plaintext projection only if it
/// is credential-free AND (numeric/bool not-PII OR business-allowlisted).
library;

import 'dart:convert';

import 'redact.dart' show luhn;

/// Split of a captured body into a plaintext projection + a sealed PII map.
class Classified {
  const Classified(this.projection, this.piiMap, this.piiPaths);

  /// dotted.path -> business scalar | typed placeholder (JSON), or null.
  final String? projection;

  /// dotted.path -> raw value (JSON-encoded scalar) to encrypt on-device.
  final Map<String, String> piiMap;

  /// paths whose value was sealed.
  final List<String> piiPaths;
}

const _maxKeys = 512;
const _maxDepth = 12;
const _maxStr = 1024;

String _norm(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[_\-$@.\s]'), '');

const _credentialNames = <String>{
  'password', 'passwd', 'pwd', 'pass', 'passphrase', 'secret', 'clientsecret',
  'token', 'apikey', 'apisecret', 'accesstoken', 'refreshtoken', 'idtoken',
  'oauthtoken', 'bearertoken', 'privatekey', 'secretkey', 'sessiontoken',
  'authorization', 'auth', 'otp', 'totp', 'csrf', 'xsrf', 'csrftoken',
  'xsrftoken', 'cvv', 'cvc', 'cvv2', 'csc', 'pin', 'cardnumber', 'cardno',
  'ccnumber', 'creditcard', 'pan',
};

const _piiNames = <String>{
  'email', 'phone', 'mobile', 'tel', 'telephone', 'fax', 'firstname',
  'lastname', 'middlename', 'fullname', 'username', 'nickname', 'customername',
  'recipientname', 'sendername', 'contactname', 'ssn', 'sin', 'iban',
  'accountnumber', 'routingnumber', 'sortcode', 'passport', 'nationality',
  'dob', 'dateofbirth', 'birthdate', 'address', 'street', 'zip', 'zipcode',
  'postal', 'postalcode', 'lat', 'latitude', 'lng', 'lon', 'longitude', 'geo',
  'coordinates', 'ip', 'ipaddress', 'deviceid', 'idfa', 'gaid', 'adid', 'imei',
  'macaddress', 'promocode', 'promotioncode', 'coupon', 'giftmessage',
  'messagetext',
};

const _businessAllowlist = <String>{
  'status', 'statuscode', 'httpstatus', 'responsecode', 'code', 'state',
  'result', 'outcome', 'declinereason', 'declinecode', 'reason', 'errorcode',
  'currency', 'amount', 'price', 'total', 'subtotal', 'tax', 'shipping',
  'discount', 'fee', 'balance', 'cost', 'revenue', 'quantity', 'qty', 'count',
  'sku', 'productid', 'itemid', 'variantid', 'orderid', 'transactionid',
  'paymentid', 'invoiceid', 'plan', 'planid', 'tier', 'type', 'kind',
  'category', 'subcategory', 'event', 'eventname', 'action', 'method',
  'httpmethod', 'verb', 'success', 'ok', 'enabled', 'active', 'error',
  'duration', 'latency', 'elapsed', 'level', 'score', 'rating', 'stars',
  'version', 'appversion', 'build', 'step', 'index', 'page', 'pagesize',
  'limit', 'offset',
};

final _credRe = <RegExp>[
  RegExp(r'eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]*'),
  RegExp(r'[Bb]earer\s+[A-Za-z0-9\-._~+/]+=*'),
  RegExp(
      r'\b(?:(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[opusr]_[A-Za-z0-9]{36,}|xox[baprs]-[A-Za-z0-9-]{10,})\b'),
  RegExp(r'-----BEGIN[A-Z0-9 ]*PRIVATE KEY-----'),
];
final _email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');
final _ssn = RegExp(r'\b\d{3}-\d{2}-\d{4}\b');
final _phone = RegExp(r'(?:\+\d{1,3}[ .-]?)?\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}\b');
final _ipv4 =
    RegExp(r'\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b');
final _ipv6 = RegExp(r'\b(?:[A-Fa-f0-9]{1,4}:){2,7}[A-Fa-f0-9]{0,4}\b');
final _uuid = RegExp(
    r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b');
final _digitRun = RegExp(r'[0-9](?:[ -]?[0-9]){11,}');

bool _credentialValue(String s) => _credRe.any((re) => re.hasMatch(s));

bool _panValue(String s) {
  final m = _digitRun.firstMatch(s);
  if (m == null) return false;
  final d = m[0]!.replaceAll(RegExp(r'[ -]'), '');
  if (d.length > 40) return true;
  for (var len = 13; len <= 19 && len <= d.length; len++) {
    for (var i = 0; i + len <= d.length; i++) {
      if (luhn(d.substring(i, i + len))) return true;
    }
  }
  return false;
}

String? _piiKind(String s) {
  if (_email.hasMatch(s)) return 'email';
  if (_ssn.hasMatch(s)) return 'ssn';
  if (_phone.hasMatch(s)) return 'phone';
  if (_ipv4.hasMatch(s) || _ipv6.hasMatch(s)) return 'ip';
  if (_uuid.hasMatch(s)) return 'deviceid';
  return null;
}

Object? _sameTyped(Object? v, String label) =>
    v is num ? 0 : (v is bool ? false : label);

class _Disp {
  const _Disp.keep(this.value)
      : kind = 0,
        raw = null,
        path = null;
  const _Disp.drop(this.value)
      : kind = 1,
        raw = null,
        path = null;
  const _Disp.seal(this.value, this.raw, this.path) : kind = 2;
  final int kind;
  final Object? value;
  final String? raw;
  final String? path;
}

_Disp _classifyLeaf(String key, String path, Object? v) {
  final n = _norm(key);
  if (v is String && (_credentialValue(v) || _panValue(v))) {
    return _Disp.drop(_sameTyped(v, '[REDACTED-SECRET]'));
  }
  if (_credentialNames.contains(n)) {
    return _Disp.drop(_sameTyped(v, '[REDACTED-SECRET]'));
  }
  final vk = v is String ? _piiKind(v) : null;
  if (vk != null) return _Disp.seal('[PII:$vk]', jsonEncode(v), path);
  if (_piiNames.contains(n)) {
    return _Disp.seal(_sameTyped(v, '[PII:$n]'), jsonEncode(v), path);
  }
  if (v is num || v is bool) return _Disp.keep(v);
  if (v is String) {
    if (v.isEmpty) return _Disp.keep(v);
    if (v.length > _maxStr) return _Disp.drop('[FREETEXT:len=${v.length}]');
    if (_businessAllowlist.contains(n) &&
        v.length <= 64 &&
        !RegExp(r'\s{2,}').hasMatch(v)) {
      return _Disp.keep(v);
    }
    return _Disp.seal('[PII]', jsonEncode(v), path);
  }
  return _Disp.drop(_sameTyped(v, '[REDACTED]'));
}

Classified _empty() => Classified(null, <String, String>{}, <String>[]);

/// Split a captured body into { projection, piiMap, piiPaths }.
Classified classifyBody(String? body) {
  if (body == null || body.isEmpty) return _empty();
  final decoded = _parseJson(body) ?? _parseForm(body);
  if (decoded == null) return _empty();

  final proj = <String, Object?>{};
  final piiMap = <String, String>{};
  final piiPaths = <String>[];

  void walk(String prefix, String key, Object? v, int depth) {
    if (proj.length >= _maxKeys || depth > _maxDepth) return;
    if (v is List) {
      for (var i = 0; i < v.length && proj.length < _maxKeys; i++) {
        walk(prefix.isEmpty ? '$i' : '$prefix.$i', key, v[i], depth + 1);
      }
      return;
    }
    if (v is Map) {
      v.forEach((k, val) {
        if (proj.length < _maxKeys) {
          walk(prefix.isEmpty ? '$k' : '$prefix.$k', '$k', val, depth + 1);
        }
      });
      return;
    }
    if (v == null) return;
    final d = _classifyLeaf(key, prefix, v);
    proj[prefix] = d.value;
    if (d.kind == 2) {
      piiMap[d.path!] = d.raw!;
      piiPaths.add(d.path!);
    }
  }

  try {
    walk('', '', decoded, 0);
  } catch (_) {
    return _empty();
  }
  if (proj.isEmpty) return _empty();
  return Classified(jsonEncode(proj), piiMap, piiPaths);
}

Object? _parseJson(String body) {
  final t = body.trimLeft();
  if (t.isEmpty || (t[0] != '{' && t[0] != '[')) return null;
  try {
    return jsonDecode(body);
  } catch (_) {
    return null;
  }
}

Map<String, String>? _parseForm(String body) {
  if (!body.contains('=') || body.contains('\n') || body.contains(' ')) {
    return null;
  }
  if (!RegExp(r'^[^=&]+=[^&]*(?:&[^=&]+=[^&]*)*$').hasMatch(body)) return null;
  final map = <String, String>{};
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
