import { test } from 'node:test';
import assert from 'node:assert/strict';
import { delayWords, partOfDay, seasonOf, timeWords } from '../server/time.ts';

// 2026-10-27 15:00 JST を「いま」にする。
const now = new Date('2026-10-27T15:00:00+09:00');
const at = (iso: string) => timeWords(iso, 'ja', now);

test('一日のうつろい', () => {
  assert.equal(partOfDay(3), 'late');
  assert.equal(partOfDay(8), 'morning');
  assert.equal(partOfDay(14), 'afternoon');
  assert.equal(partOfDay(20), 'evening');
});

test('季節', () => {
  assert.equal(seasonOf(10), 'autumn');
  assert.equal(seasonOf(1), 'winter');
});

test('分・秒を言わない', () => {
  assert.equal(at('2026-10-27T14:58:00+09:00'), 'いま');
  assert.equal(at('2026-10-27T13:30:00+09:00'), '今日の昼下がり');
  assert.equal(at('2026-10-26T20:00:00+09:00'), '昨日の宵');
  assert.equal(at('2026-10-24T08:00:00+09:00'), 'このあいだの朝');
});

test('古いものは、季節とうつろいで', () => {
  assert.equal(at('2026-09-20T23:30:00+09:00'), '秋の夜ふけ');
  assert.equal(at('2025-12-24T20:00:00+09:00'), '去年の冬の宵');
});

test('未来(お預かり)は、あとで', () => {
  assert.equal(at('2026-10-27T15:15:00+09:00'), '今日の昼下がり');
  assert.equal(at('2026-10-28T09:00:00+09:00'), 'あしたの朝');
});

test('韓国語も、同じ作法で', () => {
  assert.equal(timeWords('2026-10-26T20:00:00+09:00', 'ko', now), '어제 저녁');
});

test('見直しの余白のことば', () => {
  assert.equal(delayWords(15, 'ja'), '約四半刻');
  assert.equal(delayWords(0, 'ja'), 'すぐ');
});
