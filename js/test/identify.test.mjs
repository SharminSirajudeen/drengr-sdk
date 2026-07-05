import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Drengr } from '../dist/esm/index.js';

function mockFetch(calls) {
  return async (url, init) => {
    calls.push({ url: String(url), body: init?.body ? JSON.parse(init.body) : null });
    return new Response('{}', { headers: { 'content-type': 'application/json' } });
  };
}

function ingestEnvelopes(calls) {
  return calls.filter((c) => c.url.includes('ingest.example.com')).map((c) => c.body);
}

test('identify() sets external_id on the envelope and emits one identify event; traits redacted', async () => {
  const calls = [];
  globalThis.fetch = mockFetch(calls);
  Drengr.start({
    ingestUrl: 'https://ingest.example.com/functions/v1/ingest',
    publishableKey: 'drengr_pk_x',
    appPackage: 'com.x',
  });

  Drengr.identify('user_123', { email: 'a@b.com', plan: 'pro' });
  await globalThis.fetch('https://api.other.com/thing');
  await new Promise((r) => setTimeout(r, 20));
  await Drengr.flush();
  await new Promise((r) => setTimeout(r, 20));

  const envelopes = ingestEnvelopes(calls);
  assert.ok(envelopes.length >= 1, 'ingest received at least one envelope');
  const envelope = envelopes[envelopes.length - 1];
  assert.equal(envelope.external_id, 'user_123', 'external_id attached at envelope level');

  const identifyEv = envelope.events.find((e) => e.kind === 'identify');
  assert.ok(identifyEv, 'an identify event was emitted');
  assert.equal(identifyEv.external_id, 'user_123');
  assert.ok(!JSON.stringify(identifyEv).includes('a@b.com'), 'raw email must not appear');
  assert.ok(JSON.stringify(identifyEv).includes('pro'), 'non-PII trait survives redaction');

  const netEv = envelope.events.find((e) => e.kind === 'net');
  assert.ok(netEv, 'the subsequent normal event was captured in the same envelope');

  Drengr.stop();
});

test('identify() with empty externalId is a no-op (never throws)', async () => {
  const calls = [];
  globalThis.fetch = mockFetch(calls);
  Drengr.start({
    ingestUrl: 'https://ingest.example.com/functions/v1/ingest',
    publishableKey: 'drengr_pk_y',
    appPackage: 'com.y',
  });

  assert.doesNotThrow(() => Drengr.identify('', { email: 'a@b.com' }));
  assert.doesNotThrow(() => Drengr.identify(undefined));
  await Drengr.flush();
  await new Promise((r) => setTimeout(r, 20));

  const envelopes = ingestEnvelopes(calls);
  for (const e of envelopes) {
    assert.equal(e.external_id, undefined, 'external_id must stay unset');
    assert.ok(!(e.events ?? []).some((ev) => ev.kind === 'identify'), 'no identify event emitted');
  }

  Drengr.stop();
});

test('setExperiment() attaches experiments to the envelope; null clears; bad input is a no-op', async () => {
  const calls = [];
  globalThis.fetch = mockFetch(calls);
  Drengr.start({
    ingestUrl: 'https://ingest.example.com/functions/v1/ingest',
    publishableKey: 'drengr_pk_z',
    appPackage: 'com.z',
  });

  Drengr.setExperiment('checkout_flow', 'variant_b');
  await globalThis.fetch('https://api.other.com/a');
  await new Promise((r) => setTimeout(r, 20));
  await Drengr.flush();
  await new Promise((r) => setTimeout(r, 20));

  let envelope = ingestEnvelopes(calls).at(-1);
  assert.deepEqual(envelope.experiments, { checkout_flow: 'variant_b' });

  assert.doesNotThrow(() => Drengr.setExperiment('', 'x'));
  assert.doesNotThrow(() => Drengr.setExperiment(123, 'x'));

  Drengr.setExperiment('checkout_flow', null);
  await globalThis.fetch('https://api.other.com/b');
  await new Promise((r) => setTimeout(r, 20));
  await Drengr.flush();
  await new Promise((r) => setTimeout(r, 20));

  envelope = ingestEnvelopes(calls).at(-1);
  assert.equal(envelope.experiments, undefined, 'experiments omitted once empty');

  Drengr.stop();
});
