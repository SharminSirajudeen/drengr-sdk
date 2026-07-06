// classify.ts — the PII-vault classifier (seal-by-default splitter). One pass over a
// captured body/url/headers splits every leaf into three dispositions:
//   • DROP  — credentials + PCI card data: replaced by a [REDACTED-*] token, NEVER stored raw or sealed.
//   • SEAL  — PII + unknown free-text strings: the raw value goes into piiMap for client-side
//             encryption (seal.ts); a SAME-TYPED placeholder goes to the plaintext projection.
//   • KEEP  — business signal (numbers/bools not PII-detected; allowlisted enum names): plaintext,
//             so the server-side discovery engine still sees it.
// Typed placeholders keep each leaf's type stable, so the shape fingerprint is byte-identical to
// what it would be with the raw value. Fail-closed: a value reaches the plaintext projection ONLY
// if it is credential-free AND (numeric/bool not-PII OR business-allowlisted) — everything else seals.

import { luhn } from './redact.js';

export interface Classified {
  /** dotted.path -> business scalar | typed placeholder. JSON string, or null if nothing remains. */
  projection: string | null;
  /** dotted.path -> raw value (JSON-stringified scalar) to encrypt on-device. */
  piiMap: Record<string, string>;
  /** paths whose value was sealed (so the server/propose never map a dim/measure onto a placeholder). */
  piiPaths: string[];
}

const MAX_KEYS = 512;
const MAX_DEPTH = 12;
const MAX_STR = 1024;
const norm = (name: string) => name.toLowerCase().replace(/[_\-$@.\s]/g, '');

// --- name sets (normalized: lowercased, separators stripped) ---

/** DROP — pure secrets + PCI card data. Worthless as analytics, dangerous even encrypted. */
const CREDENTIAL_NAMES = new Set([
  'password', 'passwd', 'pwd', 'pass', 'passphrase', 'secret', 'clientsecret', 'token',
  'apikey', 'apisecret', 'accesstoken', 'refreshtoken', 'idtoken', 'oauthtoken', 'bearertoken',
  'privatekey', 'secretkey', 'sessiontoken', 'authorization', 'auth', 'otp', 'totp',
  'csrf', 'xsrf', 'csrftoken', 'xsrftoken',
  'cvv', 'cvc', 'cvv2', 'csc', 'pin', 'cardnumber', 'cardno', 'ccnumber', 'creditcard', 'pan',
]);

/** SEAL — PII the tenant may legitimately want to see decrypted, but Drengr must not. */
const PII_NAMES = new Set([
  'email', 'phone', 'mobile', 'tel', 'telephone', 'fax',
  'firstname', 'lastname', 'middlename', 'fullname', 'username', 'nickname',
  'customername', 'recipientname', 'sendername', 'contactname',
  'ssn', 'sin', 'iban', 'accountnumber', 'routingnumber', 'sortcode',
  'passport', 'nationality', 'dob', 'dateofbirth', 'birthdate',
  'address', 'street', 'zip', 'zipcode', 'postal', 'postalcode',
  'lat', 'latitude', 'lng', 'lon', 'longitude', 'geo', 'coordinates',
  'ip', 'ipaddress', 'deviceid', 'idfa', 'gaid', 'adid', 'imei', 'macaddress',
  'promocode', 'promotioncode', 'coupon', 'giftmessage', 'messagetext',
]);

/** KEEP — the business signal the discovery engine names events from (short/enum/number/known-id). */
const BUSINESS_ALLOWLIST = new Set([
  'status', 'statuscode', 'httpstatus', 'responsecode', 'code', 'state', 'result', 'outcome',
  'declinereason', 'declinecode', 'reason', 'errorcode',
  'currency', 'amount', 'price', 'total', 'subtotal', 'tax', 'shipping', 'discount', 'fee',
  'balance', 'cost', 'revenue', 'quantity', 'qty', 'count',
  'sku', 'productid', 'itemid', 'variantid', 'orderid', 'transactionid', 'paymentid', 'invoiceid',
  'plan', 'planid', 'tier', 'type', 'kind', 'category', 'subcategory',
  'event', 'eventname', 'action', 'method', 'httpmethod', 'verb',
  'success', 'ok', 'enabled', 'active', 'error',
  'duration', 'latency', 'elapsed', 'level', 'score', 'rating', 'stars',
  'version', 'appversion', 'build', 'step', 'index', 'page', 'pagesize', 'limit', 'offset',
]);

// --- value detectors ---
const credRe = [
  /eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]*/,                                   // JWT
  /[Bb]earer\s+[A-Za-z0-9\-._~+/]+=*/,                                                          // Bearer
  /\b(?:(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[opusr]_[A-Za-z0-9]{36,}|xox[baprs]-[A-Za-z0-9-]{10,})\b/, // vendor keys
  /-----BEGIN[A-Z0-9 ]*PRIVATE KEY-----/,                                                       // PEM
];
const emailRe = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;
const ssnRe = /\b\d{3}-\d{2}-\d{4}\b/;
const phoneRe = /(?:\+\d{1,3}[ .-]?)?\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}\b/;
const ipv4Re = /\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b/;
const ipv6Re = /\b(?:[A-Fa-f0-9]{1,4}:){2,7}[A-Fa-f0-9]{0,4}\b/;
const uuidRe = /\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/; // IDFA/GAID
const digitRun = /[0-9](?:[ -]?[0-9]){11,}/;

type Disp = { keep: unknown } | { drop: unknown } | { seal: unknown; raw: string; path: string };

