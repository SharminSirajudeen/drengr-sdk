import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as capture from '../dist/esm/capture.js';

async function captureOne(fetchImpl, maxBodyBytes) {
  globalThis.fetch = fetchImpl;
  let ev = null;
  capture.install({ maxBodyBytes, onEvent: (e) => { ev = e; } });
  try {
    await globalThis.fetch('https://x.com/probe');
    await new Promise((r) => setTimeout(r, 250));
    return ev;
  } finally {
    capture.uninstall();
  }
}

test('over-cap finite body still emits, size-only', async () => {
  const ev = await captureOne(
    async () => new Response('x'.repeat(50000), { headers: { 'content-type': 'text/plain' } }),
    1000,
  );
  assert.ok(ev, 'event must be emitted even when body exceeds cap');
  assert.equal(ev.responseBody, null, 'over-cap body must be size-only (null)');
  assert.ok(ev.responseBodyBytes >= 1000, 'byte count recorded');
});

test('infinite SSE stream is bounded and emitted (no hang)', async () => {
  let pulls = 0;
  const stream = new ReadableStream({
    pull(controller) {
      pulls++;
      controller.enqueue(new TextEncoder().encode('data: ' + 'y'.repeat(500) + '\n\n'));
    },
  });
  const ev = await captureOne(
    async () => new Response(stream, { headers: { 'content-type': 'text/event-stream' } }),
    1000,
  );
  assert.ok(ev, 'event must be emitted for a streaming body');
  assert.equal(ev.responseBody, null, 'streamed body must be size-only');
  assert.ok(pulls < 100, `stream must be bounded, not drained forever (pulls=${pulls})`);
});

test('under-cap body is captured with redaction applied', async () => {
  const ev = await captureOne(
    async () => new Response(JSON.stringify({ secret: 'abc', n: 5 }), { headers: { 'content-type': 'application/json' } }),
    64 * 1024,
  );
  assert.ok(ev);
  assert.match(ev.responseBody, /\[REDACTED\]/);
  assert.doesNotMatch(ev.responseBody, /abc/);
});
