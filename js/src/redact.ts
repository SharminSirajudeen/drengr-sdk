// Secret + PII redaction for captured events (port of redact.dart): structural
// key-masking + value-level scrubbing; best-effort, never throws (input unchanged).

export const redactMask = '[REDACTED]';

/** Header names (lowercase) whose values are always masked. */
export const sensitiveHeaders = new Set([
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
]);

/** Whole-name matches only — short tokens here so `pin` doesn't hit `shipping`. */
const sensitiveExact = new Set([
  'password', 'passwd', 'pwd', 'pass', 'passphrase', 'secret', 'token',
  'authorization', 'pin', 'cvv', 'cvc', 'csc', 'cvv2', 'ssn', 'sin',
  'otp', 'totp', 'iban',
  // De-masked (3-tier policy): 'auth', 'pan', 'sig' — see the Dart source note.
]);

/** Longer fragments safe to match as substrings of a normalized name. */
const sensitiveFragments = [
  'token', 'secret', 'password', 'passphrase', 'apikey', 'apisecret',
  'accesstoken', 'refreshtoken', 'idtoken', 'oauthtoken', 'privatekey',
  'secretkey', 'sessiontoken', 'cardnumber', 'cardno', 'ccnumber',
  'creditcard', 'accountnumber', 'routingnumber', 'sortcode',
  // Rare-substring tokens as fragments to catch compounds (card_cvv, user_ssn); pin/pass/sin stay whole-name-only.
  'cvv', 'cvc', 'cvv2', 'ssn', 'otp', 'totp', 'passphrase',
  // Personal data (PII), redacted by default — 0-code means 0-code PII safety.
  'email', 'phone', 'firstname', 'lastname', 'fullname', 'username',
  'recipientname', 'customername', 'sendername', 'passport', 'nationality',
  'address', 'birthdate', 'dateofbirth', 'promocode', 'promotioncode',
  'messagetext', 'giftmessage',
  // De-masked: 'sessionid' (correlation key, not a credential), 'signature'.
];

/** Whether a header/query/field name denotes a secret. */
export function isSensitiveName(name: string): boolean {
  const n = name.toLowerCase().replace(/[_\-$@.\s]/g, '');
  if (sensitiveExact.has(n)) return true;
  for (const f of sensitiveFragments) {
    if (n.includes(f)) return true;
  }
  return false;
}

/** Mask the values of sensitive headers; preserve every key. */
export function redactHeaders(
  headers: Record<string, string>,
  extra: Set<string> = new Set(),
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(headers)) {
    const lk = k.toLowerCase();
    // Name-sensitive (fixed set, caller extras, or a PII-denoting name like
    // X-User-Phone) → full mask; otherwise scrub PII values (a value can be PII
    // under a benign header name, e.g. X-Client-IP / X-Device-Id).
    out[k] = sensitiveHeaders.has(lk) || extra.has(lk) || isSensitiveName(k)
      ? redactMask
      : scrubValues(v);
  }
  return out;
}

// --- value-level scrubbers (run over any text or URL) ---

