// 混雑の応答の読みかたの試験。
//
//   node --test src/lib/busy.test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isBusyStatus, retrySeconds } from './busy.ts';

test('retrySeconds prefers the header, then the body, then a default', () => {
  assert.equal(retrySeconds('30', { retry_after: 5 }), 30);
  assert.equal(retrySeconds(null, { retry_after: 7 }), 7);
  assert.equal(retrySeconds(null, {}), 5);
  assert.equal(retrySeconds('soon', null), 5);
});

test('retrySeconds keeps the wait within a sane range', () => {
  assert.equal(retrySeconds('0', {}), 5);
  assert.equal(retrySeconds('99999', {}), 300);
  assert.equal(retrySeconds('1.2', {}), 2);
});

test('isBusyStatus is 429 and 503 only', () => {
  assert.ok([429, 503].every(isBusyStatus));
  assert.ok(![200, 401, 404, 500].some(isBusyStatus));
});
