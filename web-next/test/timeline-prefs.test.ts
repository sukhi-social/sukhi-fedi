// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { activeFilters, savedFilters, timelineRequest } from '../server/routes/read.ts';
import { statusCard } from '../server/views/status.ts';
import { makeT } from '../server/i18n.ts';
import type { Account, Status } from '../server/types.ts';
import type { Ctx } from '../server/http.ts';

const me = (home_filter?: string, boost_hide_name = false) =>
  ({ id: '1', acct: 'kuro', username: 'kuro', display_name: 'くろ', source: { home_filter, boost_hide_name } }) as unknown as Account;
const q = (s: string) => new URLSearchParams(s);

test('savedFilters: 知らない名前は捨てる', () => {
  assert.deepEqual([...savedFilters(me('only_media,nope,hide_boosts'))].sort(), ['hide_boosts', 'only_media']);
  assert.equal(savedFilters(me('')).size, 0);
  assert.equal(savedFilters(null).size, 0);
});

test('ホームを素で開くと、デフォルトから始まる', () => {
  assert.deepEqual([...activeFilters(me('hide_boosts'), 'home', q('kind=home'))], ['hide_boosts']);
});

test('filtered=1 のときは、フォームの値がすべて。全部外したら、何もかからない', () => {
  assert.equal(activeFilters(me('hide_boosts'), 'home', q('kind=home&filtered=1')).size, 0);
  assert.deepEqual([...activeFilters(me('hide_boosts'), 'home', q('kind=home&filtered=1&only_media=1'))], ['only_media']);
});

test('デフォルトはホームだけ。みんな・タグは、素なら絞らない', () => {
  assert.equal(activeFilters(me('only_media'), 'public', q('kind=public')).size, 0);
  assert.equal(activeFilters(me('only_media'), 'tag', q('kind=tag&tag=x')).size, 0);
});

test('hide_boosts は、ホーム以外では効かない', () => {
  assert.equal(activeFilters(me(), 'public', q('kind=public&filtered=1&hide_boosts=1')).size, 0);
});

test('timelineRequest: 新着の問い合わせと頁が同じ道・同じ絞りこみ', () => {
  const r = timelineRequest('home', '', new Set(['only_media', 'hide_boosts']));
  assert.equal(r.path, '/api/v1/timelines/home');
  assert.equal(r.query.only_media, '1');
  assert.equal(r.query.hide_boosts, '1');
  assert.equal(r.query.hide_sensitive, undefined);
  assert.equal(timelineRequest('bubble', '', new Set()).query.bubble, '1');
  assert.equal(timelineRequest('tag', 'しずか', new Set()).path, '/api/v1/timelines/tag/%E3%81%97%E3%81%9A%E3%81%8B');
});

// ── ブーストの行 ──
const acct = (n: string): Account => ({ id: n, acct: n, username: n, display_name: n, avatar: `https://x.example/${n}.png` }) as unknown as Account;
const boost = {
  id: '9', account: acct('booster'), media_attachments: [], emojis: [], created_at: '2026-10-30T00:00:00Z',
  content: '<p>一行目</p>',
  reblog: { id: '8', account: acct('author'), media_attachments: [], emojis: [], created_at: '2026-10-30T00:00:00Z', content: '<p>元の投稿</p>' }
} as unknown as Status;
const ctx = { t: makeT('ja'), locale: 'ja' } as unknown as Ctx;

test('ブーストの行: ブーストした人のアイコン → 名前 → ブーストの印 → された人のアイコン → 内容', () => {
  const out = String(statusCard(ctx, boost, { me: me() }));
  const at = (s: string) => out.indexOf(s);
  const order = ['booster.png', 'class="boost-row-who"', 'boost-row-mark', 'author.png', 'boost-compact-preview'].map(at);
  assert.ok(order.every((n) => n >= 0), String(order));
  assert.deepEqual(order, [...order].sort((a, b) => a - b));
  assert.match(out, /boosterが、authorの投稿をブースト/);
});

test('設定で、ブーストされた人の名前を隠せる(読み上げの文も、名前を出さない)', () => {
  const out = String(statusCard(ctx, boost, { me: me('', true) }));
  assert.doesNotMatch(out, /boost-row-who/);
  assert.match(out, /boosterが、ブースト/);
  assert.ok(out.includes('author.png'));
});

test('ブーストの行のなかの元の投稿は、単独の行と別の id を持つ(差し替えが混ざらない)', () => {
  const out = String(statusCard(ctx, boost, { me: me() }));
  assert.ok(out.includes(`id="bst-${boost.id}-inner"`));
  assert.ok(!out.includes(`id="st-${boost.reblog!.id}"`));
  const plain = String(statusCard(ctx, boost.reblog!, { me: me() }));
  assert.ok(plain.includes(`id="st-${boost.reblog!.id}"`));
});

test('名前の無いリモートの人は、user@host で呼ぶ', () => {
  const remote = { ...boost.reblog!, account: { ...boost.reblog!.account, display_name: '', username: 'kuro43_', acct: 'kuro43_@misskey.io' } };
  assert.match(String(statusCard(ctx, remote as Status, { me: me() })), /kuro43_@misskey\.io/);
});

const withImage = (over: Record<string, unknown>) =>
  ({
    ...boost,
    reblog: { ...boost.reblog, media_attachments: [{ id: 'm', type: 'image', url: 'https://x.example/full.png', preview_url: 'https://x.example/prev.png' }], ...over }
  }) as unknown as Status;

test('ブーストの行: 画像があれば、された人のアイコンと本文の間にプレビューが入る', () => {
  const out = String(statusCard(ctx, withImage({}), { me: me() }));
  const at = (s: string) => out.indexOf(s);
  const order = ['booster.png', 'boost-row-mark', 'author.png', 'boost-row-thumb', 'boost-compact-preview'].map(at);
  assert.ok(order.every((n) => n >= 0), String(order));
  assert.deepEqual(order, [...order].sort((a, b) => a - b));
  assert.ok(out.includes('prev.png'));
});

test('ブーストの行: 本文に CW、または画像が sensitive なら、プレビューを出さない', () => {
  assert.doesNotMatch(String(statusCard(ctx, withImage({ spoiler_text: 'ねこ' }), { me: me() })), /boost-row-thumb/);
  assert.doesNotMatch(String(statusCard(ctx, withImage({ sensitive: true }), { me: me() })), /boost-row-thumb/);
  assert.doesNotMatch(String(statusCard(ctx, boost, { me: me() })), /boost-row-thumb/);
});

test('開いたとき: 「(ブーストした人)さんがブーストしました」で、名前がプロフィールへのリンク', () => {
  const out = String(statusCard(ctx, boost, { me: me() }));
  assert.match(out, /<a class="boost-by-name" href="\/@booster">booster<\/a>さんがブーストしました/);
});
