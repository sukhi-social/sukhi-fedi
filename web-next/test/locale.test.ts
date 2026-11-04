// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { detectLocale, legalLang, makeT, LOCALES } from '../server/i18n.ts';
import { ja } from '../server/locales/ja.ts';
import { ko } from '../server/locales/ko.ts';
import { en } from '../server/locales/en.ts';
import { jaExtra, koExtra, enExtra } from '../server/locales/extra.ts';

// {n} {acct} のような差し込み口は、言語がちがっても同じものが並ぶ(欠けると、画面に {n} が出る)。
const slots = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(',');

test('どの言語の辞書も、差し込み口が日本語と同じ', () => {
  const pairs: Array<[string, Record<string, string>, Record<string, string>]> = [
    ['ko', ja, ko],
    ['en', ja, en],
    ['ko extra', jaExtra, koExtra],
    ['en extra', jaExtra, enExtra]
  ];
  for (const [name, base, other] of pairs) {
    for (const key of Object.keys(base)) {
      assert.equal(slots(other[key] ?? ''), slots(base[key]), `${name}: ${key}`);
      if (base[key].length > 0) assert.ok((other[key] ?? '').length > 0, `${name}: ${key} が空`);
    }
  }
});

test('どの言語も、日本語と同じ鍵を、過不足なく持つ', () => {
  const keys = (o: object) => Object.keys(o).sort().join('\n');
  assert.equal(keys(ko), keys(ja));
  assert.equal(keys(en), keys(ja));
  assert.equal(keys(koExtra), keys(jaExtra));
  assert.equal(keys(enExtra), keys(jaExtra));
});

test('英語の辞書に、日本語・韓国語の文字が残っていない', () => {
  const cjk = /[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]/;
  for (const [k, v] of [...Object.entries(en), ...Object.entries(enExtra)]) {
    assert.ok(!cjk.test(v), `en: ${k} に CJK が混ざっている: ${v}`);
  }
});

test('makeT は、en で英語を返し、差し込む', () => {
  assert.equal(LOCALES.includes('en'), true);
  const t = makeT('en');
  assert.equal(t('common.acctNotFound', { acct: 'a@b' }), 'We couldn’t find @a@b.');
  assert.equal(t('end.here'), 'That’s all, for now.');
});

test('端末で選んだものが先', () => {
  assert.equal(detectLocale('ko', 'ja', 'ja'), 'ko');
});

test('アカウントの言語を、ブラウザより先に使う', () => {
  assert.equal(detectLocale(undefined, 'ko', 'ja-JP,ja;q=0.9'), 'ko');
  assert.equal(detectLocale(undefined, 'ko_KR', 'ja'), 'ko');
});

test('アカウントが null のときは、ブラウザの言語で決める', () => {
  assert.equal(detectLocale(undefined, null, 'ko-KR,ko;q=0.9,en;q=0.8'), 'ko');
  assert.equal(detectLocale(undefined, undefined, 'ja'), 'ja');
});

test('英語も選べる。アカウントの言語・ブラウザの言語どちらでも', () => {
  assert.equal(detectLocale(undefined, 'en', 'ja'), 'en');
  assert.equal(detectLocale(undefined, null, 'en-GB,en;q=0.9'), 'en');
  assert.equal(detectLocale('en', 'ja', 'ja'), 'en');
});

test('ブラウザは並びの最初に合うもの(en が先なら en)', () => {
  assert.equal(detectLocale(undefined, null, 'en-US,en;q=0.9,ko;q=0.8'), 'en');
  assert.equal(detectLocale(undefined, null, 'fr,ja;q=0.8'), 'ja');
});

test('持っていない言語だけなら en(日本語より読める)。印が何も無ければ ja', () => {
  assert.equal(detectLocale(undefined, null, 'fr,de'), 'en');
  assert.equal(detectLocale(undefined, null, '*'), 'ja');
  assert.equal(detectLocale(undefined, null, undefined), 'ja');
  assert.equal(detectLocale(undefined, null, ''), 'ja');
});

test('規約の頁は、ko 以外には lang を足さない(英語版は、まだ無い)', () => {
  assert.equal(legalLang('ko'), 'ko');
  assert.equal(legalLang('en'), null);
  assert.equal(legalLang('ja'), null);
});
