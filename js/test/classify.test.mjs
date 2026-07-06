import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classifyBody } from '../dist/esm/classify.js';

const proj = (r) => (r.projection ? JSON.parse(r.projection) : {});

test('business signal stays plaintext, never sealed', () => {
  const r = classifyBody(JSON.stringify({
    status: 'declined', decline_reason: 'insufficient_funds', amount: 42.5, quantity: 3, success: false,
  }));
  const p = proj(r);
  assert.equal(p.status, 'declined');
  assert.equal(p.decline_reason, 'insufficient_funds');
  assert.equal(p.amount, 42.5);
  assert.equal(p.quantity, 3);
  assert.equal(p.success, false);
  assert.deepEqual(r.piiMap, {});
  assert.deepEqual(r.piiPaths, []);
});

test('PII by name/value is sealed; raw goes to piiMap', () => {
  const r = classifyBody(JSON.stringify({ email: 'a@b.com', firstName: 'John', phone: '+1 415-555-1212' }));
  const p = proj(r);
  assert.equal(p.email, '[PII:email]');
  assert.equal(p.firstName, '[PII:firstname]');
  assert.equal(p.phone, '[PII:phone]');
  assert.equal(r.piiMap.email, JSON.stringify('a@b.com'));
  assert.equal(r.piiMap.firstName, JSON.stringify('John'));
  assert.ok(r.piiPaths.includes('email') && r.piiPaths.includes('phone'));
});

test('FAIL-CLOSED: no raw PII value ever appears in the projection', () => {
  const raws = ['john.doe@example.com', '415-555-1212', '123-45-6789', '192.168.1.42'];
  const r = classifyBody(JSON.stringify({
    contact: { email: 'john.doe@example.com', phone: '415-555-1212' },
    ssn: '123-45-6789',
    client_ip: '192.168.1.42',
    note: 'reach me at john.doe@example.com', // free-text with embedded email
  }));
  const s = r.projection ?? '';
  for (const raw of raws) assert.ok(!s.includes(raw), `LEAK in projection: ${raw}`);
  // sealed, not lost — recoverable from the (to-be-encrypted) piiMap
  const sealed = Object.values(r.piiMap).join('|');
  assert.ok(sealed.includes('john.doe@example.com'));
});

test('credentials are DROPPED, never sealed (unrecoverable)', () => {
  const r = classifyBody(JSON.stringify({
    password: 'hunter2',
    api_key: 'sk_live_ABCDEFGHIJ1234567890',
    card: '4111 1111 1111 1111',
  }));
  const p = proj(r);
  assert.equal(p.password, '[REDACTED-SECRET]');
  assert.match(String(p.api_key), /REDACTED/);
  const s = r.projection ?? '';
  assert.ok(!s.includes('hunter2') && !s.includes('sk_live') && !s.includes('4111'));
  assert.ok(!Object.values(r.piiMap).some((v) => v.includes('hunter2') || v.includes('sk_live')),
    'credentials must NOT be in piiMap');
});

test('seal-by-default: unknown free-text string field seals', () => {
  const r = classifyBody(JSON.stringify({ bio: 'anything at all here', status: 'ok' }));
  const p = proj(r);
  assert.equal(p.bio, '[PII]');
  assert.equal(p.status, 'ok');
  assert.ok(r.piiPaths.includes('bio'));
});

test('typed placeholders preserve leaf type (fingerprint stability)', () => {
  const r = classifyBody(JSON.stringify({ ssn: 123456789, amount: 10, active: true }));
  const p = proj(r);
  assert.equal(typeof p.ssn, 'number'); // sealed number stays number (0)
  assert.equal(p.ssn, 0);
  assert.equal(p.amount, 10);
  assert.equal(p.active, true);
});

test('nested + arrays: items inherit the parent key', () => {
  const r = classifyBody(JSON.stringify({ emails: ['a@b.com', 'c@d.com'], amounts: [1, 2] }));
  const p = proj(r);
  assert.equal(p['emails.0'], '[PII:email]');
  assert.equal(p['amounts.0'], 1);
  assert.ok(r.piiPaths.includes('emails.0') && r.piiPaths.includes('emails.1'));
});

test('empty / non-parseable body -> empty result', () => {
  assert.deepEqual(classifyBody(null), { projection: null, piiMap: {}, piiPaths: [] });
  assert.deepEqual(classifyBody('not json'), { projection: null, piiMap: {}, piiPaths: [] });
});
