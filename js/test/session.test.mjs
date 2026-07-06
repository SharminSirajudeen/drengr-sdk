import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import { SessionManager, SESSION_IDLE_MS, SESSION_MAX_MS } from '../dist/esm/session.js';

const SESSION_KEY = 'drengr_session_v1';

function memStorage() {
  const m = new Map();
  return {
    getItem: (k) => m.get(k) ?? null,
    setItem: (k, v) => void m.set(k, v),
    removeItem: (k) => void m.delete(k),
    map: m,
  };
}

const microtask = () => new Promise((r) => queueMicrotask(r));

test('constants match the cross-SDK spec', () => {
  assert.equal(SESSION_IDLE_MS, 1800000);
  assert.equal(SESSION_MAX_MS, 86400000);
});

test('restore reuses a fresh persisted session', async () => {
  const storage = memStorage();
  const now = Date.now();
  storage.map.set(SESSION_KEY, JSON.stringify({
    session_id: 's-persisted', started_at: now - 60_000, last_activity_at: now - 60_000,
  }));
  let adopted = null;
  const sm = new SessionManager(storage, () => {}, (id) => { adopted = id; });
  await sm.restore();
  assert.equal(sm.currentId(), 's-persisted');
  assert.equal(adopted, 's-persisted');
});

test('restore mints new when the persisted session is idle-stale', async () => {
  const storage = memStorage();
  const now = Date.now();
  storage.map.set(SESSION_KEY, JSON.stringify({
    session_id: 's-old', started_at: now - SESSION_IDLE_MS - 120_000, last_activity_at: now - SESSION_IDLE_MS - 1000,
  }));
  const sm = new SessionManager(storage, () => {}, () => {});
  await sm.restore();
  assert.notEqual(sm.currentId(), 's-old');
});

test('touch after idle gap flushes old queue then rotates', async () => {
  mock.timers.enable({ apis: ['Date'] });
  try {
    const storage = memStorage();
    const flushed = [];
    let current = null;
    const sm = new SessionManager(storage, () => flushed.push(current ?? sm.currentId()), (id) => { current = id; });
    const first = sm.currentId();
    current = first;
    sm.touch();
    assert.equal(sm.currentId(), first, 'no rotation while active');

    mock.timers.tick(SESSION_IDLE_MS + 1000);
    sm.touch();
    assert.notEqual(sm.currentId(), first, 'idle gap must mint a new session');
    assert.deepEqual(flushed, [first], 'old session flushed exactly once, before the id changed');

    await microtask();
    const persisted = JSON.parse(storage.map.get(SESSION_KEY));
    assert.equal(persisted.session_id, sm.currentId());
    assert.equal(typeof persisted.last_activity_at, 'number');
  } finally {
    mock.timers.reset();
  }
});

test('continuous activity past SESSION_MAX_MS still rotates', () => {
  mock.timers.enable({ apis: ['Date'] });
  try {
    const sm = new SessionManager(memStorage(), () => {}, () => {});
    const first = sm.currentId();
    const step = 10 * 60_000; // touches every 10 min — never idle
    for (let t = 0; t <= SESSION_MAX_MS; t += step) {
      mock.timers.tick(step);
      sm.touch();
    }
    assert.notEqual(sm.currentId(), first, 'max age must force rotation despite activity');
  } finally {
    mock.timers.reset();
  }
});

test('foreground after idle gap rotates; background bumps activity', () => {
  mock.timers.enable({ apis: ['Date'] });
  try {
    const sm = new SessionManager(memStorage(), () => {}, () => {});
    const first = sm.currentId();

    mock.timers.tick(SESSION_IDLE_MS - 60_000);
    sm.background(); // activity recorded at hide
    mock.timers.tick(SESSION_IDLE_MS - 60_000);
    sm.foreground(); // gap since hide < idle → keep
    assert.equal(sm.currentId(), first);

    mock.timers.tick(SESSION_IDLE_MS + 1000);
    sm.foreground(); // gap > idle → rotate
    assert.notEqual(sm.currentId(), first);
  } finally {
    mock.timers.reset();
  }
});

test('corrupt persisted record is ignored fail-open', async () => {
  const storage = memStorage();
  storage.map.set(SESSION_KEY, '{not json');
  const sm = new SessionManager(storage, () => {}, () => {});
  await sm.restore();
  assert.ok(sm.currentId().startsWith('s-'));
});
