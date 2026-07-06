import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as capture from '../dist/esm/capture.js';

// requestBodyBytes must be accurate-or-absent, never a silent 0.

async function captureReq(body) {
  globalThis.fetch = async () => new Response('{}', { headers: { 'content-type': 'application/json' } });
  let ev = null;
  capture.install({ onEvent: (e) => { ev = e; } });
  try {
    await globalThis.fetch('https://x.com/p', { method: 'POST', body });
    await new Promise((r) => setTimeout(r, 100));
    return ev;
  } finally {
    capture.uninstall();
  }
}

test('string body: length recorded (regression)', async () => {
  const ev = await captureReq('hello=world');
  assert.equal(ev.requestBodyBytes, 11);
});

test('FormData: sum of string part lengths + Blob sizes', async () => {
  const fd = new FormData();
  fd.append('name', 'abc'); // 3
  fd.append('file', new Blob([new Uint8Array(10)])); // 10
  const ev = await captureReq(fd);
  assert.equal(ev.requestBodyBytes, 13);
  assert.equal(ev.requestBody, null, 'FormData is never read as text');
});

test('Blob body: .size', async () => {
  const ev = await captureReq(new Blob(['1234567']));
  assert.equal(ev.requestBodyBytes, 7);
});

test('ArrayBuffer body: .byteLength', async () => {
  const ev = await captureReq(new ArrayBuffer(16));
  assert.equal(ev.requestBodyBytes, 16);
});

test('TypedArray body: .byteLength', async () => {
  const ev = await captureReq(new Uint8Array(5));
  assert.equal(ev.requestBodyBytes, 5);
});

test('URLSearchParams: form-encoded text through redaction', async () => {
  const usp = new URLSearchParams({ password: 'hunter2', x: '1' });
  const ev = await captureReq(usp);
  assert.equal(ev.requestBodyBytes, usp.toString().length);
  assert.match(ev.requestBody, /\[REDACTED\]/);
  assert.doesNotMatch(ev.requestBody, /hunter2/);
});

test('ReadableStream body: size unknown → undefined, stream untouched', async () => {
  let pulls = 0;
  const stream = new ReadableStream({
    pull(controller) {
      pulls++;
      controller.enqueue(new TextEncoder().encode('x'));
    },
  });
  const ev = await captureReq(stream);
  assert.equal(ev.requestBodyBytes, undefined, 'unknown size must be undefined, never 0');
  assert.equal(stream.locked, false, 'capture must never take a reader on the stream');
  assert.ok(pulls <= 1, `only the HWM prefill pull is allowed (pulls=${pulls})`);
});

test('undefined-size req_bytes is absent on the wire, not 0', async () => {
  const { IngestSink } = await import('../dist/esm/sink.js');
  let body = null;
  const prevFetch = globalThis.fetch;
  globalThis.fetch = async (_u, init) => {
    body = JSON.parse(init.body);
    return new Response('{}', { status: 202 });
  };
  // install() snapshots the mock as the pre-patch fetch the sink delivers with
  // (earlier installs in this process left a stale snapshot behind).
  capture.install({ onEvent: () => {} });
  try {
    const mem = new Map();
    const sink = new IngestSink({
      url: 'https://ingest.test/fn',
      publishableKey: 'drengr_pk_t',
      context: {},
      storage: { getItem: (k) => mem.get(k) ?? null, setItem: (k, v) => void mem.set(k, v), removeItem: (k) => void mem.delete(k) },
    });
    sink.addNetwork({
      method: 'POST', url: 'https://x.com/s', statusCode: 200, durationMs: 1,
      requestBodyBytes: undefined, responseBodyBytes: undefined,
      requestHeaders: {}, responseHeaders: {}, requestBody: null, responseBody: null,
      errorText: null, timestampMs: Date.now(),
    });
    await sink.flush();
  } finally {
    capture.uninstall();
    globalThis.fetch = prevFetch;
  }
  assert.ok(!('req_bytes' in body.events[0]), 'undefined req_bytes must be absent');
  assert.ok(!('resp_bytes' in body.events[0]), 'undefined resp_bytes must be absent');
});
