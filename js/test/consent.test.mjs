import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Drengr } from '../dist/esm/index.js';

test('optOut persists across restart; optIn resumes', async () => {
  const mem = new Map();
  const storage = {
    getItem: (k) => mem.get(k) ?? null,
    setItem: (k, v) => void mem.set(k, v),
    removeItem: (k) => void mem.delete(k),
  };
  let captured = 0;
  globalThis.fetch = async () =>
    new Response('{}', { headers: { 'content-type': 'application/json' } });

  Drengr.start({
    ingestUrl: 'https://x/ingest', publishableKey: 'drengr_pk_x',
    appPackage: 'com.x', storage, onEvent: () => { captured++; },
  });
  Drengr.optOut();
  await new Promise((r) => setTimeout(r, 20));
  Drengr.stop();
  assert.equal(mem.get('drengr_opt_out'), '1', 'opt-out flag persisted to storage');

  captured = 0;
  Drengr.start({
    ingestUrl: 'https://x/ingest', publishableKey: 'drengr_pk_x',
    appPackage: 'com.x', storage, onEvent: () => { captured++; },
  });
  await globalThis.fetch('https://api.example.com/a');
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(captured, 0, 'opted-out install must not capture after restart');

  Drengr.optIn();
  await globalThis.fetch('https://api.example.com/b');
  await new Promise((r) => setTimeout(r, 50));
  assert.ok(captured >= 1, 'optIn resumes capture');
  assert.equal(mem.get('drengr_opt_out'), undefined, 'optIn cleared the persisted flag');
  Drengr.stop();
});
