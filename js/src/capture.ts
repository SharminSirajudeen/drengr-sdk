// Zero-code fetch/XHR capture. Fail-open: capture errors never reach the app,
// and the pre-patch fetch is preserved for the sink so delivery is invisible to capture.

import { projectBody, redactBody, redactHeaders, redactUrl } from './redact.js';

export interface NetworkEvent {
  method: string;
  url: string;
  statusCode: number | null;
  durationMs: number;
  requestBodyBytes: number;
  responseBodyBytes: number;
  requestHeaders: Record<string, string>;
  responseHeaders: Record<string, string>;
  requestBody: string | null;
  responseBody: string | null;
  errorText: string | null;
  timestampMs: number;
}

export interface CaptureOptions {
  maxBodyBytes?: number;
  captureWhen?: (url: string) => boolean;
  ignoreHosts?: Set<string>;
  redactHeaderNames?: Set<string>;
  onEvent: (e: NetworkEvent) => void;
}

type FetchFn = typeof globalThis.fetch;

const g = globalThis as Record<string, unknown> & typeof globalThis;

let installed = false;
let enabled = true;
let opts: Required<Pick<CaptureOptions, 'maxBodyBytes'>> & CaptureOptions = {
  maxBodyBytes: 64 * 1024,
  onEvent: () => {},
};
let originalFetch: FetchFn | null = null;
let originalXhrOpen: typeof XMLHttpRequest.prototype.open | null = null;
let originalXhrSend: typeof XMLHttpRequest.prototype.send | null = null;

// pre-patch fetch; the sink uses it so its own deliveries are never captured
export function nativeFetch(): FetchFn {
  return originalFetch ?? (g.fetch as FetchFn);
}

export function setEnabled(v: boolean): void {
  enabled = v;
}

export function isInstalled(): boolean {
  return installed;
}

// RN implements fetch on top of XHR; detecting it lets us avoid patching both layers
function isReactNative(): boolean {
  try {
    const nav = (g as Record<string, unknown>).navigator as { product?: string } | undefined;
    return nav?.product === 'ReactNative';
  } catch {
    return false;
  }
}

function ignored(url: string): boolean {
  try {
    if (!enabled) return true;
    if (opts.captureWhen && !opts.captureWhen(url)) return true;
    if (opts.ignoreHosts && opts.ignoreHosts.size > 0) {
      const host = new URL(url, 'http://localhost').host;
      for (const h of opts.ignoreHosts) {
        if (host === h || host.endsWith(`.${h}`)) return true;
      }
    }
    return false;
  } catch {
    return false;
  }
}

function isTextual(contentType: string | null | undefined): boolean {
  if (!contentType) return false;
  const ct = contentType.toLowerCase();
  return (
    ct.startsWith('text/') ||
    ct.includes('json') ||
    ct.includes('xml') ||
    ct.includes('x-www-form-urlencoded') ||
    ct.includes('graphql')
  );
}

function headerObj(h: Headers | undefined | null): Record<string, string> {
  const out: Record<string, string> = {};
  try {
    h?.forEach((v, k) => {
      out[k] = v;
    });
  } catch {}
  return out;
}

function cap(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) : s;
}

// hard byte cap: stop + cancel once max is exceeded so infinite/huge bodies don't buffer unbounded
async function readCapped(resp: Response, max: number): Promise<{ text: string | null; bytes: number }> {
  const body = resp.body;
  if (!body) {
    try {
      const t = await resp.text();
      return { text: t.length <= max ? t : null, bytes: t.length };
    } catch {
      return { text: null, bytes: 0 };
    }
  }
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  let over = false;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > max) { over = true; break; }
      chunks.push(value);
    }
  } catch {
    return { text: null, bytes: total };
  } finally {
    // fire-and-forget: awaiting cancel() can hang forever on a cloned body in undici
    try { void reader.cancel(); } catch {}
  }
  if (over) return { text: null, bytes: total };
  const buf = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) { buf.set(c, off); off += c.byteLength; }
  try {
    return { text: new TextDecoder().decode(buf), bytes: total };
  } catch {
    return { text: null, bytes: total };
  }
}

