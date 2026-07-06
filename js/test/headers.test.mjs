import { test } from 'node:test';
import assert from 'node:assert/strict';
import { IngestSink } from '../dist/esm/sink.js';

function memStorage() {
  const m = new Map();
  return {
    getItem: (k) => m.get(k) ?? null,
    setItem: (k, v) => void m.set(k, v),
    removeItem: (k) => void m.delete(k),
  };
}

function netEvent(over = {}) {
  return {
    method: 'GET',
    url: 'https://x.com/a',
    statusCode: 200,
    durationMs: 5,
    requestBodyBytes: 0,
    responseBodyBytes: 0,
    requestHeaders: { accept: 'application/json' },
    responseHeaders: { 'content-type': 'application/json' },
    requestBody: null,
    responseBody: null,
    errorText: null,
    timestampMs: Date.now(),
    ...over,
  };
}

// Deliver one event through a mock fetch and return the parsed envelope.
async function envelopeFor(ev) {
  let body = null;
  const prevFetch = globalThis.fetch;
  globalThis.fetch = async (_url, init) => {
    body = JSON.parse(init.body);
    return new Response('{"accepted":1}', { status: 202 });
  };
  try {
    const sink = new IngestSink({
      url: 'https://ingest.test/functions/v1/ingest',
      publishableKey: 'drengr_pk_test',
      context: {},
      storage: memStorage(),
    });
    sink.addNetwork(ev);
    await sink.flush();
  } finally {
    globalThis.fetch = prevFetch;
  }
  return body;
}

test('net event carries req_headers and resp_headers', async () => {
  const env = await envelopeFor(netEvent({
    requestHeaders: { accept: 'application/json', authorization: '[REDACTED]' },
    responseHeaders: { 'content-type': 'application/json', 'x-request-id': 'r1' },
  }));
  const e = env.events[0];
  assert.equal(e.kind, 'net');
  assert.deepEqual(e.req_headers, { accept: 'application/json', authorization: '[REDACTED]' });
  assert.deepEqual(e.resp_headers, { 'content-type': 'application/json', 'x-request-id': 'r1' });
});

test('header maps are capped at 48 entries', async () => {
  const many = {};
  for (let i = 0; i < 60; i++) many[`x-h-${i}`] = `v${i}`;
  const env = await envelopeFor(netEvent({ requestHeaders: many }));
  const e = env.events[0];
  assert.equal(Object.keys(e.req_headers).length, 48);
});

test('oversized serialized header map becomes {}', async () => {
  const env = await envelopeFor(netEvent({
    responseHeaders: { 'x-big': 'z'.repeat(9000) },
  }));
  const e = env.events[0];
  assert.deepEqual(e.resp_headers, {});
});

test('missing header maps become {}', async () => {
  const env = await envelopeFor(netEvent({ requestHeaders: undefined, responseHeaders: undefined }));
  const e = env.events[0];
  assert.deepEqual(e.req_headers, {});
  assert.deepEqual(e.resp_headers, {});
});