// 13+ digits with optional single space/dash separators between digits.
const digitRun = /[0-9](?:[ -]?[0-9]){11,}/g;
const jwtRe = /eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]*/g;
const bearerRe = /[Bb]earer\s+[A-Za-z0-9\-._~+/]+=*/g;
const cookieLineRe = /^(set-cookie|cookie)\s*:\s*.*$/gim;
// Free-text PII by VALUE PATTERN (audit blocker #1). Phone needs separators so bare id/timestamp runs aren't hit.
const emailRe = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const ssnRe = /\b\d{3}-\d{2}-\d{4}\b/g;
const phoneRe = /(?:\+\d{1,3}[ .-]?)?\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}\b/g;
// IPv4 and UUID (IDFA/GAID/device-id) — real-data validation showed name-based masking
// leaks these when they ride in query params, custom headers, or free-text bodies.
const ipv4Re = /\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b/g;
const uuidRe = /\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/g;
// Well-known opaque SECRETS by unambiguous vendor prefix — catches a key under a
// benign field name (name-masking misses). Zero-FP by anchoring on the prefix.
const secretTokenRe = /\b(?:(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[opusr]_[A-Za-z0-9]{36,}|xox[baprs]-[A-Za-z0-9-]{10,})\b/g;
// PEM private key block (catastrophic if shipped).
const pemRe = /-----BEGIN[A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END[A-Z0-9 ]*PRIVATE KEY-----/g;

export function luhn(digits: string): boolean {
  if (digits.length < 13) return false;
  let sum = 0;
  let alt = false;
  for (let i = digits.length - 1; i >= 0; i--) {
    let n = digits.charCodeAt(i) - 48;
    if (n < 0 || n > 9) return false;
    if (alt) {
      n *= 2;
      if (n > 9) n -= 9;
    }
    sum += n;
    alt = !alt;
  }
  return sum % 10 === 0;
}

/** Redact card numbers, JWTs, bearer tokens, cookie lines, and PII anywhere in a string. */
export function scrubValues(s: string): string {
  let out = s.replace(digitRun, (m) => {
    const digits = m.replace(/[ -]/g, '');
    if (digits.length > 40) return '[REDACTED-PAN]'; // suspicious + bounds work
    for (let len = 13; len <= 19 && len <= digits.length; len++) {
      for (let i = 0; i + len <= digits.length; i++) {
        if (luhn(digits.substring(i, i + len))) return '[REDACTED-PAN]';
      }
    }
    return m;
  });
  out = out.replace(jwtRe, '[REDACTED-JWT]');
  out = out.replace(bearerRe, `Bearer ${redactMask}`);
  out = out.replace(cookieLineRe, (_m, p1: string) => `${p1}: ${redactMask}`);
  out = out.replace(emailRe, '[REDACTED-EMAIL]');
  out = out.replace(ssnRe, '[REDACTED-SSN]');
  out = out.replace(phoneRe, '[REDACTED-PHONE]');
  out = out.replace(secretTokenRe, '[REDACTED-SECRET]');
  out = out.replace(pemRe, '[REDACTED-KEY]');
  out = out.replace(uuidRe, '[REDACTED-ID]');
  out = out.replace(ipv4Re, '[REDACTED-IP]');
  return out;
}

/** Mask sensitive query/fragment params and scrub secrets in the path. */
export function redactUrl(url: string): string {
  try {
    let result = url;
    let u: URL | null = null;
    let relative = false;
    try {
      u = new URL(url);
    } catch {
      // Relative URL: parse against a dummy base so query/fragment masking runs, then strip it — else params leak.
      try {
        u = new URL(url, 'http://drengr.invalid');
        relative = true;
      } catch {
        u = null;
      }
    }
    if (u) {
      if (u.search.length > 1) {
        const params = new URLSearchParams(u.search);
        const masked = new URLSearchParams();
        for (const [k, v] of params) {
          masked.append(k, isSensitiveName(k) ? redactMask : v);
        }
        u.search = masked.toString();
      }
      const frag = u.hash.startsWith('#') ? u.hash.slice(1) : u.hash;
      if (frag.includes('=')) {
        const newFrag = frag
          .split('&')
          .map((pair) => {
            const i = pair.indexOf('=');
            if (i > 0 && isSensitiveName(pair.substring(0, i))) {
              return `${pair.substring(0, i)}=${redactMask}`;
            }
            return pair;
          })
          .join('&');
        u.hash = `#${newFrag}`;
      }
      result = relative ? u.toString().slice('http://drengr.invalid'.length) : u.toString();
    }
    return scrubValues(result);
  } catch {
    return url;
  }
}

// Mask a value whenever its adjacent NAME is sensitive — for bodies key-masking
// can't reach (JSON truncated past the cap, XML/SOAP) and inline literals in a
// parsed JSON string (GraphQL `query`). Value stops at any backslash/quote so a
// JSON-wrapped literal matches the INNERMOST name:"value" pair. Bounded → no ReDoS.
// escNamed runs FIRST (anchored on the escaped quote) so a plain-quote wrapper
// can't shadow the first inner literal.
const escNamedRe = /([A-Za-z][A-Za-z0-9_.\-]{0,63})(\s*[:=]\s*)\\"[^"\\]{0,8192}\\"/g;
const dqNamedRe = /(["']?)([A-Za-z][A-Za-z0-9_.\-]{0,63})\1(\s*[:=]\s*\\?")[^"\\]{0,8192}(\\?")/g;
const sqNamedRe = /(["']?)([A-Za-z][A-Za-z0-9_.\-]{0,63})\1(\s*[:=]\s*\\?')[^'\\]{0,8192}(\\?')/g;
// XML element text: <name>value</name>
const xmlElemRe = /<([A-Za-z][A-Za-z0-9_.\-:]{0,63})>[^<]{0,8192}<\/\1\s*>/g;
// Bare numeric/bool under a quoted JSON key ("cvv":123) — value-scrubbing skips short digit runs, so it'd leak.
const jsonNumRe = /("[A-Za-z][A-Za-z0-9_.\-]{0,63}"\s*:\s*)(-?\d[\d.eE+\-]{0,40}|true|false)/g;

/** Mask values whose adjacent name is sensitive (see note above). Best-effort. */
export function scrubNamedValues(s: string): string {
  let out = s.replace(escNamedRe, (m, name, sep) =>
    isSensitiveName(name) ? `${name}${sep}\\"${redactMask}\\"` : m);
  out = out.replace(dqNamedRe, (m, q, name, sep, close) =>
    isSensitiveName(name) ? `${q}${name}${q}${sep}${redactMask}${close}` : m);
  out = out.replace(sqNamedRe, (m, q, name, sep, close) =>
    isSensitiveName(name) ? `${q}${name}${q}${sep}${redactMask}${close}` : m);
  out = out.replace(xmlElemRe, (m, name) =>
    isSensitiveName(name) ? `<${name}>${redactMask}</${name}>` : m);
  out = out.replace(jsonNumRe, (m, head, _val) => {
    const name = head.slice(1, head.indexOf('"', 1));
    return isSensitiveName(name) ? `${head}${redactMask}` : m;
  });
  return out;
}

/** Redact a body string: structurally (JSON keys / form fields) then by value. */
export function redactBody(body: string): string {
  try {
    const decoded = tryJson(body);
    let out: string;
    if (decoded !== undefined) out = scrubValues(JSON.stringify(redactJson(decoded)));
    else if (looksFormEncoded(body)) out = scrubValues(redactFormEncoded(body));
    else out = scrubValues(body);
    // Net values sensitive by NAME that survived structural + value passes. See scrubNamedValues.
    return scrubNamedValues(out);
  } catch {
    return body;
  }
}

function tryJson(body: string): unknown {
  const t = body.trimStart();
  if (t.length === 0 || (t[0] !== '{' && t[0] !== '[')) return undefined;
  try {
    return JSON.parse(body);
  } catch {
    return undefined;
  }
}

function redactJson(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(redactJson);
  if (v !== null && typeof v === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      out[k] = isSensitiveName(k) ? redactMask : redactJson(val);
    }
    return out;
  }
  return v;
}

function looksFormEncoded(body: string): boolean {
  if (!body.includes('=') || body.includes('\n') || body.includes(' ')) return false;
  return /^[^=&]+=[^&]*(?:&[^=&]+=[^&]*)*$/.test(body);
}

function redactFormEncoded(body: string): string {
  return body
    .split('&')
    .map((pair) => {
      const i = pair.indexOf('=');
      if (i <= 0) return pair;
      const key = pair.substring(0, i);
      let name = key;
      try {
        name = decodeURIComponent(key.replace(/\+/g, ' '));
      } catch {
        /* keep raw */
      }
      if (isSensitiveName(name)) return `${key}=${redactMask}`;
      // Scrub the DECODED value — else an encoded value slips the outer scrubValues and projectBody ships the secret.
      let val = pair.substring(i + 1);
      try {
        val = decodeURIComponent(val.replace(/\+/g, ' '));
      } catch {
        /* keep raw */
      }
      return `${key}=${scrubValues(val)}`;
    })
    .join('&');
}

// --- safe projection (the annotatable DTO shipped to the server) ---

const projMaxKeys = 512;
const projMaxDepth = 12;
const projMaxStrLen = 1024;

/** Project an already-redacted body into `dotted.path → scalar`, keeping only
 *  analytics scalars (num/bool/short non-mask strings). Null when nothing safe remains. */
export function projectBody(body: string | null | undefined): string | null {
  if (!body) return null;
  const decoded = tryJson(body) ?? tryForm(body);
  if (decoded === undefined || decoded === null) return null;
  const out: Record<string, unknown> = {};
  try {
    flatten('', decoded, out, 0);
    if (Object.keys(out).length === 0) return null;
    return JSON.stringify(out);
  } catch {
    return null;
  }
}

function tryForm(body: string): Record<string, string> | undefined {
  if (!looksFormEncoded(body)) return undefined;
  const map: Record<string, string> = {};
  for (const pair of body.split('&')) {
    const i = pair.indexOf('=');
    if (i <= 0) continue;
    let k = pair.substring(0, i);
    let v = pair.substring(i + 1);
    try {
      k = decodeURIComponent(k.replace(/\+/g, ' '));
    } catch { /* keep raw */ }
    try {
      v = decodeURIComponent(v.replace(/\+/g, ' '));
    } catch { /* keep raw */ }
    map[k] = v;
  }
  return Object.keys(map).length === 0 ? undefined : map;
}

function flatten(
  prefix: string,
  v: unknown,
  out: Record<string, unknown>,
  depth: number,
): void {
  if (Object.keys(out).length >= projMaxKeys || depth > projMaxDepth) return;
  if (Array.isArray(v)) {
    for (let i = 0; i < v.length && Object.keys(out).length < projMaxKeys; i++) {
      flatten(prefix === '' ? `${i}` : `${prefix}.${i}`, v[i], out, depth + 1);
    }
  } else if (v !== null && typeof v === 'object') {
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      if (Object.keys(out).length < projMaxKeys) {
        flatten(prefix === '' ? k : `${prefix}.${k}`, val, out, depth + 1);
      }
    }
  } else if (typeof v === 'string') {
    if (v.length === 0 || v.length > projMaxStrLen) return;
    if (v.startsWith('[REDACTED')) return; // redactor dropped it — no signal
    out[prefix] = v;
  } else if (typeof v === 'number' || typeof v === 'boolean') {
    out[prefix] = v;
  }
  // null / other types: skip
}