function emit(e: NetworkEvent): void {
  try {
    opts.onEvent(e);
  } catch {}
}

function patchFetch(): void {
  const orig = g.fetch as FetchFn | undefined;
  if (typeof orig !== 'function') return;
  originalFetch = orig.bind(globalThis) as FetchFn;

  const wrapped: FetchFn = async (input: RequestInfo | URL, init?: RequestInit) => {
    const start = Date.now();
    let url = '';
    let method = 'GET';
    let reqBodyText: string | null = null;
    let reqHeaders: Record<string, string> = {};
    try {
      if (typeof input === 'string') url = input;
      else if (input instanceof URL) url = input.toString();
      else {
        url = input.url;
        method = input.method || 'GET';
        reqHeaders = headerObj(input.headers);
      }
      if (init?.method) method = init.method;
      if (init?.headers) {
        reqHeaders = { ...reqHeaders, ...headerObj(new Headers(init.headers)) };
      }
      const b = init?.body;
      if (typeof b === 'string') reqBodyText = b;
      else if (b instanceof URLSearchParams) reqBodyText = b.toString();
    } catch {}

    const skip = ignored(url);
    try {
      const resp = await originalFetch!(input as RequestInfo, init);
      if (!skip) {
        void captureFetchResponse(resp, url, method.toUpperCase(), reqHeaders, reqBodyText, start);
      }
      return resp;
    } catch (err) {
      if (!skip) {
        emit({
          method: method.toUpperCase(),
          url: redactUrl(url),
          statusCode: null,
          durationMs: Date.now() - start,
          requestBodyBytes: reqBodyText?.length ?? 0,
          responseBodyBytes: 0,
          requestHeaders: redactHeaders(reqHeaders, opts.redactHeaderNames),
          responseHeaders: {},
          requestBody: reqBodyText ? redactBody(cap(reqBodyText, opts.maxBodyBytes)) : null,
          responseBody: null,
          errorText: String(err),
          timestampMs: start,
        });
      }
      throw err;
    }
  };

  try {
    g.fetch = wrapped;
  } catch {}
}

async function captureFetchResponse(
  resp: Response,
  url: string,
  method: string,
  reqHeaders: Record<string, string>,
  reqBodyText: string | null,
  start: number,
): Promise<void> {
  try {
    const respHeaders = headerObj(resp.headers);
    const ct = resp.headers.get('content-type');
    let respBody: string | null = null;
    let respBytes = 0;
    const lenHeader = Number(resp.headers.get('content-length'));
    if (Number.isFinite(lenHeader) && lenHeader > 0) respBytes = lenHeader;
    if (isTextual(ct)) {
      // read a CLONE with a hard cap; the app's own stream is untouched
      const capped = await readCapped(resp.clone(), opts.maxBodyBytes);
      if (capped.bytes > 0) respBytes = capped.bytes;
      respBody = capped.text;
    }
    emit({
      method,
      url: redactUrl(url),
      statusCode: resp.status,
      durationMs: Date.now() - start,
      requestBodyBytes: reqBodyText?.length ?? 0,
      responseBodyBytes: respBytes,
      requestHeaders: redactHeaders(reqHeaders, opts.redactHeaderNames),
      responseHeaders: redactHeaders(respHeaders, opts.redactHeaderNames),
      requestBody: reqBodyText ? redactBody(cap(reqBodyText, opts.maxBodyBytes)) : null,
      responseBody: respBody ? redactBody(respBody) : null,
      errorText: null,
      timestampMs: start,
    });
  } catch {}
}

interface XhrMeta {
  method: string;
  url: string;
  start: number;
  reqBody: string | null;
  reqHeaders: Record<string, string>;
}
const xhrMeta = new WeakMap<XMLHttpRequest, XhrMeta>();

