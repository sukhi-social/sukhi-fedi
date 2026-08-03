// 「いま打っている @語 はどれか」と「選んだらどう差し替わるか」の試験。
// ここは書き手の文を書き換える場所なので、境目を確かめておく。
//
// この repo に unit の走者は無いので、Node 組み込みのもので走らせる
// (依存を足さない。Node 24 は .ts をそのまま読める):
//
//   node --test src/lib/mention.test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { applyPick, fragmentAt } from './mention.ts';

test('行頭の @ を拾う', () => {
  assert.deepEqual(fragmentAt('@ali', 4), { start: 0, end: 4, query: 'ali' });
});

test('空白のあとの @ を拾う', () => {
  assert.deepEqual(fragmentAt('こんにちは @ali', 10), { start: 6, end: 10, query: 'ali' });
});

test('@ だけでも fragment ではある(候補を出さないのは呼ぶ側の判断)', () => {
  assert.deepEqual(fragmentAt('@', 1), { start: 0, end: 1, query: '' });
});

test('よそのサーバつきも、一語として拾う', () => {
  assert.equal(fragmentAt('@ali@mastodon.so', 16)?.query, 'ali@mastodon.so');
});

test('メールアドレスは拾わない — 前が文字なので', () => {
  assert.equal(fragmentAt('mail is ali@example', 19), null);
});

test('打ち終わって空白を打ったら、もう拾わない', () => {
  assert.equal(fragmentAt('@alice ', 7), null);
});

test('カーソルより後ろは見ない', () => {
  // 「@ali|ce」── カーソルまでが、いまの語。
  assert.equal(fragmentAt('@alice', 4)?.query, 'ali');
});

test('文中の、打ち終わった言及は触らない', () => {
  assert.equal(fragmentAt('@alice さん、こんにちは。', 15), null);
});

test('全角の括弧のあとも拾う', () => {
  assert.equal(fragmentAt('（@ali', 5)?.query, 'ali');
});

test('選んだ相手で置き換えて、空白を足す', () => {
  const f = fragmentAt('@ali', 4);
  assert.ok(f);
  assert.deepEqual(applyPick('@ali', f, 'alice'), { text: '@alice ', caret: 7 });
});

test('後ろに続きがあっても壊さない', () => {
  const text = 'こんにちは @ali さん';
  const f = fragmentAt(text, 10);
  assert.ok(f);
  assert.deepEqual(applyPick(text, f, 'alice'), { text: 'こんにちは @alice  さん', caret: 13 });
});

test('置き換えたあとは、もう fragment ではない(空白で切れる)', () => {
  const f = fragmentAt('@ali', 4);
  assert.ok(f);
  const r = applyPick('@ali', f, 'alice');
  assert.equal(fragmentAt(r.text, r.caret), null);
});
