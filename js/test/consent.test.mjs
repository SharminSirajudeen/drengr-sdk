import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Drengr } from '../dist/esm/index.js';

// Swarm finding (GDPR): setEnabled(false) was runtime-only, so an opted-out user
// was re-captured on the next launch. optOut() must PERSIST and start() must honor
// the persisted flag on a fresh session.
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

  // Session 1: start, then opt out.
  Drengr.start({
    ingestUrl: 'https://x/ingest', publishableKey: 'drengr_pk_x',
    appPackage: 'com.x', storage, onEvent: () => { captured++; },
  });
  Drengr.optOut();
  await new Promise((r) => setTimeout(r, 20));
  Drengr.stop();
  assert.equal(mem.get('drengr_opt_out'), '1', 'opt-out flag persisted to storage');

  // Session 2: fresh start with the SAME storage — must stay paused.
  captured = 0;
  Drengr.start({
    ingestUrl: 'https://x/ingest', publishableKey: 'drengr_pk_x',
    appPackage: 'com.x', storage, onEvent: () => { captured++; },
  });
  await globalThis.fetch('https://api.example.com/a');
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(captured, 0, 'opted-out install must not capture after restart');

  // optIn clears the flag and resumes.
  Drengr.optIn();
  await globalThis.fetch('https://api.example.com/b');
  await new Promise((r) => setTimeout(r, 50));
  assert.ok(captured >= 1, 'optIn resumes capture');
  assert.equal(mem.get('drengr_opt_out'), undefined, 'optIn cleared the persisted flag');
  Drengr.stop();
});
