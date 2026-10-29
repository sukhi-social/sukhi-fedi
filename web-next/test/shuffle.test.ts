import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spreadWithinMoments } from '../server/shuffle.ts';
import { timeWords } from '../server/time.ts';
import type { Status } from '../server/types.ts';

const now = new Date('2026-10-29T05:00:00Z'); // 韓国・日本では 14 時
const mk = (id: string, author: string, iso: string) =>
  ({ id, created_at: iso, account: { id: author }, reblog: null }) as unknown as Status;

// ぜんぶ「今日の昼下がり」(13:00〜13:50 JST)。a が四つ続いて、b と c が一つずつ。
const day = [
  mk('9', 'a', '2026-10-29T04:50:00Z'),
  mk('8', 'a', '2026-10-29T04:40:00Z'),
  mk('7', 'a', '2026-10-29T04:30:00Z'),
  mk('6', 'a', '2026-10-29T04:20:00Z'),
  mk('5', 'b', '2026-10-29T04:10:00Z'),
  mk('4', 'c', '2026-10-29T04:00:00Z')
];

test('前提: 六つとも、おなじことばで呼ばれる', () => {
  assert.equal(new Set(day.map((s) => timeWords(s.created_at, 'ja', now))).size, 1);
});

test('おなじ人が続かないように並べなおす(できるかぎり)', () => {
  const out = spreadWithinMoments(day, 'ja', 'seed', now);
  assert.equal(out.length, 6);
  assert.deepEqual(out.map((s) => s.id).sort(), day.map((s) => s.id).sort());
  // a は 4 つ、ほかは 2 つなので、離しきれない。でも、はじめの 4 つは離れている
  const authors = out.map((s) => s.account.id);
  for (let i = 1; i < 5; i++) assert.notEqual(authors[i], authors[i - 1]);
});

test('読み込みなおしても、おなじ順。札がちがえば、ちがってよい', () => {
  const a = spreadWithinMoments(day, 'ja', 'seed', now).map((s) => s.id);
  assert.deepEqual(a, spreadWithinMoments(day, 'ja', 'seed', now).map((s) => s.id));
});

test('ことばの切れ目はまたがない(昨日のものは、昨日のまま下)', () => {
  const yesterday = mk('1', 'a', '2026-10-28T04:00:00Z');
  const out = spreadWithinMoments([...day, yesterday], 'ja', 'seed', now);
  assert.equal(out[out.length - 1].id, '1');
});

test('ふたつ以下は、そのまま', () => {
  assert.deepEqual(spreadWithinMoments(day.slice(0, 2), 'ja', 's', now).map((s) => s.id), ['9', '8']);
});
