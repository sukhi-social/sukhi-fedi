// 鍵の詰め替えと alerts の組み立ての試験。
//
//   node --test src/lib/push.test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { alertsFor, decodeServerKey, readPushConfig } from './push.ts';

// 本物の VAPID 公開鍵の形 ── 65 バイトの非圧縮 P-256 点。
const REAL_KEY =
  'BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U';

test('base64url の鍵が 65 バイトになる', () => {
  const bytes = decodeServerKey(REAL_KEY);
  assert.equal(bytes.length, 65);
  // 非圧縮の点は 0x04 で始まる。
  assert.equal(bytes[0], 0x04);
});

test('base64url の綴り(- と _)をちゃんと直す', () => {
  // `-` と `_` を素の atob に渡すと、投げるか、黙って別のバイトになる。
  // 標準の綴りに直したものと、同じ結果になること。
  const urlish = 'a-b_cd';
  const standard = 'a+b/cd';
  assert.deepEqual([...decodeServerKey(urlish)], [...Uint8Array.from(atob(standard), (c) => c.charCodeAt(0))]);
});

test('詰め物(=)が省かれていても読める', () => {
  // base64url は = を落とす。落ちたまま atob に渡すと転ぶ。
  for (const s of ['YQ', 'YWI', 'YWJj', 'YWJjZA']) {
    assert.ok(decodeServerKey(s).length > 0, `${s} が読めていない`);
  }
});

test('詰め物が付いたままでも、同じものが返る', () => {
  assert.deepEqual([...decodeServerKey('YQ')], [...decodeServerKey('YQ==')]);
});

test('往復する', () => {
  const bytes = decodeServerKey(REAL_KEY);
  const back = btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
  assert.equal(back, REAL_KEY);
});

// ── alerts ────────────────────────────────────────────────────────────

test('サーバがくれた種類を、そのまま on にする', () => {
  assert.deepEqual(alertsFor(['mention', 'follow_request']), {
    mention: true,
    follow_request: true
  });
});

test('**自分では足さない** — 一覧に無いものは on にしない', () => {
  // ここに favourite を足すのが、この設計がずっと避けている一手。
  // 手元で一覧を作らないので、そもそも足しようがない。
  const alerts = alertsFor(['mention']);
  assert.equal(alerts.favourite, undefined);
  assert.equal(alerts.reblog, undefined);
  assert.equal(Object.keys(alerts).length, 1);
});

test('空で来たら、何も鳴らさない', () => {
  // サーバの一覧が取れなかったとき。分からないなら、鳴らさないほう。
  assert.deepEqual(alertsFor([]), {});
});

// ── サーバの返事の読みとり ─────────────────────────────────────────────
//
// ここを一度まちがえた。v1 を見ていて、v1 には configuration が無かった。
// **パネルは正しく隠れた**ので動いて見えて、鍵を置いた日にはじめて
// 「ずっと出ない」と分かる ── いちばん気づきにくい壊れかた。

// 本番の /api/v2/instance が返す形（要るところだけ）。
const V2 = {
  domain: 'sukhi.f3liz.casa',
  configuration: {
    statuses: { max_characters: 500 },
    vapid: { public_key: 'BOjTBaInlH6UV-k8kNgW8T' },
    direct_types: ['mention', 'follow_request']
  }
};

test('v2 の返事から、鍵と一覧が取れる', () => {
  assert.deepEqual(readPushConfig(V2), {
    serverKey: 'BOjTBaInlH6UV-k8kNgW8T',
    directTypes: ['mention', 'follow_request']
  });
});

test('鍵が置かれていなければ null(=やっていない)', () => {
  const off = { configuration: { vapid: { public_key: null }, direct_types: ['mention'] } };
  assert.equal(readPushConfig(off).serverKey, null);
  // 一覧のほうは、鍵が無くても層分けに要るので残る。
  assert.deepEqual(readPushConfig(off).directTypes, ['mention']);
});

test('空文字の鍵も、無いものとして扱う', () => {
  assert.equal(readPushConfig({ configuration: { vapid: { public_key: '' } } }).serverKey, null);
});

test('**configuration ごと無い返事**でも転ばず、やっていない扱い', () => {
  // これが v1 の形。転ばないのは良いが、転ばないから気づけなかった。
  assert.deepEqual(readPushConfig({ domain: 'sukhi.f3liz.casa', title: 'sukhi' }), {
    serverKey: null,
    directTypes: []
  });
});

test('null や、まるで違うものが来ても転ばない', () => {
  for (const junk of [null, undefined, 'なにか', 42, []]) {
    assert.deepEqual(readPushConfig(junk), { serverKey: null, directTypes: [] });
  }
});

test('一覧に文字列でないものが混じっていたら、落とす', () => {
  const odd = { configuration: { direct_types: ['mention', 42, null, 'follow_request'] } };
  assert.deepEqual(readPushConfig(odd).directTypes, ['mention', 'follow_request']);
});
