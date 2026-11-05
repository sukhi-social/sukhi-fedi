// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { delayWords, isSouthern, partOfDay, seasonOf, timeWords, validTz } from '../server/time.ts';

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

// 英語。同じ「いま」(2026-10-27 15:00 JST = 06:00 UTC)を、UTC と、東京と、ニューヨークで読む。
const en = (iso: string, tz?: string) => timeWords(iso, 'en', now, tz);

test('英語も、分・秒を言わない', () => {
  assert.equal(en('2026-10-27T05:58:00Z'), 'just now');
  assert.equal(en('2026-10-27T04:30:00Z'), 'at dawn'); // UTC では 04:30
  assert.equal(en('2026-10-27T04:30:00Z', 'Asia/Tokyo'), 'this afternoon'); // 東京では 13:30
  assert.equal(en('2026-10-26T20:00:00Z', 'UTC'), 'yesterday evening');
  assert.equal(en('2026-10-24T08:00:00Z', 'UTC'), 'the other morning');
});

test('英語: 古いものは、季節とうつろいで(a / an も)', () => {
  assert.equal(en('2026-09-20T23:30:00Z', 'UTC'), 'an autumn night');
  assert.equal(en('2026-06-20T13:30:00Z', 'UTC'), 'a summer afternoon');
  assert.equal(en('2025-12-24T20:00:00Z', 'UTC'), 'a winter evening last year');
  assert.equal(en('2023-03-24T08:00:00Z', 'UTC'), 'spring 2023');
});

test('英語: 未来(お預かり)は、あとで', () => {
  assert.equal(en('2026-10-27T06:15:00Z', 'UTC'), 'this morning');
  assert.equal(en('2026-10-28T09:00:00Z', 'UTC'), 'tomorrow morning');
});

test('読む人の tz で、日付も時間帯も変わる', () => {
  // ニューヨークは、この「いま」で 02:00。その人の前日 20:00(= 00:00 UTC)は、昨日の宵。
  assert.equal(en('2026-10-27T00:00:00Z', 'America/New_York'), 'yesterday evening');
  assert.equal(en('2026-10-27T00:00:00Z', 'UTC'), 'at dawn'.replace('at dawn', 'late tonight'));
});

test('南半球は、季節が半年ずれる', () => {
  assert.equal(isSouthern('Australia/Sydney'), true);
  assert.equal(isSouthern('Asia/Tokyo'), false);
  assert.equal(seasonOf(10, true), 'spring');
  assert.equal(seasonOf(1, true), 'summer');
  assert.equal(en('2026-09-20T23:30:00Z', 'Australia/Sydney'), 'a spring morning');
});

test('tz の cookie は、使える名前だけ受ける', () => {
  assert.equal(validTz('Asia/Tokyo'), 'Asia/Tokyo');
  assert.equal(validTz('Not/AZone'), undefined);
  assert.equal(validTz(''), undefined);
  assert.equal(validTz(undefined), undefined);
  assert.equal(validTz('x'.repeat(100)), undefined);
});

test('日本語・韓国語に tz を渡しても、作法はそのまま', () => {
  assert.equal(timeWords('2026-10-26T20:00:00+09:00', 'ja', now, 'Asia/Tokyo'), '昨日の宵');
});

test('英語の見直しの余白のことば', () => {
  assert.equal(delayWords(0, 'en'), 'right away');
  assert.equal(delayWords(15, 'en'), 'about a quarter of an hour');
  assert.equal(delayWords(60, 'en'), 'about an hour');
});
