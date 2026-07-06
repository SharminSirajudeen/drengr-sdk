import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { SDK_VERSION } from '../dist/esm/version.js';
import { SDK_VERSION as fromIndex } from '../dist/esm/index.js';

test('SDK_VERSION matches package.json version', () => {
  const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(SDK_VERSION, pkg.version);
  assert.equal(fromIndex, pkg.version);
});

test('src/version.ts is the committed generated file', () => {
  const src = readFileSync(new URL('../src/version.ts', import.meta.url), 'utf8');
  const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  assert.ok(src.includes(`export const SDK_VERSION = '${pkg.version}';`));
});
