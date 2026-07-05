import { test } from 'node:test';
import assert from 'node:assert/strict';
import { redactUrl, isSensitiveName } from '../dist/esm/redact.js';

// Swarm finding: relative URLs skipped query masking → token leaked.
test('redactUrl masks sensitive params on RELATIVE urls', () => {
  const r = redactUrl('/api/pay?token=SECRET&amount=25');
  assert.match(r, /token=(\[REDACTED\]|%5BREDACTED%5D)/);
  assert.match(r, /amount=25/);
  assert.doesNotMatch(r, /SECRET/);
  assert.ok(r.startsWith('/api/pay'), 'base not stripped: ' + r);
});

// Swarm finding: compound credential field names bypassed exact-only match.
test('compound credential field names are caught', () => {
  for (const n of ['card_cvv', 'paymentOtp', 'user_ssn', 'cvc2', 'totp_code'])
    assert.equal(isSensitiveName(n), true, n);
  // whole-word collisions still safe (pin/pass stay exact-only)
  for (const n of ['shipping', 'passenger', 'business'])
    assert.equal(isSensitiveName(n), false, n);
});

import { scrubValues, redactBody } from '../dist/esm/redact.js';
test('opaque vendor secrets under a benign key are scrubbed by value', () => {
  const b = redactBody(JSON.stringify({
    data: 'sk_live_abcdef0123456789ABCDEF',   // Stripe secret under non-sensitive key
    note: 'key is AKIAIOSFODNN7EXAMPLE here',   // AWS access key id
    gh: 'ghp_' + 'a'.repeat(36),               // GitHub token
    goog: 'AIza' + 'b'.repeat(35),             // Google API key
    orderId: 'order_12345', amount: 25,        // must SURVIVE — not secrets
  }));
  assert.doesNotMatch(b, /sk_live_abcdef/);
  assert.doesNotMatch(b, /AKIAIOSFODNN7EXAMPLE/);
  assert.doesNotMatch(b, /ghp_aaaa/);
  assert.doesNotMatch(b, /AIzabbbb/);
  assert.match(b, /REDACTED-SECRET/);
  assert.match(b, /"orderId":"order_12345"/); // benign id survives
  assert.match(b, /"amount":25/);
  // publishable keys are public by design — must NOT be nuked
  assert.equal(scrubValues('pk_live_51H8xYzPublishableKey'), 'pk_live_51H8xYzPublishableKey');
});
test('free-text PII (email/ssn/phone) scrubbed by value, any field or path', () => {
  const b = redactBody(JSON.stringify({ note: 'reach me at john.doe@x.com or 555-123-4567', ssn: 'x', field: '123-45-6789', amount: 25 }));
  assert.doesNotMatch(b, /john\.doe@x\.com/);
  assert.doesNotMatch(b, /555-123-4567/);
  assert.doesNotMatch(b, /123-45-6789/);
  assert.match(b, /REDACTED-EMAIL/);
  assert.match(b, /REDACTED-PHONE/);
  assert.match(b, /REDACTED-SSN/);
  assert.match(b, /"amount":25/); // analytics numbers survive
  // bare id-like digit runs are NOT phone-nuked (needs separators)
  assert.equal(scrubValues('order 1234567890 shipped'), 'order 1234567890 shipped');
});
