import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as capture from '../dist/esm/capture.js';
import { Drengr } from '../dist/esm/index.js';

// Swarm finding: on React Native, fetch is XHR-backed. Patching both layers
// double-captured every request and let the sink's deliveries recurse.

test('React Native: fetch is NOT patched (XHR-only)', () => {
  const before = globalThis.navigator;
  const prevXHR = globalThis.XMLHttpRequest;
  Object.defineProperty(globalThis, 'navigator', { value: { product: 'ReactNative' }, configurable: true });
  class FakeXHR {
    open() {}
    send() {}
    setRequestHeader() {}
    addEventListener() {}
    getAllResponseHeaders() { return ''; }
    getResponseHeader() { return null; }
  }
  globalThis.XMLHttpRequest = FakeXHR;
  const fetchBefore = (globalThis.fetch = async () => new Response('{}'));
  const sendBefore = FakeXHR.prototype.send;
  try {
    capture.install({ onEvent: () => {} });
    assert.equal(globalThis.fetch, fetchBefore, 'fetch must NOT be wrapped on RN (avoids double-capture)');
    assert.notEqual(FakeXHR.prototype.send, sendBefore, 'XHR.send MUST be wrapped on RN');
  } finally {
    capture.uninstall();
    globalThis.XMLHttpRequest = prevXHR;
    Object.defineProperty(globalThis, 'navigator', { value: before, configurable: true });
  }
});

// Self-capture guard (all runtimes): the ingest host is auto-excluded so the sink's
// own deliveries are never captured — the load-bearing fix for the RN XHR sink path.
test('ingest host is auto-ignored (no self-capture)', async () => {
  let capturedIngest = 0;
  let capturedOther = 0;
  globalThis.fetch = async () => new Response('{}', { headers: { 'content-type': 'application/json' } });
  Drengr.start({
    ingestUrl: 'https://ingest.example.com/functions/v1/ingest',
    publishableKey: 'drengr_pk_x',
    appPackage: 'com.x',
    onEvent: (e) => {
      if (e.url.includes('ingest.example.com')) capturedIngest++;
      else capturedOther++;
    },
  });
  await globalThis.fetch('https://ingest.example.com/functions/v1/ingest');
  await globalThis.fetch('https://api.other.com/thing');
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(capturedIngest, 0, 'requests to the ingest host must not be captured');
  assert.ok(capturedOther >= 1, 'requests to other hosts are still captured');
  Drengr.stop();
});
