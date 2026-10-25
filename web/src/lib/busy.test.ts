// 混雑の応答の読みかたの試験。
//
//   node --test src/lib/busy.test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isBusyStatus, queueTicket, reasonText, retrySeconds, slotFor } from './busy.ts';

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

test('slotFor does not wait outside the slow window', () => {
  assert.deepEqual(slotFor(1000, 500, 0), { wait: 0, nextFree: 1000 });
});

test('slotFor lines requests up one gap apart inside the slow window', () => {
  let nextFree = 0;
  const waits: number[] = [];
  for (let i = 0; i < 3; i++) {
    const s = slotFor(1000, 10_000, nextFree, 1000);
    waits.push(s.wait);
    nextFree = s.nextFree;
  }
  assert.deepEqual(waits, [0, 1000, 2000]);
  // a request that comes after the queue has drained starts at once
  assert.equal(slotFor(9000, 10_000, nextFree, 1000).wait, 0);
});

test('reasonText takes a short human line, or nothing', () => {
  assert.equal(reasonText({ reason: ' おいたはダメだよ〜 ' }), 'おいたはダメだよ〜');
  assert.equal(reasonText({ reason: '' }), null);
  assert.equal(reasonText({ reason: 5 }), null);
  assert.equal(reasonText(null), null);
});

test('queueTicket reads the ticket and the wait from a queued 503', () => {
  const body = { error: 'queued', queue: { ticket: 7, position: 3 }, retry_after_ms: 1400, retry_after: 2 };
  assert.deepEqual(queueTicket(body), { ticket: 7, waitMs: 1400 });
});

test('queueTicket keeps the wait within a sane range', () => {
  const at = (ms: number) => queueTicket({ error: 'queued', queue: { ticket: 1 }, retry_after_ms: ms })?.waitMs;
  assert.equal(at(1), 100);
  assert.equal(at(999_999), 10_000);
  assert.equal(queueTicket({ error: 'queued', queue: { ticket: 1 } })?.waitMs, 1000);
});

test('queueTicket is null for anything that is not a queued 503', () => {
  assert.equal(queueTicket(null), null);
  assert.equal(queueTicket({ error: 'plugin_busy', retry_after: 5 }), null);
  assert.equal(queueTicket({ error: 'queued', queue: { ticket: 0 } }), null);
  assert.equal(queueTicket({ error: 'queued', queue: {} }), null);
});