function credentialValue(s: string): boolean {
  return credRe.some((re) => re.test(s));
}
function panValue(s: string): boolean {
  const m = s.match(digitRun);
  if (!m) return false;
  const d = m[0].replace(/[ -]/g, '');
  if (d.length > 40) return true;
  for (let len = 13; len <= 19 && len <= d.length; len++)
    for (let i = 0; i + len <= d.length; i++) if (luhn(d.substring(i, i + len))) return true;
  return false;
}
function piiKind(s: string): string | null {
  if (emailRe.test(s)) return 'email';
  if (ssnRe.test(s)) return 'ssn';
  if (phoneRe.test(s)) return 'phone';
  if (ipv4Re.test(s) || ipv6Re.test(s)) return 'ip';
  if (uuidRe.test(s)) return 'deviceid';
  return null;
}
const sameTyped = (v: unknown, label: string): unknown =>
  typeof v === 'number' ? 0 : typeof v === 'boolean' ? false : label;

/** Classify one leaf. `key` is the field name (last non-index path segment); `path` its dotted path. */
function classifyLeaf(key: string, path: string, v: unknown): Disp {
  const n = norm(key);

  // 1. credential by value or name -> DROP (never sealed, never recoverable)
  if (typeof v === 'string' && (credentialValue(v) || panValue(v))) return { drop: sameTyped(v, '[REDACTED-SECRET]') };
  if (CREDENTIAL_NAMES.has(n)) return { drop: sameTyped(v, '[REDACTED-SECRET]') };

  // 2. PII by value or name -> SEAL
  const vk = typeof v === 'string' ? piiKind(v) : null;
  if (vk) return { seal: `[PII:${vk}]`, raw: JSON.stringify(v), path };
  if (PII_NAMES.has(n)) return { seal: sameTyped(v, `[PII:${n}]`), raw: JSON.stringify(v), path };

  // 3. numbers / booleans that survived credential+PII checks are business signal -> KEEP
  if (typeof v === 'number' || typeof v === 'boolean') return { keep: v };

  // 4. strings: allowlisted short enum -> KEEP; everything else seals (free-text default)
  if (typeof v === 'string') {
    if (v.length === 0) return { keep: v };
    if (v.length > MAX_STR) return { drop: `[FREETEXT:len=${v.length}]` };
    if (BUSINESS_ALLOWLIST.has(n) && v.length <= 64 && !/\s{2,}/.test(v)) return { keep: v };
    return { seal: '[PII]', raw: JSON.stringify(v), path };
  }
  // 5. other (should not reach — objects handled by the walker)
  return { drop: sameTyped(v, '[REDACTED]') };
}

/** Split a captured body into { projection, piiMap, piiPaths }. */
export function classifyBody(body: string | null | undefined): Classified {
  const empty: Classified = { projection: null, piiMap: {}, piiPaths: [] };
  if (!body) return empty;
  const decoded = parseJson(body) ?? parseForm(body);
  if (decoded === undefined || decoded === null) return empty;

  const proj: Record<string, unknown> = {};
  const piiMap: Record<string, string> = {};
  const piiPaths: string[] = [];

  const walk = (prefix: string, key: string, v: unknown, depth: number): void => {
    if (Object.keys(proj).length >= MAX_KEYS || depth > MAX_DEPTH) return;
    if (Array.isArray(v)) {
      for (let i = 0; i < v.length && Object.keys(proj).length < MAX_KEYS; i++)
        walk(prefix === '' ? `${i}` : `${prefix}.${i}`, key, v[i], depth + 1); // array items keep parent key
      return;
    }
    if (v !== null && typeof v === 'object') {
      for (const [k, val] of Object.entries(v as Record<string, unknown>))
        if (Object.keys(proj).length < MAX_KEYS) walk(prefix === '' ? k : `${prefix}.${k}`, k, val, depth + 1);
      return;
    }
    if (v === null || typeof v === 'undefined') return;
    const d = classifyLeaf(key, prefix, v);
    if ('keep' in d) proj[prefix] = d.keep;
    else if ('drop' in d) proj[prefix] = d.drop;
    else {
      proj[prefix] = d.seal;
      piiMap[d.path] = d.raw;
      piiPaths.push(d.path);
    }
  };

  try {
    walk('', '', decoded, 0);
  } catch {
    return empty;
  }
  if (Object.keys(proj).length === 0) return empty;
  return { projection: JSON.stringify(proj), piiMap, piiPaths };
}

function parseJson(body: string): unknown {
  const t = body.trimStart();
  if (t.length === 0 || (t[0] !== '{' && t[0] !== '[')) return undefined;
  try {
    return JSON.parse(body);
  } catch {
    return undefined;
  }
}
function parseForm(body: string): Record<string, string> | undefined {
  if (!body.includes('=') || body.includes('\n') || body.includes(' ')) return undefined;
  if (!/^[^=&]+=[^&]*(?:&[^=&]+=[^&]*)*$/.test(body)) return undefined;
  const map: Record<string, string> = {};
  for (const pair of body.split('&')) {
    const i = pair.indexOf('=');
    if (i <= 0) continue;
    let k = pair.substring(0, i);
    let v = pair.substring(i + 1);
    try { k = decodeURIComponent(k.replace(/\+/g, ' ')); } catch { /* keep raw */ }
    try { v = decodeURIComponent(v.replace(/\+/g, ' ')); } catch { /* keep raw */ }
    map[k] = v;
  }
  return Object.keys(map).length === 0 ? undefined : map;
}
