// 会話の面で本文を書き換えるところの試験。
//
//   node --test src/lib/preview.test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { previewOf, stripLeadingMentionHtml } from './preview.ts';

// sukhi が返す実際の形。言及は h-card の span に包まれる。
const CARD = (acct: string) =>
  `<span class="h-card"><a href="https://sukhi.f3liz.casa/@${acct}">@<span>${acct}</span></a></span>`;

test('あたまの h-card 言及を落とす', () => {
  const html = `<p>${CARD('shiro_mudita')} こんにちは</p>`;
  assert.equal(stripLeadingMentionHtml(html), '<p>こんにちは</p>');
});

test('あたまに二人ぶん並んでいても落とす', () => {
  const html = `<p>${CARD('a')} ${CARD('b')} やあ</p>`;
  assert.equal(stripLeadingMentionHtml(html), '<p>やあ</p>');
});

test('h-card に包まれていない素の @ でも落とす', () => {
  assert.equal(stripLeadingMentionHtml('<p>@alice やあ</p>'), '<p>やあ</p>');
});

test('文中の言及は残す — 落とすのは、あたまだけ', () => {
  const html = `<p>これは ${CARD('someone')} のこと</p>`;
  assert.equal(stripLeadingMentionHtml(html), html);
});

test('言及で始まらない本文は、そのまま', () => {
  assert.equal(stripLeadingMentionHtml('<p>ただの文</p>'), '<p>ただの文</p>');
});

test('二段落目の頭は触らない', () => {
  const html = `<p>${CARD('a')} 一段目</p><p>@b 二段目</p>`;
  assert.equal(stripLeadingMentionHtml(html), '<p>一段目</p><p>@b 二段目</p>');
});

test('空でも転ばない', () => {
  assert.equal(stripLeadingMentionHtml(null), '');
  assert.equal(stripLeadingMentionHtml(''), '');
});

test('一覧のひとことは、タグを落として言及も外す', () => {
  assert.equal(previewOf(`<p>${CARD('shiro_mudita')} はへー</p>`), 'はへー');
});

test('一覧のひとことは、長ければ畳む', () => {
  const long = '<p>' + 'あ'.repeat(200) + '</p>';
  const out = previewOf(long, 20);
  assert.equal(out.length, 21);
  assert.ok(out.endsWith('…'));
});

// ── 末尾に回した宛名 ─────────────────────────────────────────────────
// composer は DM の宛先を末尾へ回す。受け取る側では配達の宛名なので出さない。

test('末尾の「言及だけの段落」は落とす', () => {
  const html = `<p>こんにちは</p><p>${CARD('nyanrus')}</p>`;
  assert.equal(stripLeadingMentionHtml(html), '<p>こんにちは</p>');
});

test('末尾に文が混じっていれば、落とさない', () => {
  const html = `<p>やあ</p><p>${CARD('nyanrus')} これは本文</p>`;
  assert.equal(stripLeadingMentionHtml(html), html);
});

test('末尾が素の @ だけでも落とす', () => {
  assert.equal(stripLeadingMentionHtml('<p>やあ</p><p>@nyanrus</p>'), '<p>やあ</p>');
});

test('宛名だけの一通は、空にならず段落が残る', () => {
  // 本文が無く宛名だけ ── 落としたら何も残らないので、先頭側の規則に任せる。
  const out = stripLeadingMentionHtml(`<p>${CARD('nyanrus')}</p>`);
  assert.equal(out, '<p></p>');
});