function patchXhr(): void {
  const X = g.XMLHttpRequest as typeof XMLHttpRequest | undefined;
  if (typeof X !== 'function') return;
  originalXhrOpen = X.prototype.open;
  originalXhrSend = X.prototype.send;
  const origSetHeader = X.prototype.setRequestHeader;

  X.prototype.open = function (this: XMLHttpRequest, method: string, url: string | URL, ...rest: unknown[]) {
    try {
      xhrMeta.set(this, {
        method: String(method).toUpperCase(),
        url: String(url),
        start: 0,
        reqBody: null,
        reqHeaders: {},
      });
    } catch {}
    // @ts-expect-error — pass through the runtime's own signature verbatim
    return originalXhrOpen!.call(this, method, url, ...rest);
  };

  X.prototype.setRequestHeader = function (this: XMLHttpRequest, name: string, value: string) {
    try {
      const m = xhrMeta.get(this);
      if (m) m.reqHeaders[name] = value;
    } catch {}
    return origSetHeader.call(this, name, value);
  };

  X.prototype.send = function (this: XMLHttpRequest, body?: Document | XMLHttpRequestBodyInit | null) {
    const m = xhrMeta.get(this);
    if (m && !ignored(m.url)) {
      m.start = Date.now();
      if (typeof body === 'string') m.reqBody = body;
      else if (body instanceof URLSearchParams) m.reqBody = body.toString();
      this.addEventListener('loadend', () => {
        try {
          const status = this.status;
          let respBody: string | null = null;
          let respBytes = 0;
          if (this.responseType === '' || this.responseType === 'text') {
            const text = this.responseText ?? '';
            respBytes = text.length;
            if (
              text.length > 0 &&
              text.length <= opts.maxBodyBytes &&
              isTextual(this.getResponseHeader('content-type'))
            ) {
              respBody = text;
            }
          }
          const respHeaders: Record<string, string> = {};
          for (const line of (this.getAllResponseHeaders() || '').split('\r\n')) {
            const i = line.indexOf(': ');
            if (i > 0) respHeaders[line.slice(0, i)] = line.slice(i + 2);
          }
          emit({
            method: m.method,
            url: redactUrl(m.url),
            statusCode: status === 0 ? null : status,
            durationMs: Date.now() - m.start,
            requestBodyBytes: m.reqBody?.length ?? 0,
            responseBodyBytes: respBytes,
            requestHeaders: redactHeaders(m.reqHeaders, opts.redactHeaderNames),
            responseHeaders: redactHeaders(respHeaders, opts.redactHeaderNames),
            requestBody: m.reqBody ? redactBody(cap(m.reqBody, opts.maxBodyBytes)) : null,
            responseBody: respBody ? redactBody(respBody) : null,
            errorText: status === 0 ? 'network_error' : null,
            timestampMs: m.start,
          });
        } catch {}
      });
    }
    return originalXhrSend!.call(this, body as never);
  };
}

export function install(options: CaptureOptions): void {
  if (installed) return;
  // coerce so an explicit maxBodyBytes:undefined can't clobber the default
  opts = { ...options, maxBodyBytes: options.maxBodyBytes ?? 64 * 1024 };
  // on RN fetch is XHR-backed; patch only XHR to avoid double-capture + sink recursion
  if (!isReactNative()) patchFetch();
  patchXhr();
  installed = true;
}

export function uninstall(): void {
  if (!installed) return;
  try {
    if (originalFetch) g.fetch = originalFetch;
    const X = g.XMLHttpRequest as typeof XMLHttpRequest | undefined;
    if (X && originalXhrOpen) X.prototype.open = originalXhrOpen;
    if (X && originalXhrSend) X.prototype.send = originalXhrSend;
  } catch {}
  installed = false;
}

export { projectBody };
